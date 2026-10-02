//
//  ViewerView.swift
//  3D-Views
//

import SwiftUI
import SceneKit
import UIKit
import os

struct ViewerView: View {
    let file: RecentFile
    @StateObject private var viewModel = ViewerViewModel()
    @State private var showSettings = false
    @State private var copiedToPasteboard = false
    /// The same key `SettingsView` writes, so toggling the switch takes effect on the
    /// part already open rather than only on the next one.
    @AppStorage("autoRotate") private var autoRotate = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(.systemGray6).ignoresSafeArea()

            SceneView(
                scene: viewModel.scene,
                onMeasureTap: { point, view in
                    viewModel.handleTap(screenPoint: point, in: view)
                },
                onViewReady: { view in viewModel.attach(view: view) },
                onSceneAssigned: { view, scene in
                    viewModel.claimPointOfView(in: view, scene: scene)
                },
                onPreview: { point, view in
                    viewModel.handlePreview(screenPoint: point, in: view)
                },
                onPreviewCommitted: { view in
                    viewModel.commitPreview(in: view)
                },
                onPreviewCancelled: { _ in
                    viewModel.clearPreview()
                },
                onOrbit: { dx, dy, _ in
                    viewModel.orbit(dx: dx, dy: dy)
                },
                onPan: { dx, dy, view in
                    viewModel.pan(dx: dx, dy: dy, viewportHeight: view.bounds.height)
                },
                onZoom: { scale, _ in
                    viewModel.zoom(by: scale)
                },
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
                .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // Kept up until the measurement has all the picks it needs, not just until
            // the first one: entity measurements often need two, and hiding the hint
            // after one tap left the user with no idea what was still wanted. The
            // tally underneath doubles as the selection status — which is why the old
            // dedicated selection panel is gone. One capsule, nothing else floating.
            if viewModel.mode == .measure && !viewModel.isComplete {
                VStack {
                    Spacer().frame(height: 6)
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text(instructionText)
                                .font(.system(size: 13, weight: .medium))
                            if !viewModel.picks.isEmpty {
                                Text(pickProgressText)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
            }

            if viewModel.isComplete {
                VStack {
                    Spacer().frame(height: 6)
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
                    // One compact bar is all the mode keeps pinned to the bottom: the
                    // pick tally lives in the hint capsule, finished readings archive
                    // onto the model, and their controls live in the orbit toolbar.
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
        // The viewer owns the whole screen and its one-finger drag is orbit. A
        // right-swipe from the left edge would otherwise pop the navigation stack
        // mid-drag, which fights the camera gesture the user is actually trying to
        // make. Disabling the interactive pop keeps the swipe for orbit only.
        .disableInteractivePopGesture()
        .alert(isPresented: errorBinding) {
            Alert(title: Text("错误"),
                  message: Text(viewModel.loadError ?? ""),
                  dismissButton: .default(Text("确定")))
        }
        .task {
            await viewModel.loadFile(url: file.fileURL)
        }
        .onAppear {
            viewModel.setAutoRotation(autoRotate && scenePhase == .active)
        }
        .onDisappear {
            // Leaving the viewer must stop the timer: it would otherwise keep turning a
            // part nobody is looking at, and a repeating timer holds a strong reference
            // to its block until it is invalidated.
            viewModel.setAutoRotation(false)
        }
        .onChange(of: autoRotate) { _, isOn in
            viewModel.setAutoRotation(isOn && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            // Covers the app being backgrounded, where the timer would otherwise keep
            // ticking against a renderer that is no longer drawing.
            viewModel.setAutoRotation(autoRotate && phase == .active)
        }
        .sheet(isPresented: $showSettings) {
            // `SettingsView` supplies its own title and "完成" button, so it needs a
            // navigation container of its own when presented as a sheet.
            NavigationStack { SettingsView() }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.loadError != nil },
            set: { if !$0 { viewModel.loadError = nil } }
        )
    }

    private var instructionText: String {
        // A STEP import keeps real B-rep topology, so the pick resolves to a face,
        // edge or vertex and the kernel answers the question analytically. An STL is
        // only a triangle shell — there is nothing under a tap but a point — so it
        // keeps the older point-based wording.
        if viewModel.usesEntityMeasurement {
            return viewModel.measureType.entityHint
        }
        switch viewModel.measureType {
        case .distance, .linear: return "点选两点；靠近顶点或圆心会自动吸附"
        case .angle: return "依次点选：点1、角顶点、点3"
        case .radius: return "在圆弧上点选三个点"
        case .area: return "点选一个面；面积测量仅支持 STEP / IGES / BREP 模型"
        case .volume, .boundingBox: return "由模型外形直接计算，无需点选"
        }
    }

    /// "已选 2/3：面 3 · 边 2" — the in-progress tally under the instruction.
    ///
    /// Carried by the hint capsule instead of its own panel: the user needs to know
    /// what is already picked and how many picks remain, but that is two lines of
    /// text, not a list floating over the model.
    private var pickProgressText: String {
        let names = viewModel.picks.map { $0.entity.description }.joined(separator: " · ")
        return "已选 \(viewModel.picks.count)/\(viewModel.requiredPickCount)：\(names)"
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: viewModel.measureType.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
                Text(viewModel.measureType.label)
                    .font(.system(size: 12, weight: .semibold))
                // What the number belongs to, stated on the same line that names the
                // measurement. These chips were a row of their own until they were
                // folded in here — one less band laid across the model.
                ForEach(Array(viewModel.picks.enumerated()), id: \.element.id) { entry in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color(uiColor: entry.element.entity.markerColor))
                            .frame(width: 5, height: 5)
                        Text(entry.element.entity.description)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Spacer(minLength: 4)
                // Puts the reading on the clipboard — the most common thing to do
                // with a measured number is paste it into a drawing note or a chat.
                // The glyph flips to a checkmark for a beat so the tap has feedback.
                if viewModel.isComplete {
                    Button {
                        UIPasteboard.general.string = resultSummary
                        copiedToPasteboard = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copiedToPasteboard = false
                        }
                    } label: {
                        Image(systemName: copiedToPasteboard ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(copiedToPasteboard ? .green : .blue)
                    }
                    .accessibilityLabel("复制测量结果")
                }
                Button { viewModel.clearMeasure() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider()

            VStack(spacing: 4) {
                Text(mainResultValue)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: mainResultValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // A radius and its diameter are the same reading stated two ways, so
                // the panel carries one number and a switch rather than two rows.
                if viewModel.measureType == .radius, viewModel.isComplete {
                    radiusToggle
                }

                // The three distances are not one reading stated three ways — each is a
                // different computation — so this switch asks the model for a different
                // number rather than only re-rendering the one it already has. It needs
                // B-rep topology to have two entities to measure between, which is why
                // the STL case is left out.
                if (viewModel.measureType == .distance || viewModel.measureType == .linear),
                   viewModel.isComplete, viewModel.usesEntityMeasurement {
                    distanceToggle
                }
            }
            .padding(.vertical, 5)

            if (viewModel.measureType == .distance || viewModel.measureType == .linear),
               let delta = deltaVector {
                Divider()
                HStack(spacing: 0) {
                    deltaColumn(label: "X", value: delta.x, color: .red)
                    Divider().frame(height: 22)
                    deltaColumn(label: "Y", value: delta.y, color: .green)
                    Divider().frame(height: 22)
                    deltaColumn(label: "Z", value: delta.z, color: .blue)
                }
                .padding(.vertical, 4)
            }

            if viewModel.measureType == .boundingBox, let e = viewModel.boundingBoxExtents {
                Divider()
                VStack(spacing: 3) {
                    extentRow(icon: "arrow.left.and.right", label: "长 X", value: e.x)
                    extentRow(icon: "arrow.up.and.down", label: "宽 Y", value: e.y)
                    extentRow(icon: "cube", label: "高 Z", value: e.z)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            if let message = viewModel.measureMessage {
                Divider()
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(message)
                        .font(.system(size: 10, weight: .medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Wide tablets get a centered card, not a reading stretched across the screen.
        .frame(maxWidth: 400)
        .padding(.horizontal, 12)
    }

    /// 半径 ⇄ 直径: one reading, two ways of stating it.
    ///
    /// A two-segment capsule rather than a `Picker`, because this sits inside the
    /// reading card and a full-height segmented control would be the tallest thing
    /// in a panel that was just shrunk.
    ///
    /// It writes through to the model rather than to local state, so the number the
    /// card shows, the label floating on the geometry and the entry the history list
    /// keeps are all the same statement of the reading.
    private var radiusToggle: some View {
        HStack(spacing: 2) {
            radiusToggleSegment(icon: "r.circle", label: "半径", diameter: false)
            radiusToggleSegment(icon: "arrow.left.and.right", label: "直径", diameter: true)
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("半径或直径显示")
    }

    private func radiusToggleSegment(icon: String, label: String, diameter: Bool) -> some View {
        let selected = viewModel.radiusShowsDiameter == diameter
        return Button {
            withAnimation(.snappy(duration: 0.2)) { viewModel.radiusShowsDiameter = diameter }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(selected ? Color(.systemBackground) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 中心距 / 最小距离 / 最大距离: three answers to "how far apart".
    ///
    /// Same capsule treatment as the radius toggle above, and for the same reason — a
    /// full-height segmented control would be the tallest thing in a card that was
    /// just shrunk. Three labels is the most that will still fit across it.
    private var distanceToggle: some View {
        HStack(spacing: 2) {
            ForEach(DistanceMode.allCases) { mode in
                distanceToggleSegment(mode)
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("距离显示方式")
    }

    private func distanceToggleSegment(_ mode: DistanceMode) -> some View {
        let selected = viewModel.distanceMode == mode
        return Button {
            withAnimation(.snappy(duration: 0.2)) { viewModel.distanceMode = mode }
        } label: {
            Text(mode.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selected ? Color(.systemBackground) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The vector between the two endpoints of the measurement.
    ///
    /// Prefers the kernel's own closest points: for two faces or two edges the
    /// minimum-distance segment is generally nowhere near the tapped positions, so
    /// differencing the taps would misreport the direction.
    private var deltaVector: SCNVector3? {
        if let a = viewModel.closestPointA, let b = viewModel.closestPointB {
            return SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
        }
        guard viewModel.picks.count >= 2 else { return nil }
        let a = viewModel.picks[0].point
        let b = viewModel.picks[1].point
        return SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
    }

    /// The clipboard form: the labeled reading plus whatever breakdown the panel
    /// shows underneath, so a pasted value carries its meaning with it. A radius
    /// carries both statements of itself — the one on screen and its complement —
    /// because a pasted note is often read by someone who thinks in the other one.
    private var resultSummary: String {
        var lines = ["\(mainResultLabel)：\(mainResultValue)"]
        if (viewModel.measureType == .distance || viewModel.measureType == .linear),
           let delta = deltaVector {
            lines.append("ΔX \(viewModel.displayUnit.format(delta.x))")
            lines.append("ΔY \(viewModel.displayUnit.format(delta.y))")
            lines.append("ΔZ \(viewModel.displayUnit.format(delta.z))")
        }
        if viewModel.measureType == .radius, let r = viewModel.radiusResult {
            lines.append("半径：\(viewModel.displayUnit.format(r))")
            lines.append("直径：\(viewModel.displayUnit.format(r * 2))")
        }
        if viewModel.measureType == .boundingBox, let e = viewModel.boundingBoxExtents {
            lines.append("长 X \(viewModel.displayUnit.format(e.x))")
            lines.append("宽 Y \(viewModel.displayUnit.format(e.y))")
            lines.append("高 Z \(viewModel.displayUnit.format(e.z))")
        }
        return lines.joined(separator: "\n")
    }

    private var mainResultLabel: String {
        switch viewModel.measureType {
        case .distance, .linear:
            // On a STEP model the label names which of the three distances is showing;
            // an STL has no entities to measure between, so it keeps the plain reading.
            return viewModel.usesEntityMeasurement ? viewModel.distanceMode.label : "距离"
        case .angle: return "角度"
        case .radius: return viewModel.radiusShowsDiameter ? "直径" : "半径"
        case .area: return "面积"
        case .volume: return "体积"
        case .boundingBox: return "包围盒尺寸"
        }
    }

    private var mainResultValue: String {
        switch viewModel.measureType {
        case .distance, .linear:
            if let d = viewModel.distanceResult { return viewModel.displayUnit.format(d) }
        case .angle:
            if let a = viewModel.angleResult { return String(format: "%.2f°", a) }
        case .radius:
            // One number, stated as radius or as diameter — the toggle above decides
            // which, and both come from the same kernel reading.
            if let r = viewModel.radiusResult {
                return viewModel.displayUnit.format(viewModel.radiusShowsDiameter ? r * 2 : r)
            }
        case .area:
            if let a = viewModel.areaResult { return viewModel.displayUnit.formatArea(a) }
        case .volume:
            if let v = viewModel.volumeResult { return viewModel.displayUnit.formatVolume(v) }
        case .boundingBox:
            // A box has no single number, so the summary line carries the largest extent
            // and the per-axis breakdown below carries the rest.
            if let e = viewModel.boundingBoxExtents {
                let longest = max(e.x, max(e.y, e.z))
                return viewModel.displayUnit.format(longest)
            }
        }
        return "--"
    }

    private func deltaColumn(label: String, value: Float, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(color)
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    /// One axis of the bounding box: icon, axis label, extent.
    private func extentRow(icon: String, label: String, value: Float) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.blue)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }

    /// The measure-mode toolbar: one compact row.
    ///
    /// Exit/undo sits fixed on the left, the display menu fixed on the right, and the
    /// seven measurement types scroll in between. Display mode is offered here too:
    /// seeing inside a bore to pick its wall is often *why* one reaches for 透明 or
    /// 线框, and having to leave measure mode to change it made those two picks
    /// impossible in the one situation that calls for them. Switching does drop the
    /// picks in progress — the scene graph is rebuilt — but a finished reading
    /// survives either way.
    ///
    /// The unit menu used to sit beside it and is gone. It was the only place the unit
    /// could be changed from the viewer, but it is a setting, not a control: it is set
    /// once and then left alone, while this row is the scarcest space in the app — it
    /// has to hold eight measurement types beside a scrolling list. 设置 already
    /// carries 默认单位 and the model reads that same `defaultUnit` key at init, so
    /// removing this costs no capability, only a detour through the settings sheet.
    private var measureToolbar: some View {
        HStack(spacing: 0) {
            toolButton(icon: viewModel.picks.isEmpty ? "xmark" : "arrow.uturn.backward.circle",
                       label: viewModel.picks.isEmpty ? "退出" : "撤销") {
                if viewModel.picks.isEmpty {
                    viewModel.toggleMeasureMode()
                } else {
                    viewModel.undoLastPoint()
                }
            }

            toolRowDivider

            measureTypeRow

            toolRowDivider

            displayModeMenu(compact: true)
        }
        .padding(.vertical, 5)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var measureTypeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(measureTypeGroups.enumerated()), id: \.element.title) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 34)
                            .padding(.horizontal, 5)
                    }
                    // The group captions (距离 / 形状 / 模型) are gone: the divider
                    // already separates the runs, and at 9pt the captions cost a row
                    // of height while saying only what the icons say better.
                    HStack(spacing: 0) {
                        ForEach(group.types) { type in
                            measureTypeButton(type)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var toolRowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 30)
    }

    /// A labelled icon+text button at the toolbar's fixed edges — the scrolling
    /// type row takes the middle, so these get a fixed width instead of a share.
    private func toolButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(width: 54, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The measurement types as displayed groups: distance questions, shape
    /// questions answered from one or two picked entities, and whole-model
    /// properties that need no pick at all.
    private var measureTypeGroups: [MeasureTypeGroup] {
        [
            MeasureTypeGroup(title: "距离", types: [.distance, .linear]),
            MeasureTypeGroup(title: "形状", types: [.angle, .radius, .area]),
            MeasureTypeGroup(title: "模型", types: [.volume, .boundingBox]),
        ]
    }

    private func measureTypeButton(_ type: MeasureType) -> some View {
        let accent = Color(red: 0.3, green: 0.8, blue: 0.9)
        let selected = viewModel.measureType == type
        return Button { viewModel.selectMeasureType(type) } label: {
            VStack(spacing: 3) {
                Image(systemName: type.icon)
                    .font(.system(size: 17, weight: .medium))
                Text(type.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(selected ? accent : .primary)
            .frame(width: 58, height: 44)
            .background(selected ? accent.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.label)
    }

    /// Display-mode picker, offered in the orbit toolbar and again in the measure
    /// toolbar.
    ///
    /// Measuring wants it more than orbiting does: seeing an internal bore is often
    /// *why* one reaches for 透明 or 线框, and having to leave measure mode to change
    /// it made those two picks impossible in the one situation that calls for them.
    /// The tradeoff is unchanged either way — switching display mode mid-measurement
    /// drops the picks in progress, while a finished reading survives the switch.
    ///
    /// `compact` sizes the label for the measure toolbar, whose controls are a fixed
    /// 54×44 strip beside a scrolling type list. The orbit toolbar instead shares its
    /// width equally between whatever buttons it happens to be showing, so the label
    /// there stretches. Sharing one build put that stretch into the measure row, where
    /// it had no row to share with and ate the space the type list needed.
    private func displayModeMenu(compact: Bool = false) -> some View {
        Menu {
            ForEach(DisplayMode.allCases) { mode in
                Button {
                    viewModel.displayMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        } label: {
            VStack(spacing: compact ? 3 : 4) {
                Image(systemName: viewModel.displayMode.icon)
                    .font(.system(size: compact ? 17 : 20, weight: .medium))
                Text("显示")
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(width: compact ? 54 : nil, height: compact ? 44 : nil)
            .frame(maxWidth: compact ? nil : .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("显示模式")
    }

    /// Orbit-side control over the finished measurements: hide them all for a clean
    /// look at the part, or wipe the history without entering measure mode.
    private var annotationsMenu: some View {
        Menu {
            Button {
                viewModel.toggleAnnotations()
            } label: {
                Label(viewModel.annotationsVisible ? "隐藏测量标注" : "显示测量标注",
                      systemImage: viewModel.annotationsVisible ? "eye.slash" : "eye")
            }
            Button(role: .destructive) {
                viewModel.clearAllMeasurements()
            } label: {
                Label("清除全部测量", systemImage: "trash")
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: viewModel.annotationsVisible ? "ruler.fill" : "ruler")
                    .font(.system(size: 20, weight: .medium))
                Text("标注").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
        }
    }

    private var mainToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "ruler", label: "测量") { viewModel.toggleMeasureMode() }
            toolbarButton(icon: "arrow.2.squarepath", label: "复位") { viewModel.resetView() }

            // Finished measurements survive leaving measure mode on purpose — the
            // readings get checked while orbiting. This is their orbit-side control.
            if !viewModel.measurements.isEmpty {
                annotationsMenu
            }

            displayModeMenu()

            Menu {
                ForEach(ViewDirection.allCases) { direction in
                    Button {
                        viewModel.setViewDirection(direction)
                    } label: {
                        Label(direction.rawValue, systemImage: direction.icon)
                    }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "cube").font(.system(size: 20, weight: .medium))
                    Text("视图").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
            }

            toolbarButton(icon: "slider.horizontal.3", label: "设置") { showSettings = true }
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

// MARK: - Disable swipe-back

extension View {
    /// Kills swipe-back (left-edge drag to pop) on the screen this modifier is
    /// applied to. The back button keeps working — it pops programmatically and
    /// never consults gesture recognizers.
    ///
    /// The screen lives in a SwiftUI `NavigationStack`, whose back gesture is
    /// not reliably the UIKit pop recognizer the classic recipes disable —
    /// SwiftUI can drive it with its own edge pan on a hosting view. See
    /// `SwipeBackSuppressor` for how the gesture layer is swept instead of the
    /// controller layer, and why a repeating re-assert is the only thing that
    /// stays ahead of the framework's lazy re-arms.
    func disableInteractivePopGesture() -> some View {
        background(InteractivePopDisabler())
    }
}

private struct InteractivePopDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PopDisablerVC {
        PopDisablerVC()
    }

    func updateUIViewController(_ controller: PopDisablerVC, context: Context) {
        SwipeBackSuppressor.shared.install(from: controller)
    }
}

/// Vetoes every interactive-pop attempt on the hosting navigation controller.
/// A process-wide singleton because UIKit stores the recognizer's delegate as an
/// unowned reference — a per-screen instance would dangle once its screen is
/// popped while the (shared) navigation controller lives on.
@MainActor
private final class PopGestureVetoer: NSObject, UIGestureRecognizerDelegate {
    static let shared = PopGestureVetoer()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

/// Keeps swipe-back dead on the viewer screen.
///
/// The screen is pushed by a SwiftUI `NavigationStack`, whose back gesture is
/// not necessarily `UINavigationController.interactivePopGestureRecognizer` —
/// SwiftUI can drive the swipe with its own edge pan on a hosting view, and the
/// classic recognizer may not even exist in the tree. Whatever the framework
/// owns, it re-arms at transition boundaries and lazily afterwards, at moments
/// this screen does not re-render on.
///
/// So the suppression attacks the gesture layer instead of the controller
/// layer: every `UIScreenEdgePanGestureRecognizer` anywhere in the viewer's
/// window, plus every navigation controller's pop recognizer found in its
/// view-controller tree, is disarmed three ways at once (no targets, disabled,
/// vetoing delegate). A repeating timer re-runs the sweep while the viewer is
/// on screen, staying ahead of every re-arm no matter when it lands.
///
/// Suppression is scoped hard: only the window that contains the viewer is
/// swept, and the did-show re-assert only touches navigation controllers that
/// were actually discovered in that tree — system surfaces hosting their own
/// navigation controllers (the document picker is one) are never touched.
@MainActor
private final class SwipeBackSuppressor {
    static let shared = SwipeBackSuppressor()

    private static let logger = Logger(subsystem: "com.xiaochun.3DViews", category: "swipe-back")

    /// Re-assert cadence: short enough that a lazily re-armed gesture cannot be
    /// used before the next sweep, cheap enough to be invisible.
    private static let reassertInterval: TimeInterval = 0.5

    private weak var trackedWindow: UIWindow?
    private var reassertTimer: Timer?
    /// Navigation controllers discovered in the viewer's window tree. The
    /// did-show re-assert is limited to these, so foreign controllers — the
    /// document picker hosts one — are never suppressed.
    private var knownNavs = Set<ObjectIdentifier>()
    private var killedEdgePans = Set<ObjectIdentifier>()
    private var observingDidShow = false

    func install(from viewController: UIViewController) {
        guard let window = viewController.view.window else { return }
        trackedWindow = window
        startReassertTimer()
        sweep()
    }

    /// Stops the re-assert loop when the viewer leaves the screen, so the rest
    /// of the app — home list, settings sheet, document picker — keeps its
    /// gestures untouched.
    func deactivate() {
        reassertTimer?.invalidate()
        reassertTimer = nil
        trackedWindow = nil
        knownNavs.removeAll()
    }

    private func startReassertTimer() {
        guard reassertTimer == nil else { return }
        reassertTimer = Timer.scheduledTimer(
            timeInterval: Self.reassertInterval,
            target: self,
            selector: #selector(reassertTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func reassertTick() {
        sweep()
    }

    private func sweep() {
        guard let window = trackedWindow else { return }

        var navs: [UINavigationController] = []
        collectNavigationControllers(under: window.rootViewController, into: &navs)
        var seen = Set<ObjectIdentifier>()
        let unique = navs.filter { seen.insert(ObjectIdentifier($0)).inserted }
        knownNavs = Set(unique.map { ObjectIdentifier($0) })
        for nav in unique {
            suppressPop(on: nav)
        }

        // The gesture layer. The window's whole view tree is walked — presented
        // sheets live inside the same window's presentation containers, so one
        // recursion reaches everything, including hosting views SwiftUI owns
        // outright.
        killEdgePans(under: window)

        if !observingDidShow {
            observingDidShow = true
            // Posted exactly when a push/pop finishes — the same window in which
            // the framework re-arms what it owns. Scoped to known navs so the
            // document picker's own navigation is never touched.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(navDidShow(_:)),
                name: NSNotification.Name("UINavigationControllerDidShowViewController"),
                object: nil
            )
        }
    }

    private func collectNavigationControllers(
        under root: UIViewController?,
        into result: inout [UINavigationController]
    ) {
        guard let root else { return }
        if let nav = root as? UINavigationController {
            result.append(nav)
        }
        for child in root.children {
            collectNavigationControllers(under: child, into: &result)
        }
        if let presented = root.presentedViewController {
            collectNavigationControllers(under: presented, into: &result)
        }
    }

    @objc private func navDidShow(_ notification: Notification) {
        guard let nav = notification.object as? UINavigationController,
              knownNavs.contains(ObjectIdentifier(nav)) else { return }
        suppressPop(on: nav)
    }

    private func suppressPop(on nav: UINavigationController) {
        guard let pop = nav.interactivePopGestureRecognizer else { return }
        // Three independent kills, because each alone has been re-armed by the
        // framework at one point or another: no targets means nothing left to
        // invoke, disabled means the touch stream never reaches it even if a
        // target comes back, and the vetoing delegate refuses a begin attempt
        // even while it is enabled.
        pop.removeTarget(nil, action: nil)
        pop.isEnabled = false
        if pop.delegate !== PopGestureVetoer.shared {
            pop.delegate = PopGestureVetoer.shared
        }
    }

    private func killEdgePans(under view: UIView) {
        for gesture in view.gestureRecognizers ?? [] where gesture is UIScreenEdgePanGestureRecognizer {
            gesture.removeTarget(nil, action: nil)
            gesture.isEnabled = false
            if gesture.delegate !== PopGestureVetoer.shared {
                gesture.delegate = PopGestureVetoer.shared
            }
            let id = ObjectIdentifier(gesture)
            if killedEdgePans.insert(id).inserted {
                Self.logger.info("swipe-back: disabled edge pan on \(String(describing: type(of: view)), privacy: .public)")
            }
        }
        for child in view.subviews {
            killEdgePans(under: child)
        }
    }
}

/// Embeds the suppression into the viewer's hierarchy. Appear callbacks arm the
/// suppressor (and restart its re-assert loop); disappearing stops it, so the
/// rest of the app — home list, settings sheet, document picker — keeps its
/// gestures untouched. `updateUIViewController` re-asserts on every SwiftUI
/// render of the screen, closing the window between a framework re-arm and the
/// next sweep.
private final class PopDisablerVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        SwipeBackSuppressor.shared.install(from: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SwipeBackSuppressor.shared.install(from: self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        SwipeBackSuppressor.shared.deactivate()
    }
}

extension View {
    /// Liquid Glass surface on iOS 26+, ultra-thin material on older systems.
    ///
    /// Every floating bar and panel in the viewer goes through this one helper so
    /// the app picks up the iOS 26 glass look without raising the deployment
    /// target, and keeps a visually close material fallback below it. The shape is
    /// always given explicitly because panels are rounded rectangles while the
    /// hint bubble is a capsule.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// One group of measurement types in the toolbar's type row.
///
/// The title is no longer drawn — the row lost its captions — but it stays as the
/// group's identity, which is what the `ForEach` keys the divider placement on.
private struct MeasureTypeGroup {
    let title: String
    let types: [MeasureType]
}
