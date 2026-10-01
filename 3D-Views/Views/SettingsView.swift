//
//  SettingsView.swift
//  3D-Views
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultUnit") private var defaultUnit = "mm"
    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("autoRotate") private var autoRotate = false

    var body: some View {
        Form {
            Section("查看器") {
                Picker("默认单位", selection: $defaultUnit) {
                    Text("毫米").tag("mm")
                    Text("厘米").tag("cm")
                    Text("英寸").tag("in")
                    Text("米").tag("m")
                }
                Toggle("显示网格", isOn: $showGrid)
                Toggle("自动旋转", isOn: $autoRotate)
            }

            shareSection

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("构建号", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                LabeledContent("渲染引擎", value: "OCCT + SceneKit")
            }

            Section {
                NavigationLink {
                    ImportLogView()
                } label: {
                    Label("导入诊断", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("支持格式")
            } footer: {
                Text("支持 STEP（.step、.stp）和 STL 文件。点击右上角按钮导入文件，或在「文件」App 中选择分享到本应用。分享没反应时，导入诊断里能看到文件走到了哪一步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    /// The share extension and the app can only see each other through the App Group
    /// container, and whether that container exists is decided at signing time rather
    /// than at build time — the IPA ships unsigned, so the entitlement has to be applied
    /// afterwards by whatever installs it. When it is missing there is no error anywhere:
    /// the extension has nowhere to put the file, the app finds nothing to pick up, and
    /// the share simply does nothing. That is why the identifier is shown here, together
    /// with whether the container behind it actually opened.
    @ViewBuilder
    private var shareSection: some View {
        Section {
            LabeledContent("App Group") {
                Text(AppGroup.identifier)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LabeledContent("共享容器") {
                if AppGroup.isAvailable {
                    Label("可用", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Label("不可用", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            LabeledContent("待取文件", value: "\(FileHistory.shared.sharedInboxFileCount()) 个")
        } header: {
            Text("分享与导入")
        } footer: {
            Text(AppGroup.isAvailable
                 ? "分享到本应用的文件会先放进共享容器，再在应用回到前台时导入。"
                 : "共享容器未打开：当前安装包的签名里没有这个 App Group，分享扩展无法把文件交给本应用。需要在签名时带上该 App Group 权限。")
                .font(.system(size: 10))
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
