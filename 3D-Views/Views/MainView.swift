//
//  MainView.swift
//  3D-Views
//
//  Liquid-glass floating top bar, transparent nav, capsule title.
//

import SwiftUI
import SceneKit
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var viewModel = ViewerViewModel()
    @State private var showImporter = false
    @State private var showHelp = false

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.loadError != nil },
            set: { if !$0 { viewModel.loadError = nil } }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            SceneView(viewModel: viewModel)
                .ignoresSafeArea()

            floatingGlassBar

            VStack {
                Spacer()
                bottomDock
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showImporter) {
            DocumentPicker { url in
                Task { await viewModel.loadFile(url: url) }
            }
        }
        .onOpenURL { url in
            // File opened via "Open with" / share sheet from Files.app
            Task { await viewModel.loadFile(url: url) }
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("Cannot open file"),
                message: Text(viewModel.loadError ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var floatingGlassBar: some View {
        HStack(spacing: 12) {
            Button {
            } label: {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            HStack(spacing: 6) {
                Image(systemName: "rotate.3d")
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.fileName.isEmpty ? "3D Views" : viewModel.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomDock: some View {
        VStack(spacing: 12) {
            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model…")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }

            if let dist = viewModel.lastDistance {
                HStack(spacing: 8) {
                    Image(systemName: "ruler")
                        .foregroundStyle(.blue)
                    Text("Distance: \(viewModel.displayUnit.format(dist))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Button {
                        viewModel.resetMeasurement()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                dockButton(icon: "folder", label: "Open") {
                    showImporter = true
                }

                dockButton(
                    icon: viewModel.mode == .measurePoint ? "ruler.fill" : "ruler",
                    label: "Measure",
                    highlighted: viewModel.mode == .measurePoint
                ) {
                    viewModel.mode = viewModel.mode == .measurePoint ? .orbit : .measurePoint
                }

                dockButton(icon: "rotate.left", label: "Reset") {
                    viewModel.resetMeasurement()
                }

                Menu {
                    ForEach(DisplayUnit.allCases, id: \.self) { unit in
                        Button(unit.rawValue) { viewModel.displayUnit = unit }
                    }
                } label: {
                    dockButtonContent(icon: "units", label: viewModel.displayUnit.rawValue)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.lastDistance != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isLoading)
    }

    private func dockButton(icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            dockButtonContent(icon: icon, label: label, highlighted: highlighted)
        }
    }

    private func dockButtonContent(icon: String, label: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : Color.secondary)
        }
        .frame(width: 60, height: 56)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.blue)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
            }
        }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    helpSection(title: "Supported formats",
                                items: [
                                    "STEP (.step / .stp) — native CAD exchange format.",
                                    "STL (.stl) — triangulated mesh.",
                                    "SolidWorks (.SLDPRT / .SLDASM) cannot be opened directly; please use File ▸ Save As ▸ STEP in SolidWorks first, then open the exported .step file here."
                                ])
                    helpSection(title: "How to open a file",
                                items: [
                                    "Method 1: tap the Open button in the dock, then pick a .step/.stp/.stl file.",
                                    "Method 2: in the Files app, long-press a CAD file, choose Share ▸ 3D Views, or tap the file and pick 3D Views as the target app.",
                                    "The model will load automatically once 3D Views opens."
                                ])
                    helpSection(title: "Gestures",
                                items: [
                                    "One finger drag — orbit the model.",
                                    "Pinch — zoom in / out.",
                                    "Two-finger drag — pan.",
                                    "Tap a surface (in Measure mode) — pick a point; tap a second point to read the distance."
                                ])
                    helpSection(title: "Measurement",
                                items: [
                                    "Tap the ruler button to enter measure mode.",
                                    "Tap two points on the part; the straight-line distance appears above the dock.",
                                    "Switch display units (mm / cm / in / m) from the units menu."
                                ])
                }
                .padding()
            }
            .navigationTitle("About 3D Views")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func helpSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item).font(.subheadline)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    MainView()
}
