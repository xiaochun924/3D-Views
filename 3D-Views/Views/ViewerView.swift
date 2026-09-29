//
//  ViewerView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct ViewerView: View {
    let file: RecentFile
    @StateObject private var viewModel = ViewerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            SceneView(
                scene: viewModel.scene,
                onMeasureTap: { pos in viewModel.handleTap(pos) },
                measureMode: viewModel.mode == .measurePoint
            )
            .ignoresSafeArea()

            VStack {
                debugBanner
                Spacer()
                bottomDock
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .alert(isPresented: errorBinding) {
            Alert(title: Text("Error"),
                  message: Text(viewModel.loadError ?? ""),
                  dismissButton: .default(Text("OK")))
        }
        .task {
            await viewModel.loadFile(url: file.fileURL)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.loadError != nil },
            set: { if !$0 { viewModel.loadError = nil } }
        )
    }

    private var debugBanner: some View {
        HStack(spacing: 6) {
            Circle().fill(viewModel.isLoading ? Color.orange : Color.green).frame(width: 8, height: 8)
            Text(viewModel.isLoading ? "loading..." : (viewModel.debugInfo.isEmpty ? "ready" : viewModel.debugInfo))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
            if viewModel.isLoading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private var bottomDock: some View {
        VStack(spacing: 12) {
            if let dist = viewModel.lastDistance {
                HStack(spacing: 8) {
                    Image(systemName: "ruler").foregroundStyle(.blue)
                    Text("Distance: \(viewModel.displayUnit.format(dist))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Button { viewModel.resetMeasurement() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }

            HStack(spacing: 12) {
                dockButton(
                    icon: viewModel.mode == .measurePoint ? "ruler.fill" : "ruler",
                    label: viewModel.mode == .measurePoint ? "Measuring" : "Measure",
                    highlighted: viewModel.mode == .measurePoint
                ) {
                    viewModel.mode = viewModel.mode == .measurePoint ? .orbit : .measurePoint
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
    }

    private func dockButton(icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    private func dockButtonContent(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(width: 60, height: 56)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }
}
