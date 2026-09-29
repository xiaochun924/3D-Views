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
            Section("Viewer") {
                Picker("Default Unit", selection: $defaultUnit) {
                    Text("Millimeters").tag("mm")
                    Text("Centimeters").tag("cm")
                    Text("Inches").tag("in")
                }
                Toggle("Show Grid", isOn: $showGrid)
                Toggle("Auto Rotate", isOn: $autoRotate)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                LabeledContent("Engine", value: "OCCT + SceneKit")
            }

            Section {
                Text("3D Views supports STEP (.step, .stp) and STL files. Use Open to import, or share files from the Files app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Supported Formats")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
