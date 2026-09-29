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
        ZStack {
            Color(.systemGray6).ignoresSafeArea()

            SceneView(
                scene: viewModel.scene,
                onMeasureTap: { pos in viewModel.handleTap(pos) },
                measureMode: viewModel.mode == .measurePoint
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                        Text("加载中...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .padding(.top, 8)
                Spacer()
            }

            VStack {
                Spacer()
                bottomBar
            }
        }
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbarBackground(.hidden)
        .alert(isPresented: errorBinding) {
            Alert(title: Text("错误"),
                  message: Text(viewModel.loadError ?? ""),
                  dismissButton: .default(Text("确定")))
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

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let dist = viewModel.lastDistance {
                HStack(spacing: 8) {
                    Image(systemName: "ruler")
                    Text(viewModel.displayUnit.format(dist))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Button { viewModel.resetMeasurement() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .padding(.horizontal, 16).frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }

            HStack(spacing: 0) {
                toolbarButton(icon: "ruler", label: "测量", highlighted: viewModel.mode == .measurePoint) {
                    viewModel.mode = viewModel.mode == .measurePoint ? .orbit : .measurePoint
                }
                toolbarButton(icon: "arrow.2.squarepath", label: "复位") {
                    // TODO: reset camera
                }
                toolbarButton(icon: "cube", label: "视图") {
                    // TODO: view presets
                }
                Menu {
                    ForEach(DisplayUnit.allCases, id: \.self) { unit in
                        Button(unit.rawValue) { viewModel.displayUnit = unit }
                    }
                } label: {
                    toolbarButtonContent(icon: "units", label: viewModel.displayUnit.rawValue)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func toolbarButton(icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(highlighted ? Color.blue : Color.primary)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(highlighted ? Color.blue : Color.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func toolbarButtonContent(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
