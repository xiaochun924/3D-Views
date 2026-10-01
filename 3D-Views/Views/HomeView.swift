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
                diagnosticSection
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
            .alert(
                "无法导入",
                isPresented: Binding(
                    get: { history.importFailure != nil },
                    set: { if !$0 { history.importFailure = nil } }
                ),
                presenting: history.importFailure
            ) { _ in
                Button("好", role: .cancel) {}
            } message: { reason in
                // The handover path used to end in a silent `nil`, so a share that
                // could not be carried out was indistinguishable from one that never
                // arrived — the app just sat on the file list. Saying why is the whole
                // point of keeping the failure around.
                Text(reason)
            }
        }
    }

    /// Temporary. Shows what the *installed* build declares and what the system has
    /// actually told the app, because the report being chased — "the app comes forward
    /// and nothing else happens" — looks the same whether the URL was never delivered,
    /// was delivered to a hook that was never installed, or arrived and was rejected.
    /// Two rounds were spent guessing between those; this is what replaces guessing.
    /// Delete this section, and `FileHistory.handoverLog` / `bundleFacts()`, once the
    /// external handover is confirmed working.
    @ViewBuilder
    private var diagnosticSection: some View {
        Section {
            if history.handoverLog.isEmpty {
                Text("尚无记录")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.handoverLog, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(FileHistory.bundleFacts(), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("导入诊断")
        } footer: {
            Text("上半部分是系统告知本 App 的记录，下半部分是当前安装包自己的声明。用于定位外部分享问题，定位完即删。")
                .font(.system(size: 10))
        }
    }

    private func openPicker() {
        DocumentPicker.shared.present(
            onPicked: { url in
                // `asCopy: true` means this URL is already a sandbox copy, so the only
                // way the import fails is a genuine file-system problem — which is
                // worth saying out loud rather than navigating to a file that is not
                // there.
                do {
                    let file = try history.addFile(sourceURL: url)
                    history.importFailure = nil
                    navPath.append(file)
                } catch {
                    history.importFailure = "导入失败：\(error.localizedDescription)"
                }
            },
            onCancel: {}
        )
    }
}

#Preview {
    HomeView()
}
