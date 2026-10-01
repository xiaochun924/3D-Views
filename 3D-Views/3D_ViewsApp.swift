//
//  3D_ViewsApp.swift
//  3D-Views
//

import SwiftUI
import UIKit

/// Takes the document handover on the lifecycle that SwiftUI's `onOpenURL` cannot reach.
///
/// A URL opened from outside the app arrives at one of two doors, and which door is in
/// use is not the app's choice. `onOpenURL` covers the SwiftUI scene lifecycle. But an
/// app whose `Info.plist` carries no `UIApplicationSceneManifest` — and this one
/// deliberately does not, see `c5affb9` — is run by UIKit on the legacy, pre-iOS-13
/// lifecycle instead, where document URLs are delivered to
/// `application(_:open:options:)` and never reach a scene at all.
///
/// That mismatch is exactly the report that sent us here: the share sheet hands the file
/// over, the app comes forward, and nothing else happens — no import, and not even the
/// rejection message, because the URL was dropped a layer below the SwiftUI handler.
///
/// Both doors are left wired. Whichever the system uses is enough on its own, and
/// `FileHistory.receiveExternalFile(at:)` recognises a second sighting of the same URL
/// so a lifecycle that knocks on both only imports once.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        FileHistory.shared.receiveExternalFile(at: url)
        return true
    }
}

@main
struct ViewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HomeView()
                // The SwiftUI-side door. Kept even though the delegate above is the one
                // that currently does the work: if a future change restores a scene
                // manifest, this becomes the live path and the delegate goes quiet.
                .onOpenURL { url in
                    FileHistory.shared.receiveExternalFile(at: url)
                }
        }
    }
}
