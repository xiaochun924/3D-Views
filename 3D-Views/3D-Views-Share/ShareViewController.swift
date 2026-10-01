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
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在导入…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
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
        statusLabel.text = message(deposited: deposited, failures: failures)

        // Let the message land before the sheet closes; a silent dismissal reads as
        // "nothing happened", which is the exact confusion this extension exists to end.
        try? await Task.sleep(for: .seconds(1.1))

        wakeUpHostApp()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
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

    /// Best-effort pull of the host app to the foreground.
    ///
    /// Share extensions are given no supported way to do this, and on most iOS
    /// versions the responder walk below finds nothing to call. That is precisely why
    /// nothing depends on it: the file is already sitting in the App Group inbox, and
    /// the app drains that inbox on launch and on every activation regardless.
    ///
    /// The class name is matched as a string rather than with `as? UIApplication`
    /// because `UIApplication.shared` is marked unavailable in app extensions and the
    /// intent here is narrow enough not to need the type.
    private func wakeUpHostApp() {
        guard let url = URL(string: "\(AppGroup.wakeUpScheme)://import") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            let className = NSStringFromClass(type(of: current))
            if className.hasSuffix("Application"), current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
