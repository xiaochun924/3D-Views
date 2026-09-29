//
//  ViewerView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct ViewerView: View {
    let file: RecentFile
    @StateObject private var viewModel = ViewerViewModel()

    var body: some View {
        ZStack {
            Color(.systemGray6).ignoresSafeArea()

            SceneView(
                scene: viewModel.scene,
                onMeasureTap: { pos in viewModel.handleTap(pos) },
                measureMode: viewModel.mode == .measure
            )
            .ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("加载中...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            if viewModel.mode == .measure && viewModel.pickedPoints.isEmpty {
                VStack {
                    Spacer().frame(height: 60)
                    HStack {
                        Spacer()
                        Text(instructionText)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
            }

            if viewModel.isComplete {
                VStack {
                    Spacer().frame(height: 56)
                    HStack {
                        Spacer()
                        resultPanel
                        Spacer()
                    }
                    Spacer()
                }
            }

            VStack {
                Spacer()
                if viewModel.mode == .measure {
                    measureToolbar
                } else {
                    mainToolbar
                }
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

    private var instructionText: String {
        switch viewModel.measureType {
        case .distance, .linear: return "点选模型上的两个点"
        case .angle: return "依次点选：点1、角顶点、点3"
        case .radius: return "在圆弧上点选三个点"
        }
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: viewModel.measureType.icon)
                    .foregroundColor(.blue)
                Text(viewModel.measureType.label)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { viewModel.clearMeasure() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            VStack(spacing: 4) {
                Text(mainResultLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(mainResultValue)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
            }
            .padding(.vertical, 10)

            if viewModel.measureType == .distance || viewModel.measureType == .linear {
                Divider()
                HStack(spacing: 0) {
                    deltaColumn(label: "X", value: viewModel.pickedPoints[1].x - viewModel.pickedPoints[0].x, color: .red)
                    Divider().frame(height: 36)
                    deltaColumn(label: "Y", value: viewModel.pickedPoints[1].y - viewModel.pickedPoints[0].y, color: .green)
                    Divider().frame(height: 36)
                    deltaColumn(label: "Z", value: viewModel.pickedPoints[1].z - viewModel.pickedPoints[0].z, color: .blue)
                }
                .padding(.vertical, 8)
            }

            if viewModel.measureType == .radius, let r = viewModel.radiusResult {
                Divider()
                HStack {
                    Text("直径").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Text(viewModel.displayUnit.format(r * 2))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    private var mainResultLabel: String {
        switch viewModel.measureType {
        case .distance, .linear: return "距离"
        case .angle: return "角度"
        case .radius: return "半径"
        }
    }

    private var mainResultValue: String {
        switch viewModel.measureType {
        case .distance, .linear:
            if let d = viewModel.distanceResult { return viewModel.displayUnit.format(d) }
        case .angle:
            if let a = viewModel.angleResult { return String(format: "%.2f°", a) }
        case .radius:
            if let r = viewModel.radiusResult { return viewModel.displayUnit.format(r) }
        }
        return "--"
    }

    private func deltaColumn(label: String, value: Float, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(color)
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    private var measureToolbar: some View {
        HStack(spacing: 0) {
            Button { viewModel.toggleMeasureMode() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
            }
            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(MeasureType.allCases) { type in
                        measureTypeButton(type)
                    }
                    Menu {
                        ForEach(DisplayUnit.allCases, id: \.self) { unit in
                            Button(unit.rawValue) { viewModel.displayUnit = unit }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "number").font(.system(size: 18, weight: .medium))
                            Text(viewModel.displayUnit.rawValue).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(width: 60, height: 48)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func measureTypeButton(_ type: MeasureType) -> some View {
        let selected = viewModel.measureType == type
        return Button { viewModel.selectMeasureType(type) } label: {
            VStack(spacing: 3) {
                Image(systemName: type.icon).font(.system(size: 18, weight: .medium))
                Text(type.label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(selected ? Color(red: 0.3, green: 0.8, blue: 0.9) : .white)
            .frame(width: 62, height: 48)
            .background(selected ? Color.white.opacity(0.15) : Color.clear)
        }
    }

    private var mainToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "ruler", label: "测量") { viewModel.toggleMeasureMode() }
            toolbarButton(icon: "arrow.2.squarepath", label: "复位") { }
            toolbarButton(icon: "cube", label: "视图") { }
            toolbarButton(icon: "slider.horizontal.3", label: "设置") { }
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
        }
    }
}
