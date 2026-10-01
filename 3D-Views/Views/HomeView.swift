//
//  HomeView.swift
//  3D-Views
//

import SwiftUI

struct HomeView: View {
    @StateObject private var history = FileHistory.shared
    @State private var navPath = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                if history.files.isEmpty {
                    ContentUnavailableView(
                        "暂无文件",
                        systemImage: "cube.transparent",
                        description: Text("点击右上角按钮导入 STEP 或 STL 文件。")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    Section("最近文件") {
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
            .navigationTitle("3D 看图")
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
            .onReceive(history.$pendingOpen) { entry in
                // onReceive, not onChange: @Published replays the current value on
                // subscribe, so a file handed over during a cold launch — before any
                // observer existed — still reaches the navigation stack.
                guard let entry else { return }
                navPath.append(entry)
                history.pendingOpen = nil
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
