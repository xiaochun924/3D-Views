//
//  SettingsView.swift
//  Views
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
            } header: {
                Text("支持格式")
            } footer: {
                Text("支持 STEP（.step、.stp）、IGES（.iges、.igs）、STL、OBJ、BREP 文件。其中 STEP / IGES / BREP 带实体拓扑，可以量测面、边、顶点；STL 和 OBJ 只有三角网格，只能量测点与距离。SolidWorks、Parasolid 等原生格式读不了，请在原软件里另存为 STEP 或 IGES。点击右上角按钮导入文件，或在「文件」App 中选择分享到本应用。")
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
}

#Preview {
    NavigationStack { SettingsView() }
}
