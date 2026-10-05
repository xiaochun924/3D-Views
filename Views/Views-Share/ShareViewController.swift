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
/// came up at all — no line of this file ran, so the 「扩展启动于」 timestamp stayed
/// frozen at its previous value.
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
        // Left before anything else, including the label. If the principal-class
        // lookup ever fails the extension dies without running a line of this file —
        // which looks exactly like the extension never having been launched. This
        // timestamp is what tells those two apart from the app's side, so it stays the
        // first thing the extension does.
        //
        // The write is dispatched off the main thread deliberately. The *first* access to
        // the App Group (which `UserDefaults(suiteName:)` triggers) mounts the shared
        // container, and on a cold extension launch that mount is slow enough that the
        // system watchdog can kill the extension — the "first share after install
        // crashes, the second one works" symptom. The timestamp only needs to exist
        // before the handoff record is read, so it is written asynchronously.
        Task.detached {
            AppGroup.recordExtensionStart()
        }

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
        // — the "first share after install crashes" symptom. `viewDidLoad` already
        // started the mount through `recordExtensionStart`, so by the time this runs the
        // container is usually warm; keeping the check off the main actor removes the
        // remaining stall on the very first launch.
        let containerAvailable = await Task.detached { AppGroup.isAvailable }.value
        guard containerAvailable else {
            // Recorded off the main actor for the same reason as the check above: the
            // failure path still touches the shared container for the first time.
            let message = "无法导入：共享容器不可用\n当前安装包的签名里没有 \(AppGroup.identifier)"
            await Task.detached {
                AppGroup.recordHandoff(names: [], failures: ["共享容器不可用"])
            }.value
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

        // Dispatched off the main actor for the same reason as the check above.
        // `recordHandoff` writes through `UserDefaults(suiteName:)` (AppGroup.swift), and
        // that call is what mounts the shared container on first access. Left bare here,
        // it ran synchronously on the main actor — the exact stall the check above exists
        // to avoid, and the reason this file dispatches its other App Group writes.
        // On a cold launch the mount is slow enough for the watchdog to kill the extension,
        // which is why the first share after install crashed and the second one worked: by
        // then the container was already mounted and this line returned instantly.
        //
        // Awaited rather than fired off, because the record has to be durable before the
        // host is asked to wake up — the app reads it to report what arrived.
        //
        // The `@Sendable` closure annotation is required by the strict Swift 6.2 build
        // (`NonisolatedNonsendingByDefault`): this method is `@MainActor`-isolated, so the
        // captured `deposited`/`failures` would otherwise be treated as non-sending values
        // crossing into the detached task, and the compiler rejects the closure outright.
        //
        // Snapshotting into `let` bindings before the task is also mandatory: a @Sendable
        // closure may not capture the mutable `var` themselves (they are appended to in the
        // loop above), only immutable copies of their current values.
        let depositedSnapshot = deposited
        let failuresSnapshot = failures
        await Task.detached { @Sendable in
            AppGroup.recordHandoff(names: depositedSnapshot, failures: failuresSnapshot)
        }.value
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
        AppGroup.recordFinishStep("已安排自动关闭")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { self?.completeExtension() }
        }
    }

    /// Best-effort request to bring the host app forward after the file is safely in the
    /// shared inbox. This is intentionally fire-and-forget: share extensions are not
    /// guaranteed to receive the completion callback, so awaiting it can leave the extension
    /// suspended forever. The host's Inbox sweep is the recovery path when iOS rejects this.
    private func requestHostWakeup() {
        hostWakeupResolved = false
        // 飞行记录仪的起点。这一步之前的一切都已经有据可查（`recordExtensionStart` 与
        // `recordHandoff`），之后的一切此前完全没有记录——而收尾正是唯一一段「扩展被杀了，
        // 还是正常走完了」无法分辨的区间。这里就是那段区间的开头。
        AppGroup.recordFinishStep("请求唤醒主 App")
        guard let url = URL(string: "views://import?handoff=1") else {
            showWakeupFailure()
            return
        }

        // The official API first. Its callback decides whether the responder-chain
        // fallback runs, which is why the deadline below must not pre-empt it.
        openHostAppRequest(url)

        // Only a deadline on the *total* attempt, and it deliberately does not set
        // `hostWakeupResolved` before the fallback has had its turn. The previous version
        // set it here, which silently disabled the only path that runs on device: the flag
        // was already true, so `openViaResponderChain` was never reached and the sheet gave
        // up while the working route sat idle.
        //
        // 真机读数（10-05 21:25，iOS 26，`f2b2338`）：`extensionContext.open` 在 **1 毫秒**
        // 后回调，`didOpen = false`。既不是 2.5 秒后，也不是「永不回调」—— 这段注释原本断言
        // 后者是 iOS 26 上的常态（"or never, which is its usual behaviour on iOS 26"），
        // 被实测推翻。所以这个 deadline 正常情况下根本没有在等官方 API；它剩下的意义只是
        // 「兜底那条路连回调都没来」时的最后一道网。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.hostWakeupResolved else { return }
            // Official API has not answered in time. Try the fallback rather than
            // declaring failure; `showWakeupFailure` only runs if that also stays silent
            // for its own grace period.
            self.openViaResponderChain(url, trigger: .deadlineExpired)
        }
    }

    private func openHostAppRequest(_ url: URL) {
        extensionContext?.open(url) { [weak self] didOpen in
            DispatchQueue.main.async {
                // 记在 guard 之前：这条要回答的是「官方 API 到底回没回调、回了什么」，而
                // `hostWakeupResolved` 已经为真时下面的 guard 会直接返回，那就什么都记不下。
                AppGroup.recordFinishStep("官方 open 回调 didOpen=\(didOpen)")
                guard let self, !self.hostWakeupResolved else { return }
                if didOpen {
                    self.hostWakeupResolved = true
                    self.scheduleAutoClose()
                } else {
                    // 官方 API 被拒时，走社区验证的 responder chain 兜底再试一次
                    // （iOS 26/27 实测有效，非官方 API、尽力而为）。失败无副作用：
                    // 重试按钮与主 App 的收件箱扫描仍是恢复路径。
                    //
                    // 这条路和 2.5 秒 deadline 那条路一样，必须自己收尾：官方 API 已经明确
                    // 回了 `false`，不会再有第二次回调来解开状态，所以从这里进去的兜底要把
                    // 失败处理走完（1.5 秒宽限 → 失败提示）。
                    //
                    // 早先这里走的是默认参数 `isFallback = false`，那会让下面三条失败处理
                    // （open 回调回 false、回调根本不来、链上找不到 UIApplication）全部失效：
                    // 面板会一直挂着，直到 2.5 秒后 deadline 再发第二次 `UIApplication.open`。
                    // 真机读数显示，正常分享走的**就是**这条路 —— 官方 API 1 毫秒回 false，
                    // 兜底从此进。所以「默认关掉失败处理」等于把唯一在跑的路径的收尾关掉。
                    self.openViaResponderChain(url, trigger: .officialRefused)
                }
            }
        }
    }

    /// Why the walk is running. Both triggers mean the same thing for control flow — the
    /// official API is finished with this attempt and no further callback will resolve the
    /// state, so the walk owns the failure path — but they say different things about iOS,
    /// and the trail is only worth keeping if it records which one happened. An earlier
    /// version used a single `isFallback` flag for both jobs, which forced one of the two
    /// reasons to be logged wrongly and, at the official-refusal call site, quietly switched
    /// the entire failure path off.
    private enum WakeupTrigger: String {
        case officialRefused = "兜底 open（官方拒绝）"
        case deadlineExpired = "兜底 open（超时触发）"
    }

    /// 社区方案：沿 responder chain 找 UIApplication 调用 open 拉起主 App。
    /// 官方 `extensionContext.open` 在分享扩展里多数版本返回 false，此路是社区实测
    /// 有效的兜底。非官方 API，有审核风险，且仍可能被系统拒绝——被拒或无人响应时
    /// 走失败提示，交给重试按钮与收件箱扫描兜底。
    private func openViaResponderChain(_ url: URL, trigger: WakeupTrigger) {
        AppGroup.recordFinishStep(trigger.rawValue)
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
                            // 官方 API 已经拒过一次，兜底也拒了，没有第三条路可试 ——
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
                    AppGroup.recordFinishStep("兜底宽限到期")
                    self.hostWakeupResolved = true
                    self.showWakeupFailure()
                }
                return
            }
            responder = current.next
        }

        // Two ways to reach here: the chain really has no `UIApplication` on it, or the walk
        // hit its cap. Both leave the user in the same place, so they share the failure path
        // — but the trail records them apart, because a chain that spun and a chain that was
        // merely short are not the same finding.
        AppGroup.recordFinishStep(hops >= hopLimit
            ? "兜底：responder 链超过 \(hopLimit) 跳（疑似成环）"
            : "兜底：链上找不到 UIApplication")
        hostWakeupResolved = true
        showWakeupFailure()
    }

    private func showWakeupFailure() {
        AppGroup.recordFinishStep("显示失败提示")
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
        // 整条轨迹的终点，也是它存在的理由：`completeRequest` 一旦返回，扩展随时可能被系统
        // 拆掉，而在此之前它一个字节都没写过。有了这一条，诊断页第一次能回答「扩展是被杀了，
        // 还是正常走完了」——记录停在上一条＝收尾没走完；记录里有这一条＝收尾是完整的，
        // 闪退另有原因，别再往这条路径上找。
        AppGroup.recordFinishStep("提交 completeRequest")
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
