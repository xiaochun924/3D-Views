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

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("构建号", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                LabeledContent("渲染引擎", value: "OCCT + SceneKit")
            }

            Section {
                Text("支持 STEP（.step、.stp）和 STL 文件。点击右上角按钮导入文件，或在「文件」App 中选择分享到本应用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("支持格式")
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
}

#Preview {
    NavigationStack { SettingsView() }
}
