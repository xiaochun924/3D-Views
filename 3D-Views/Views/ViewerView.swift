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
                measureMode: viewModel.mode == .measure
            )
            .ignoresSafeArea()

            // Loading overlay
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("加载中...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            // Measure instruction
            if viewModel.mode == .measure && viewModel.pickedPoints.isEmpty {
                VStack {
                    Spacer().frame(height: 60)
                    HStack {
                        Spacer()
                        Text("点选模型上的两个点进行测量")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
            }

            // Measure result panel
            if let result = viewModel.measureResult {
                VStack {
                    Spacer().frame(height: 56)
                    HStack {
                        Spacer()
                        measurePanel(result)
                        Spacer()
                    }
                    Spacer()
                }
            }

            // Bottom toolbar
            VStack {
                Spacer()
                bottomToolbar
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

    // MARK: - Measure panel (SolidWorks style)

    private func measurePanel(_ result: MeasureResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "ruler")
                    .foregroundColor(.blue)
                Text("测量结果")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    viewModel.clearMeasure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Main distance
            VStack(spacing: 4) {
                Text("距离")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(viewModel.displayUnit.format(result.distance))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 10)

            Divider()

            // X/Y/Z deltas
            HStack(spacing: 0) {
                deltaColumn(label: "X", value: result.deltaX, color: .red)
                Divider().frame(height: 36)
                deltaColumn(label: "Y", value: result.deltaY, color: .green)
                Divider().frame(height: 36)
                deltaColumn(label: "Z", value: result.deltaZ, color: .blue)
            }
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func deltaColumn(label: String, value: Float, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "ruler", label: "测量",
                          highlighted: viewModel.mode == .measure) {
                viewModel.toggleMeasureMode()
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
                toolbarButtonContent(icon: "number", label: viewModel.displayUnit.rawValue)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func toolbarButton(icon: String, label: String,
                               highlighted: Bool = false,
                               action: @escaping () -> Void) -> some View {
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
