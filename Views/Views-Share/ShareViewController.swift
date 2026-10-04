//
//  ShareViewController.swift
//  Views-Share
//
//  The share sheet's entry point for 3D Views — the **only** import path.
//
//  An app only gets a row in the share sheet's app strip from a **share extension**
//  (`com.apple.share-services`). Two other paths were tried on this project and both
//  were removed after failing on the device every single time:
//
//  * The document-open path (`CFBundleDocumentTypes` + `LSHandlerRank`). Measured with
//    `Alternate`+`false`, `None`+`false`, and `Alternate`+`true`; none of the three ever
//    delivered a URL, because the system routes that URL to the scene's
//    `connectionOptions.urlContexts` and this app does not own its scene.
//  * The wake-up URL scheme (`views://import`) was previously disabled after one device
//    build returned `didOpen == false`. It is now used as a best-effort wake-up only: the
//    file is copied to the App Group inbox first, then the host is asked to open the scheme.
//    The inbox remains authoritative, so a rejected or ignored wake-up cannot lose the file.
//
//  The sheet reports the outcome and requests the host app. It closes itself only after iOS
//  confirms the host was opened; if iOS rejects or ignores the request, the sheet stays open
//  and shows a retry button instead of reporting a false success.
//
//  Three device-measured defects were removed from this file and must not come back:
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
//

import UIKit
import UniformTypeIdentifiers

/// Declared with an explicit Objective-C name because the extension's `Info.plist`
/// names this class directly in `NSExtensionPrincipalClass`, and a Swift mangled name
/// there is a class the runtime cannot find.
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private var hasStarted = false
    private var handoffFinished = false
    /// Guards the auto-close so a slow handover cannot outlive the sheet's dismissal.
    private var closeScheduled = false
    private var hostWakeupAttempted = false
    private var hostWakeupResolved = false
    private var wakeupTimeoutScheduled = false

    override func viewDidLoad() {
        // Left before anything else, including the label. `NSExtensionPrincipalClass`
        // names this class as a plain Objective-C string, and if that lookup ever fails
        // the extension dies without running a line of this file — which looks exactly
        // like the extension never having been launched. This timestamp is what tells
        // those two apart from the app's side.
        AppGroup.recordExtensionStart()

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
        // Detached on purpose: `handOverEverything` copies the shared file, and a
        // multi-megabyte STEP model copied on the main actor holds the share sheet at
        // its launch moment, which is where iOS kills an extension. The body hops back
        // to the main actor by itself whenever it touches the label or the button.
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
        guard AppGroup.isAvailable else {
            AppGroup.recordHandoff(names: [], failures: ["共享容器不可用"])
            await MainActor.run { [weak self] in
                self?.statusLabel.text = "无法导入：共享容器不可用\n当前安装包的签名里没有 \(AppGroup.identifier)"
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

        AppGroup.recordHandoff(names: deposited, failures: failures)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.statusLabel.text = self.message(deposited: deposited, failures: failures)
            if deposited.isEmpty {
                // Nothing usable came through, so there is no handover to close on and
                // the user needs a way out. The button is that way out.
                self.openButton.isHidden = false
                self.openButton.isEnabled = true
            } else {
                // The file is already durable in the App Group inbox. Complete the
                // extension now; host wake-up is only an optimization and must not gate
                // the handoff because iOS may reject or omit its callback.
                self.openButton.isHidden = true
                self.requestHostWakeup()
                self.scheduleAutoClose()
            }
        }
    }

    /// Dismisses the sheet a beat after a successful handover, so the result line is
    /// readable but the user is not asked to do anything.
    private func scheduleAutoClose() {
        guard !closeScheduled else { return }
        closeScheduled = true
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
        guard !hostWakeupAttempted else { return }
        hostWakeupAttempted = true
        hostWakeupResolved = false
        guard let url = URL(string: "views://import?handoff=1") else {
            showWakeupFailure()
            return
        }

        // Some iOS versions return `false`; others never call the completion handler for
        // a share extension. Try the supported extension API and an experimental responder
        // chain fallback immediately, then repeat both after one second. The fallback is
        // intentionally isolated here so it can be removed if the device rejects it or the
        // App Store validation flags the extension-only call.
        openHostAppRequest(url)
        _ = tryResponderChainOpen(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.hostWakeupResolved else { return }
            self.openHostAppRequest(url)
            _ = self.tryResponderChainOpen(url)
        }

        guard !wakeupTimeoutScheduled else { return }
        wakeupTimeoutScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.hostWakeupResolved else { return }
            self.hostWakeupResolved = true
            self.showWakeupFailure()
        }
    }

    private func openHostAppRequest(_ url: URL) {
        extensionContext?.open(url) { [weak self] didOpen in
            DispatchQueue.main.async {
                guard let self, !self.hostWakeupResolved else { return }
                if didOpen {
                    self.hostWakeupResolved = true
                    self.scheduleAutoClose()
                }
            }
        }
    }

    /// Experimental fallback for device testing only.
    ///
    /// A share extension cannot reference `UIApplication.shared` directly because that API
    /// is unavailable to application extensions. The selector is therefore resolved at runtime
    /// while walking the responder chain. This is not a supported contract: a missing target
    /// simply returns false, and a future OS can remove or ignore the selector without affecting
    /// the normal `extensionContext.open` path.
    private func tryResponderChainOpen(_ url: URL) -> Bool {
        let openSelector = Selector(("openURL:"))
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: openSelector) {
                current.perform(openSelector, with: url)
                return true
            }
            responder = current.next
        }

        return false
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
        case (true, _):
            return "没有拿到可导入的文件\n请试试从「文件」App 里分享"
        }
    }

    /// One attachment, one copy into the shared inbox. Returns the name it landed
    /// under, or `nil` when nothing usable came out of the provider.
    private func deposit(from provider: NSItemProvider) async -> String? {
        // 1) A file URL — what the Files app hands over almost every time.
        for identifier in [UTType.fileURL.identifier, UTType.url.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let name = await depositURL(from: provider, typeIdentifier: identifier),
               !name.isEmpty {
                return name
            }
        }

        // 2) Anything else: ask for a file representation. These providers hand over a
        //    URL into a temporary directory the system reclaims the moment the callback
        //    returns, which is why the copy happens inside it and not after an await.
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
                    continuation.resume(returning: nil)
                    return
                }
                // Copy while the provider owns the temporary/security-scoped URL.
                continuation.resume(returning: AppGroup.deposit(fileAt: url))
            }
        }
    }

    private func depositFileRepresentation(from provider: NSItemProvider,
                                           typeIdentifier: String,
                                           suggestedName: String?) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: AppGroup.deposit(fileAt: url,
                                                               preferredName: suggestedName))
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
        hostWakeupAttempted = false
        hostWakeupResolved = false
        wakeupTimeoutScheduled = false
        requestHostWakeup()
    }

    private func completeExtension() {
        guard !handoffFinished else { return }
        handoffFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
