//
//  ViewsApp.swift
//  Views
//
//  UIKit lifecycle, copied from the one app in this project's universe that
//  demonstrably does what the user asked for: the document-open path plus a real
//  `UIWindowSceneDelegate` (measured from 全能签's Info.plist, `UISceneDelegateClassName:
//  SceneDelegate`, no `.appex` anywhere in its bundle).
//
//  Why UIKit and not `@main struct App: SwiftUI.App`
//  -------------------------------------------------
//  The whole point of this file is to own the scene. Under SwiftUI's own `App` lifecycle
//  SwiftUI builds the `UISceneConfiguration` itself and installs `AppSceneDelegate`; a
//  custom delegate installed through `application(_:configurationForConnecting:options:)`
//  takes that configuration away from it, and `responds(to:)` then recurses until the main
//  thread runs off its stack:
//
//      Thread stack size exceeded due to excessive recursion
//      AppSceneDelegate.responds(to:)  ← repeating, self-recursive
//      @objc AppSceneDelegate.responds(to:)
//
//  That signature is recorded in `3D-Views-2026-10-01-162946.ips` from `72fdde7`, and it
//  is why `05edd08` deleted the delegate. The mistake was never the delegate itself — it
//  was asking SwiftUI for a scene and then not letting SwiftUI own it. Under UIKit there
//  is no SwiftUI scene delegate to collide with, so the same hook becomes safe. That is
//  exactly how 全能签 gets away with it.
//
//  Why this buys automatic hand-off
//  --------------------------------
//  The share extension makes a best-effort `extensionContext.open` request with
//  `views://import?handoff=1` after depositing the file. iOS may refuse that request, so the
//  App Group inbox remains the source of truth and the host also scans it on every activation.
//  When the request succeeds, the host receives the wake-up URL, consumes the inbox, and the
//  existing pending-open state automatically navigates to the viewer.
//
//  The share extension has since been removed from the bundle (user's call: copy 全能签
//  outright, and it carries no `.appex` at all). So this file is now the *only* import
//  path, and the document-open route below is the whole mechanism — nothing runs beside it
//  any more. The extension's source and target are still in the repository and can be
//  re-embedded with a two-line change to `project.yml`; until then the App Group inbox it
//  used to fill will simply stay empty, and the diagnostics page says so rather than
//  reporting it as a fault.

import SwiftUI
import UIKit

/// Owns the launch and the scene.
///
/// The scene delegate below is installed from `application(_:configurationForConnecting:options:)`
/// rather than declared statically in `Info.plist` (which is what 全能签 does, with a bare
/// `UISceneDelegateClassName: SceneDelegate`), for one concrete reason: `info.properties`
/// is the only place XcodeGen reads, and CI regenerates the plist on every run, so a class
/// name written there is a second copy of an identifier that belongs to this file. Setting
/// `delegateClass` keeps the reference and the name together, and it cannot go stale when
/// `PRODUCT_NAME` changes the module (formerly `3D-Views` → `3D_Views`; now simply `Views`,
/// so the module and the Objective-C runtime name finally agree).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// A cold launch caused by opening a document can carry the URL here instead of
    /// through the scene. Recording the no-URL case too is deliberate: it is
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
        // depositing into the inbox, both carry no file URL: in each the file is waiting
        // to be found, not handed over. `scheduleInboxSweep` looks now and again a few
        // seconds later, because at this instant iOS may not have finished copying the
        // file in yet — a single scan here can see an empty folder and be right about it.
        FileHistory.shared.consumePendingShareImportIfNeeded(reason: "冷启动")
        FileHistory.shared.scheduleInboxSweep(reason: "冷启动")
        return true
    }

    /// Installs `SceneDelegate` for the application's scene.
    ///
    /// This is the hook `05edd08` recorded as fatal, and it is fatal *only* under SwiftUI's
    /// `App` lifecycle. Here the app is a plain `UIApplicationDelegate`, SwiftUI never
    /// builds a scene for itself, and there is no `AppSceneDelegate` in play to recurse.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// A URL that arrived through the non-scene door, kept wired as a second sighting.
    /// `FileHistory.receiveExternalFile(at:source:)` recognises a repeat of the same URL,
    /// so a lifecycle that knocks on both doors still imports once.
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        FileHistory.shared.handleIncomingURL(url, source: "AppDelegate")
        return true
    }

    /// A return to the foreground is when the share extension's handover becomes visible,
    /// and it is the only hook that runs for a launch the app slept through.
    func applicationDidBecomeActive(_ application: UIApplication) {
        FileHistory.shared.consumePendingShareImportIfNeeded(reason: "回到前台")
        FileHistory.shared.scheduleInboxSweep(reason: "回到前台")
    }
}

/// Builds the window and takes the URL.
///
/// `HomeView` is mounted through `UIHostingController` instead of `WindowGroup`, which is
/// the whole cost of this migration: SwiftUI views survive it untouched, but `@Environment(\.scenePhase)`
/// and `.onOpenURL` are properties of SwiftUI's *scene* and have to be re-checked on device.
/// `HomeView` reaches the inbox through `scheduleInboxSweep` on every foreground anyway, and
/// that scan is what actually performs the import — so the share-extension path does not
/// depend on `scenePhase` continuing to fire.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: HomeView())
        self.window = window
        window.makeKeyAndVisible()

        // A cold launch from 「打开方式」 or a share sheet arrives here, as
        // `connectionOptions.urlContexts` rather than as `launchOptions[.url]` — the blind
        // spot this project spent six rounds inside, and the reason the migration is worth
        // its cost.
        handle(connectionOptions.urlContexts, source: "SceneDelegate 冷启动")
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts, source: "SceneDelegate")
    }

    /// 全能签在 scene 回到前台时再次消费分享桥接；这里同样处理，覆盖 AppDelegate
    /// 通知与 SwiftUI scene 状态没有可靠变化的冷启动/恢复场景。
    func sceneWillEnterForeground(_ scene: UIScene) {
        FileHistory.shared.consumePendingShareImportIfNeeded(reason: "scene 回前台")
        FileHistory.shared.scheduleInboxSweep(reason: "scene 回前台")
    }

    /// Also the hook that catches a handover while the app is already running, which is
    /// every share that comes back to a warm app.
    func sceneDidBecomeActive(_ scene: UIScene) {
        FileHistory.shared.consumePendingShareImportIfNeeded(reason: "回到前台")
        FileHistory.shared.scheduleInboxSweep(reason: "回到前台")
    }

    private func handle(_ contexts: Set<UIOpenURLContext>, source: String) {
        for context in contexts {
            FileHistory.shared.handleIncomingURL(context.url, source: source)
        }
        FileHistory.shared.scheduleInboxSweep(reason: source)
    }
}
