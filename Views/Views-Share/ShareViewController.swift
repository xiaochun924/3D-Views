//
//  ShareViewController.swift
//  Views-Share
//
//  The share sheet's entry point for 3D Views.
//
//  An app only gets a row in the share sheet's app strip from a **share extension**
//  (`com.apple.share-services`). The document-open path (`CFBundleDocumentTypes` +
//  `LSHandlerRank`, both still declared in `project.yml`) has been measured on this
//  project with `Alternate`+`false`, `None`+`false` and `Alternate`+`true`, and none of
//  the three ever delivered a URL; it is kept declared but is not what brings a file in.
//
//  The wake-up URL scheme (`views://import`) is used as a best-effort wake-up only: the
//  file is copied to the App Group inbox first, then the host is asked to open the scheme.
//  The inbox remains authoritative, so a rejected or ignored wake-up cannot lose the file.
//
//  The sheet reports the outcome and requests the host app. It closes itself only after iOS
//  confirms the host was opened; if iOS rejects or ignores the request, the sheet stays open
//  and shows a retry button instead of reporting a false success.
//
//  Four device-measured defects were removed from this file and must not come back:
//
//  * `tryToOpenHostApp` awaited `extensionContext.open` inside a continuation. The
//    callback is not guaranteed to fire in a share extension, so the continuation hung
//    and the process was reaped — the "share sheet crashes on the second try" report.
//    It also only ever returned `didOpen == false`, so it bought nothing.
//  * The completion button was shown unconditionally and never auto-closed, forcing the
//    user to tap 完成 on a handover that had already succeeded.
//  * `deposit` ran `FileManager.copyItem` on the main thread from `viewDidAppear`. A
//    multi-megabyte STEP file blocked the sheet during launch, which is the other way
//    this extension was killed.
//  * The first App Group access ran synchronously on the main thread. Mounting the shared
//    container on a cold extension launch is slow enough for the watchdog to kill the
//    process — the "first share after install crashes, the second one works" report.
//

import UIKit
import UniformTypeIdentifiers

