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
        // Which keys are present is the whole evidence, so they are listed rather than
        // summarised. "No URL" on its own cannot distinguish a share that carried nothing
        // from a share whose URL was routed to the scene instead — iOS only fills
        // `launchOptions[.url]` when UIKit, not a scene, owns the launch.
        let keys = (launchOptions ?? [:])
            .keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let keyText = keys.isEmpty ? "空" : keys
        if let url = launchOptions?[.url] as? URL {
            FileHistory.shared.note("冷启动，带 URL：\(url.lastPathComponent)｜键：\(keyText)")
        } else {
            FileHistory.shared.note("冷启动，无 URL｜键：\(keyText)")
        }
        // A launch caused by 「拷贝到 3D Views」, and one caused by the share extension
        // waking us through `3dviews://`, both carry no file URL: in each the file is
        // waiting to be found, not handed over. `scheduleInboxSweep` looks now and again a
        // few seconds later, because at this instant iOS may not have finished copying the
        // file into `Documents/Inbox` yet — a single scan here can see an empty folder and
        // be right about it.
        FileHistory.shared.scheduleInboxSweep(reason: "冷启动")
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        FileHistory.shared.handleIncomingURL(url, source: "AppDelegate")
        return true
    }

    // `application(_:configurationForConnecting:options:)` is NOT implemented, and the
    // `SceneDelegate` that replaced SwiftUI's own scene delegate has been removed with it.
    //
    // It was re-added to catch a cold-launch URL arriving as `connectionOptions.urlContexts`
    // — the blind spot this project spent six rounds inside. On the device the result was
    // the opposite of a fix: tapping 「打开 3D Views」 in the share extension made the sheet
    // disappear with no foreground app at all. The recorded crash from the earlier attempt
    // at this same hook (`72fdde7`, `3D-Views-2026-10-01-162946.ips`) is the same failure:
    //
    //     Thread stack size exceeded due to excessive recursion
    //     AppSceneDelegate.responds(to:)  ← repeating, self-recursive
    //     @objc AppSceneDelegate.responds(to:)
    //
    // Handing UIKit our own configuration takes the scene away from SwiftUI, and the app
    // then dies during launch. iOS does not surface that to the user: the extension's
    // `open` request is simply abandoned, which looks exactly like a URL that never fired.
    //
    // Both URL doors that do work stay wired: `application(_:open:options:)` above and
    // `.onOpenURL` on the window group.

    /// A return to the foreground is the moment the share extension's handover becomes
    /// visible, and it is the only hook that runs for a launch the app slept through.
    /// `HomeView` watches `scenePhase` too, but a cold launch can mount the view already
    /// `.active`, so `onChange` has no change to report; this notification has no such gap.
    func applicationDidBecomeActive(_ application: UIApplication) {
        FileHistory.shared.scheduleInboxSweep(reason: "回到前台")
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
                    FileHistory.shared.handleIncomingURL(url, source: "onOpenURL")
                }
        }
    }
}
