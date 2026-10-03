//
//  ShareViewController.swift
//  3D-Views-Share
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
//  * The wake-up URL scheme (`3dviews://import`). `extensionContext.open` returned
//    `didOpen == false` on every attempt, and Safari could not open the scheme either.
//
//  So the extension stops waiting for a URL it does not control. It takes whatever the
//  share sheet offered, copies it into the App Group inbox, and leaves a note there.
//  The app drains that inbox on every activation, so the handover completes whether or
//  not the app was ever woken up — which is the one behaviour that was measured to work.
//
//  The sheet reports the outcome and stays up so the user can read it. It does not try to
//  launch the host app: it has no supported way to do that, and the file does not need it.
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
    private var hostLaunchAttempted = false

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

        openButton.setTitle("完成", for: .normal)
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
        let opened = await tryToOpenHostApp(deposited: deposited, failures: failures)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.statusLabel.text = self.message(deposited: deposited,
                                                 failures: failures,
                                                 hostOpened: opened)
            // The button is the only way out of a share extension that stays alive. It is
            // shown whatever happened, so a failure still leaves something tappable rather
            // than a sheet the user has to dismiss by swiping.
            self.openButton.isHidden = false
            self.openButton.isEnabled = true
        }
    }

    /// 请求系统把已完成交接的分享返回到主 App。
    ///
    /// 这不是把文件再传一次：文件已经在 App Group Inbox，深链只负责唤起宿主；
    /// 主 App 启动后会按自己的生命周期消费 Inbox。若系统仍拒绝扩展发起的打开请求，
    /// 仍保留当前可用的“完成”按钮，不能影响已经成功的导入。
    private func tryToOpenHostApp(deposited: [String], failures: [String]) async -> Bool {
        guard !hostLaunchAttempted else { return false }
        hostLaunchAttempted = true
        guard let url = URL(string: "3dviews://import") else {
            return false
        }

        guard let context = extensionContext else {
            return false
        }
        let opened = await withCheckedContinuation { continuation in
            context.open(url) { didOpen in
                continuation.resume(returning: didOpen)
            }
        }
        if !opened {
            AppGroup.recordHandoff(names: deposited, failures: failures + ["主 App 深链未被系统接受"])
        }
        return opened
    }

    private func message(deposited: [String],
                         failures: [String],
                         hostOpened: Bool) -> String {
        let hostLine = hostOpened ? "正在打开 3D Views…" : "请点击“完成”返回"
        switch (deposited.isEmpty, failures.isEmpty) {
        case (false, true):
            return deposited.count == 1
                ? "已导入 \(deposited[0])\n\(hostLine)"
                : "已导入 \(deposited.count) 个文件\n\(hostLine)"
        case (false, false):
            return "已导入 \(deposited.count) 个文件，另有 \(failures.count) 个未能读取\n\(hostLine)"
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

    // MARK: - Finishing

    /// 关闭分享扩展。文件已在共享收件箱中，主 App 会在启动或激活时消费它。
    /// 自动拉起由 `tryToOpenHostApp()` 先尝试；若系统拒绝扩展发起的深链，
    /// 这个按钮仍然提供可靠的手动返回路径。
    @objc private func openHostApp() {
        completeExtension()
    }

    private func completeExtension() {
        guard !handoffFinished else { return }
        handoffFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