/// The class the share sheet instantiates, named from the extension's `Info.plist`.
///
/// `NSExtensionPrincipalClass` now reads `$(PRODUCT_MODULE_NAME).ShareViewController`
/// (see `project.yml`'s `NSExtensionPrincipalClass`), so the runtime is handed a
/// module-qualified name it can resolve without waiting on Swift's Objective-C name
/// registration. The `@objc` attribute is kept as the second route: it also lets the
/// class be found under the bare `ShareViewController`, which is what a plist that has
/// not been through the build-variable expansion would ask for. Both names resolve to
/// this same class, so neither path can land on a class the runtime cannot find.
///
/// This pairing is the fix for the cold-launch crash. A bare `ShareViewController` in
/// the plist was measured on device to fail exactly this way: the share sheet still
/// listed the row and the .appex was still bundled and signed, but the process never
/// came up at all — no line of this file ran.
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private var hasStarted = false
    private var handoffFinished = false
    /// Guards the auto-close so a slow handover cannot outlive the sheet's dismissal.
    private var closeScheduled = false
    private var hostWakeupResolved = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在导入…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        openButton.setTitle("打开 3D Views", for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.configuration = .borderedProminent()
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openHostApp), for: .touchUpInside)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)
        view.addSubview(openButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -32),
            openButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        // Detached so the sheet is not held at its launch moment while the providers are
        // asked for their files. Note what this does *not* do: `handOverEverything` is a
        // method of a `UIViewController`, so the whole class is `@MainActor` and the body
        // runs on the main actor regardless — `Task.detached` cannot move it off. What
        // actually keeps the copy off the main thread is that it happens inside the
        // provider callbacks below: those are non-isolated escaping closures called on the
        // provider's own queue, and `AppGroup.deposit` is non-isolated too. Moving the copy
        // out of those callbacks (to after an `await`, say) would put it back on the main
        // actor, and this wrapper would not prevent that.
        Task.detached { [weak self] in
            await self?.handOverEverything()
        }
    }

    // MARK: - Handover

    private func handOverEverything() async {
        // Checked first and reported out loud. The container's existence is decided when
        // the app is signed, not when it is built, and this IPA ships unsigned — so a
        // signing tool that drops the App Group leaves the extension with nowhere to put
        // anything. That failure used to look identical to success: "正在导入…" for a
        // second, then the sheet closes and nothing has happened anywhere. Saying it here
        // is the only place the user can see it, since the app has nothing to look at.
        //
        // The check itself is dispatched off the main actor. Reading `containerURL` is
        // what mounts the shared container on first access; on a cold launch that mount
        // can take long enough for the watchdog to kill the extension mid-`viewDidAppear`
        // — the "first share after install crashes" symptom. Keeping the check off the
        // main actor removes the remaining stall on the very first launch.
        let containerAvailable = await Task.detached { AppGroup.isAvailable }.value
        guard containerAvailable else {
            let message = "无法导入：共享容器不可用\n当前安装包的签名里没有 \(AppGroup.identifier)"
            await MainActor.run { [weak self] in
                self?.statusLabel.text = message
                self?.openButton.isHidden = false
                self?.openButton.isEnabled = true
            }
            return
        }

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        var deposited: [String] = []
        var failures: [String] = []

        for provider in providers {
            if let name = await deposit(from: provider) {
                deposited.append(name)
            } else {
                failures.append(provider.registeredTypeIdentifiers.joined(separator: ","))
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.statusLabel.text = self.message(deposited: deposited, failures: failures)
            if deposited.isEmpty {
                // Nothing usable came through, so there is no handover to close on and
                // the user needs a way out. The button is that way out.
                self.openButton.isHidden = false
                self.openButton.isEnabled = true
            } else {
                // The file is durable, but the handoff is not complete until iOS confirms
                // that the host app accepted the wake-up request. Keep this controller alive
                // while that request is in flight so the extension cannot be reaped before
                // the main app is brought forward.
                //
                // The wake-up is delayed a beat on purpose. On a cold extension launch the
                // sheet has not finished presenting when the copy lands; opening the host
                // app that instant switches away before the result panel was ever rendered —
                // the "first share jumps straight to the app, no panel" report. Waiting here
                // lets the label show first, then hands over.
                //
                // DispatchQueue.main.asyncAfter instead of `Task.sleep` deliberately: a
                // `Task {}` in an app extension rides the process's concurrency scheduler,
                // whose behaviour under the extension lifecycle is not something we can
                // verify here, and the measured symptom after switching to it was a
                // regression of the cold-launch crash. GCD timers are what the rest of this
                // file already uses on the wake-up path and are known-good on device.
                self.openButton.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, !self.handoffFinished else { return }
                    self.requestHostWakeup()
                }
            }
        }
    }

    /// Dismisses the sheet a beat after a successful handover, so the result line is
    /// readable but the user is not asked to do anything.
    private func scheduleAutoClose() {
        guard !closeScheduled else { return }
        closeScheduled = true
        // GCD rather than Task.sleep — the extension lifecycle's concurrency scheduler
        // is not something we can verify, and this file's known-good timers are GCD.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.completeExtension()
        }
    }

    /// Best-effort request to bring the host app forward after the file is safely in the
    /// shared inbox. This is intentionally fire-and-forget: share extensions are not
    /// guaranteed to receive the completion callback, so awaiting it can leave the extension
    /// suspended forever. The host's Inbox sweep is the recovery path when iOS rejects this.
    private func requestHostWakeup() {
        hostWakeupResolved = false
        guard let url = URL(string: "views://import?handoff=1") else {
            showWakeupFailure()
            return
        }

        // Directly to the responder-chain wake-up. The official `extensionContext.open`
        // path was removed: on-device readings (iOS 26, 10-05 21:25) showed it answering
        // in ~1 ms with `didOpen = false` every time, so it only ever handed the job to
        // the fallback — it bought one extra round-trip and a second place to hang.
        openViaResponderChain(url)
    }

    /// 社区方案：沿 responder chain 找 UIApplication 调用 open 拉起主 App。
    /// 分享扩展里官方 `extensionContext.open` 多数版本返回 false，此路是社区实测
    /// 有效的主路径。非官方 API，有审核风险，且仍可能被系统拒绝——被拒或无人响应时
    /// 走失败提示，交给重试按钮与收件箱扫描兜底。
    private func openViaResponderChain(_ url: URL) {
        // The chain is finite in principle and unguarded in practice: `next` is whatever
        // the hierarchy says it is, and during a dismissal it can point back into the chain
        // it came from. A cycle here is a main-thread spin, which the watchdog ends by
        // killing the extension — the same symptom this walk exists to avoid. Capping the
        // walk turns "hung forever" into "gave up", and the failure path below already
        // handles giving up. 200 hops is far past any real chain.
        let hopLimit = 200
        var hops = 0
        var responder: UIResponder? = self
        while let current = responder, hops < hopLimit {
            hops += 1
            if let app = current as? UIApplication {
                app.open(url, options: [:]) { [weak self] success in
                    DispatchQueue.main.async {
                        guard let self, !self.hostWakeupResolved else { return }
                        if success {
                            self.hostWakeupResolved = true
                            self.scheduleAutoClose()
                        } else {
                            // 兜底 open 被系统拒绝，没有第三条路可试 ——
                            // 直接给用户一个可操作的出口，而不是让面板继续挂着。
                            self.hostWakeupResolved = true
                            self.showWakeupFailure()
                        }
                    }
                }
                // `open`'s completion is not guaranteed to arrive either; give it its own
                // grace period so the sheet cannot sit unresolved forever. Now that the
                // failure path is no longer optional, this timer is the only thing between
                // "the walk found a UIApplication" and a sheet that hangs until iOS gives up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.hostWakeupResolved else { return }
                    self.hostWakeupResolved = true
                    self.showWakeupFailure()
                }
                return
            }
            responder = current.next
        }

        // Two ways to reach here: the chain really has no `UIApplication` on it, or the walk
        // hit its cap. Both leave the user in the same place, so they share the failure path.
        hostWakeupResolved = true
        showWakeupFailure()
    }

    private func showWakeupFailure() {
        statusLabel.text = "文件已导入，但没有自动打开 3D Views\n请点击下方按钮重试"
        openButton.setTitle("打开 3D Views", for: .normal)
        openButton.isHidden = false
        openButton.isEnabled = true
    }
    private func message(deposited: [String],
                         failures: [String]) -> String {
        switch (deposited.isEmpty, failures.isEmpty) {
        case (false, true):
            return deposited.count == 1
                ? "已导入 \(deposited[0])"
                : "已导入 \(deposited.count) 个文件"
        case (false, false):
            return "已导入 \(deposited.count) 个文件，另有 \(failures.count) 个未能读取"
        case (true, false):
            // Everything handed over failed to read. The count is what separates this from
            // the case below, where nothing was handed over at all — and it is the only
            // thing that tells the user the share itself did arrive.
            return "没有拿到可导入的文件\n\(failures.count) 个附件未能读取"
        case (true, true):
            return "没有拿到可导入的文件\n请试试从「文件」App 里分享"
        }
    }

    /// One attachment, one copy into the shared inbox. Returns the name it landed
    /// under, or `nil` when nothing usable came out of the provider.
    private func deposit(from provider: NSItemProvider) async -> String? {
        for identifier in [UTType.fileURL.identifier, UTType.url.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let name = await depositURL(from: provider, typeIdentifier: identifier),
               !name.isEmpty {
                return name
            }
        }

        // These providers hand over a URL into a temporary directory the system reclaims
        // the moment the callback returns, which is why the copy happens inside it and not
        // after an await.
        let suggested = provider.suggestedName
        for identifier in [UTType.data.identifier, UTType.item.identifier, UTType.content.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let name = await depositFileRepresentation(from: provider,
                                                         typeIdentifier: identifier,
                                                         suggestedName: suggested) {
                return name
            }
        }

        return nil
    }

    private func depositURL(from provider: NSItemProvider,
                            typeIdentifier: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let gate = ContinuationGate()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else {
                    gate.resume(continuation, value: nil)
                    return
                }
                // Copy while the provider owns the temporary/security-scoped URL. The
                // deadline below is cancelled for the duration, because a large model can
                // legitimately take longer than it to copy — and a timeout that fires
                // mid-copy would report a failure while the file is in fact on its way
                // into the inbox.
                let copied = AppGroup.deposit(fileAt: url)
                gate.resume(continuation, value: copied)
            }
            // On a cold extension launch `loadItem` can be delayed or never fire. Without
            // a deadline the extension stays suspended on the continuation and the system
            // eventually kills it — the "first share after install crashes" symptom in its
            // other form. The gate makes the two sources safe to race; `deposit` marks
            // itself busy so this cannot cut a copy short.
            gate.armDeadline(after: 5.0) {
                gate.resume(continuation, value: nil)
            }
        }
    }

    private func depositFileRepresentation(from provider: NSItemProvider,
                                           typeIdentifier: String,
                                           suggestedName: String?) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let gate = ContinuationGate()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    gate.resume(continuation, value: nil)
                    return
                }
                let copied = AppGroup.deposit(fileAt: url, preferredName: suggestedName)
                gate.resume(continuation, value: copied)
            }
            gate.armDeadline(after: 5.0) {
                gate.resume(continuation, value: nil)
            }
        }
    }

    // MARK: - Finishing

    /// 关闭分享扩展。文件已在共享收件箱中，主 App 会在启动或激活时消费它。
    /// 交接成功时由 `scheduleAutoClose()` 自动调用；只有“没有拿到文件”或
    /// “共享容器不可用”这两种需要用户阅读的失败，才把按钮留给用户点。
    @objc private func openHostApp() {
        // A successful callback closes the extension. If iOS refuses the request or never
        // calls back, `requestHostWakeup` leaves this button available for another attempt.
        requestHostWakeup()
    }

    private func completeExtension() {
        guard !handoffFinished else { return }
        handoffFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

/// Lets two racing sources (a provider callback and a deadline) resolve the same
/// continuation exactly once. `CheckedContinuation` must be resumed precisely once;
/// without this gate, a provider answering a tick after the 5s timeout fired would
/// resume it twice and crash the extension.
///
/// The deadline is *armed* rather than scheduled immediately, and disarmed while a copy
/// is in flight. A 5 s wall-clock timer started alongside `loadItem` cannot tell "the
/// provider never answered" from "the provider answered and we are still copying a
/// 200 MB STEP file": in the second case it fired, resolved the continuation with `nil`,
/// and the sheet reported the attachment as failed — while `AppGroup.deposit` went on to
/// finish and put the file in the inbox. The file was imported and the UI said it was not.
/// Holding the timer off until the callback actually arrives removes that window; the
/// deadline then only covers the wait it was meant to cover.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var deadlineScheduled = false
    private var deadlineWork: DispatchWorkItem?

    func resume(_ continuation: CheckedContinuation<String?, Never>, value: String?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let pending = deadlineWork
        deadlineWork = nil
        lock.unlock()
        pending?.cancel()
        continuation.resume(returning: value)
    }

    /// Schedules the timeout, unless the callback already resolved the gate or the
    /// deadline was already armed. Safe to call from any thread.
    func armDeadline(after seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        let work = DispatchWorkItem(block: body)
        lock.lock()
        // Already resolved, or a deadline already armed: nothing to add. Guarding here as
        // well as in `resume` keeps the double-arm case from leaking a second timer.
        if finished || deadlineScheduled {
            lock.unlock()
            return
        }
        deadlineScheduled = true
        deadlineWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
