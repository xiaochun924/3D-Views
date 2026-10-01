//
//  HomeView.swift
//  3D-Views
//

import SwiftUI

struct HomeView: View {
    @StateObject private var history = FileHistory.shared
    @State private var navPath = NavigationPath()
    @State private var showSettings = false
    @State private var showImportLog = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                if history.files.isEmpty {
                    ContentUnavailableView(
                        "暂无文件",
                        systemImage: "cube.transparent",
                        description: Text("点击左上角按钮导入文件。\n支持 STEP、IGES、STL、OBJ、BREP。也可以把文件拷进「文件」App →「我的 iPhone」→「3D Views」，回到本应用会自动导入。")
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
                ToolbarItem(placement: .topBarLeading) {
                    // Out of the list and behind a button of its own. Kept in the toolbar
                    // rather than buried in Settings because it is needed at exactly the
                    // moment something fails to arrive, which is on this screen.
                    Button {
                        showImportLog = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("导入诊断")
                }
            }
            .navigationDestination(for: RecentFile.self) { file in
                ViewerView(file: file)
            }
            .navigationDestination(isPresented: $showImportLog) {
                ImportLogView()
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
            // The other half of the sandbox scan. A file copied into the app's own folder
            // in Files — or left in the shared inbox by the share extension — arrives
            // while the app may already be running, so nothing in the launch sequence
            // would ever notice it, and coming back to the foreground is when to look.
            // `scheduleInboxSweep` rather than a bare scan: this observer alone is not
            // enough, because a cold launch can mount the view already `.active` and then
            // there is no change for `onChange` to report at all.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                history.scheduleInboxSweep(reason: "回到前台")
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

    private func openPicker() {
        DocumentPicker.shared.present(
            onPicked: { url in
                // `asCopy: true` means this URL is already a sandbox copy, so the only
                // way the import fails is a genuine file-system problem — which is
                // worth saying out loud rather than navigating to a file that is not
                // there.
                // This picker path is the one that works, so it is also the only way to
                // see what UTI the system tags a real STEP/STL with on this device.
                history.note("文件选择器拿到：\(url.lastPathComponent)（\(FileHistory.describeType(of: url))）")
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
