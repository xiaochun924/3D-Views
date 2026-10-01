//
//  3D_ViewsApp.swift
//  3D-Views
//

import SwiftUI

@main
struct ViewsApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                // The share sheet's 「导入到"3D Views"」 and Files open-in deliver the
                // document here. Without this handler the app activates and simply
                // shows the file list — the URL is dropped on the floor.
                .onOpenURL { url in
                    FileHistory.shared.receiveExternalFile(at: url)
                }
        }
    }
}
