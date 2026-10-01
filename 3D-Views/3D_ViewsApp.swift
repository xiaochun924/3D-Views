//
//  3D_ViewsApp.swift
//  3D-Views
//

import SwiftUI
import UIKit

/// Takes the document handover on the lifecycle that SwiftUI's `onOpenURL` cannot reach.
///
/// A URL opened from outside the app arrives at one of two doors, and which door is in
/// use is not the app's choice. `onOpenURL` covers the SwiftUI scene lifecycle.
/// `application(_:open:options:)` covers an app that UIKit is running on the legacy,
/// pre-iOS-13 lifecycle — which is what happens when `Info.plist` carries no usable
/// `UIApplicationSceneManifest`.
///
/// `c5affb9` removed that manifest in the belief that it blocked `onOpenURL`. What it
/// removed was an empty `<dict/>`, which is not a well-formed manifest, so that
/// diagnosis is at least as likely to have been about the malformation as about having
/// one at all. A well-formed manifest has since been put back: it is what a SwiftUI app
/// is supposed to ship, and its absence is the best remaining explanation for
/// `onOpenURL` never firing here.
///
/// The delegate below stays wired regardless. Whichever door the system picks is enough
/// on its own, and `FileHistory.receiveExternalFile(at:source:)` recognises a second
/// sighting of the same URL, so a lifecycle that knocks on both still imports once.
///
/// Both doors, and the cold-launch path, leave a line in `FileHistory.handoverLog`
/// naming which one was used. The report that sent us here — "the app comes forward and
/// nothing happens" — is what a dropped URL, an uninstalled hook, and a rejected file
/// all look like from the outside; the log is what tells them apart.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// A cold launch caused by opening a document can carry the URL here instead of
    /// through either door below. Recording the no-URL case too is deliberate: it is
    /// what separates "the share sheet started the app and the URL went missing" from
    /// "the app was already running and the URL went missing".
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            FileHistory.shared.note("冷启动，launchOptions 带 URL：\(url.lastPathComponent)")
        } else {
            FileHistory.shared.note("冷启动，launchOptions 无 URL")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        FileHistory.shared.receiveExternalFile(at: url, source: "AppDelegate")
        return true
    }
}

@main
struct ViewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HomeView()
                // The SwiftUI-side door.
                .onOpenURL { url in
                    FileHistory.shared.receiveExternalFile(at: url, source: "onOpenURL")
                }
        }
    }
}
