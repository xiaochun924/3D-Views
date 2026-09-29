//
//  HomeView.swift
//  3D-Views
//

import SwiftUI

struct HomeView: View {
    @StateObject private var history = FileHistory.shared
    @State private var navPath = NavigationPath()
    @State private var pendingFile: RecentFile?
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                if history.files.isEmpty {
                    ContentUnavailableView(
                        "No Files Yet",
                        systemImage: "cube.transparent",
                        description: Text("Tap Open to import a STEP or STL file.")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    Section("Recent Files") {
                        ForEach(history.files) { file in
                            Button {
                                navPath.append(file)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: file.fileName.lowercased().hasSuffix("stl") ? "cube" : "cube.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                        .frame(width: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.fileName)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(file.openedAt, format: .relative(presentation: .named))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                history.removeFile(history.files[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("3D Views")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openPicker()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .navigationDestination(for: RecentFile.self) { file in
                ViewerView(file: file)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }

    private func openPicker() {
        DocumentPicker.shared.present(
            onPicked: { url in
                let file = history.addFile(sourceURL: url)
                navPath.append(file)
            },
            onCancel: {}
        )
    }
}

#Preview {
    HomeView()
}
