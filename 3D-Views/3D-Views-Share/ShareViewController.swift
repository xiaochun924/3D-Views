//
//  ShareViewController.swift
//  3D-Views-Share
//
//  The share sheet's entry point for 3D Views.
//
//  An app only gets a row in the share sheet's app strip from a **share extension**
//  (`com.apple.share-services`). This app had none, which is why "共享 → 到 3D Views"
//  could only ever bounce through the document-open path — a path that, on this
//  project, has never once been observed to deliver a URL.
//
//  So the extension stops waiting for a URL it does not control. It takes whatever
//  the share sheet offered, copies it into the App Group inbox, and leaves a note
//  there. The app drains that inbox on every activation, so the handover completes
//  whether or not the app was ever woken up.
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
        Task { await handOverEverything() }
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
                self?.openButton.isHidden = true
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
            self.openButton.isHidden = deposited.isEmpty
            self.openButton.isEnabled = !deposited.isEmpty
        }

        // Keep the extension alive after a successful copy. The user can now see and tap the
        // button, which lets us distinguish an iOS URL-handoff rejection from a dead extension.
        if deposited.isEmpty {
            await MainActor.run { [weak self] in
                self?.completeExtension()
            }
        }
    }

    private func message(deposited: [String], failures: [String]) -> String {
        switch (deposited.isEmpty, failures.isEmpty) {
        case (false, true):
            return deposited.count == 1
                ? "已导入 \(deposited[0])\n打开 3D Views 查看"
                : "已导入 \(deposited.count) 个文件\n打开 3D Views 查看"
        case (false, false):
            return "已导入 \(deposited.count) 个文件，另有 \(failures.count) 个未能读取"
        case (true, _):
            return "没有拿到可导入的文件\n请试试用文件 App 打开后分享"
        }
    }

    /// One attachment, one copy into the shared inbox. Returns the name it landed
    /// under, or `nil` when nothing usable came out of the provider.
    private func deposit(from provider: NSItemProvider) async -> String? {
        // 1) A file URL — what the Files app hands over almost every time.
        for identifier in [UTType.fileURL.identifier, UTType.url.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let url = await loadURL(from: provider, typeIdentifier: identifier),
               let name = AppGroup.deposit(fileAt: url) {
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

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
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

    // MARK: - Waking the app

    @objc private func openHostApp() {
        guard !handoffFinished else { return }
        guard let context = extensionContext else {
            statusLabel.text = "分享扩展已结束，请返回后重新分享"
            return
        }

        // `AppGroup.wakeUpURL` is failable on purpose. Both Foundation URL builders have
        // been observed to *trap* on this platform rather than return `nil` — a force
        // unwrap of `URL(string:)` and an `_assertionFailure` inside `URLComponents.scheme`'s
        // setter, each of which killed the extension during a `static let`'s
        // `dispatch_once` and made the button look like a crash-to-nothing. Reporting the
        // failure as text is the only way this case is ever observable.
        //
        // The report prints the string Foundation was actually given, its length and its
        // code points. That turns "the parser rejected our URL" from an inference into a
        // reading: if the text on screen is the expected seven ASCII letters and the parse
        // still failed, no reshaping of the string can fix it and the fix has to happen
        // somewhere other than `URL(string:)`.
        guard let url = AppGroup.wakeUpURL else {
            openButton.isEnabled = true
            statusLabel.text = wakeUpFailureReport()
            return
        }

        openButton.isEnabled = false
        statusLabel.text = "正在打开 3D Views…"

        // The extension context is Apple's supported handoff API. Keep the extension alive
        // until its completion callback, because completing first can discard the request.
        context.open(url) { [weak self] didOpen in
            DispatchQueue.main.async {
                guard let self else { return }
                if didOpen {
                    self.completeExtension()
                } else {
                    self.openButton.isEnabled = true
                    self.statusLabel.text = "系统未能打开 3D Views，请关闭后重试"
                }
            }
        }
    }

    /// What to show when `AppGroup.wakeUpURL` comes back `nil`.
    ///
    /// On-screen, not in a log: the share extension's log is not reachable from the
    /// device, and this is the only channel the user has. Everything printed is taken from
    /// the string Foundation was actually handed, so the report cannot itself be wrong
    /// about what was parsed.
    private func wakeUpFailureReport() -> String {
        let text = AppGroup.wakeUpURLText
        let codePoints = text.unicodeScalars
            .map { String($0.value) }
            .joined(separator: " ")
        return """
        无法构造唤醒地址
        原文：\(text)
        长度：\(text.count)
        码位：\(codePoints)
        请手动切到 3D Views
        """
    }

    private func completeExtension() {
        guard !handoffFinished else { return }
        handoffFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
