//
//  ViewerView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct ViewerView: View {
    let file: RecentFile
    @StateObject private var viewModel = ViewerViewModel()
    @State private var showSettings = false

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
            // after one tap left the user with no idea what was still wanted.
            if viewModel.mode == .measure && !viewModel.isComplete {
                VStack {
                    Spacer().frame(height: 60)
                    HStack {
                        Spacer()
                        Text(instructionText)
                            .font(.system(size: 13, weight: .medium))
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
                    // The history sits above the current selection: finished readings
                    // first, the slate being built right now directly above the toolbar.
                    if !viewModel.measurements.isEmpty {
                        measurementsPanel
                    }
                    if !viewModel.picks.isEmpty {
                        selectionPanel
                    }
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
        case .area: return "点选一个面；面积测量仅支持 STEP 模型"
        case .volume, .boundingBox: return "由模型外形直接计算，无需点选"
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
                // Saves the finished reading into 「测量记录」 without waiting for the
                // next tap to supersede it. Distinct from the ×, which discards.
                if viewModel.isComplete {
                    Button { viewModel.saveCurrentMeasurement() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .accessibilityLabel("存入测量记录")
                }
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

            if (viewModel.measureType == .distance || viewModel.measureType == .linear),
               let delta = deltaVector {
                Divider()
                HStack(spacing: 0) {
                    deltaColumn(label: "X", value: delta.x, color: .red)
                    Divider().frame(height: 36)
                    deltaColumn(label: "Y", value: delta.y, color: .green)
                    Divider().frame(height: 36)
                    deltaColumn(label: "Z", value: delta.z, color: .blue)
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

            if viewModel.measureType == .boundingBox, let e = viewModel.boundingBoxExtents {
                Divider()
                VStack(spacing: 6) {
                    extentRow(label: "长 X", value: e.x)
                    extentRow(label: "宽 Y", value: e.y)
                    extentRow(label: "高 Z", value: e.z)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if let message = viewModel.measureMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
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

    private var mainResultLabel: String {
        switch viewModel.measureType {
        case .distance, .linear: return "距离"
        case .angle: return "角度"
        case .radius: return "半径"
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
            if let r = viewModel.radiusResult { return viewModel.displayUnit.format(r) }
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
        VStack(spacing: 2) {
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(color)
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    /// One axis of the bounding box: label on the left, extent on the right.
    private func extentRow(label: String, value: Float) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(viewModel.displayUnit.format(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }

    /// The selection list: every entity taken for the current measurement, each one
    /// removable on its own.
    ///
    /// Individual removal is the point. A distance between two faces regularly needs a
    /// first pick that turns out to be the wrong face, and without this the only way
    /// back was 「清空」 — throwing away the picks that were already right and starting
    /// the measurement over.
    private var selectionPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Text("已选实体")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(viewModel.picks.count)/\(viewModel.requiredPickCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button { viewModel.clearMeasure() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("清空")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // A measurement never holds more than the three picks its type asks for,
            // so the list is bounded and needs no scrolling or height cap.
            VStack(spacing: 0) {
                ForEach(Array(viewModel.picks.enumerated()), id: \.element.id) { entry in
                    selectionRow(index: entry.offset, pick: entry.element)
                    if entry.offset != viewModel.picks.count - 1 {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// One row of the selection list: ordinal, the entity it resolved to, and the
    /// control that drops just this pick.
    private func selectionRow(index: Int, pick: Pick) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color(uiColor: pick.entity.markerColor), in: Circle())

            Text(pick.entity.description)
                .font(.system(size: 13, weight: .medium, design: .monospaced))

            Spacer()

            Button { viewModel.removePick(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(pick.entity.description)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The finished-measurement list: one row per reading, each removable on its own.
    ///
    /// The newest first — the reading just taken is the one still being checked, so it
    /// is the one that must be visible without scrolling.
    private var measurementsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Text("测量记录")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(viewModel.measurements.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button { viewModel.clearAllMeasurements() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                        Text("清空")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // Bounded so a long measuring session cannot push the toolbars off screen.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.measurements.enumerated().reversed()),
                            id: \.element.id) { entry in
                        measurementRow(entry.element)
                        if entry.offset != 0 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            .frame(maxHeight: 168)
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// One row of the history: the measurement's type, its formatted reading, and the
    /// control that removes it — annotation and all.
    private func measurementRow(_ item: MeasurementItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.type.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.type.label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(item.valueText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }

            Spacer()

            Button { viewModel.removeMeasurement(item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除该\(item.type.label)记录")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// The measure-mode toolbar: a categorized two-row glass bar.
    ///
    /// Row one holds the measurement types, grouped the way a desktop CAD package
    /// groups them — 距离 (minimum distance and point-to-point), 形状 (angle, radius
    /// and the area of a picked face), 模型 (whole-solid volume and bounding box) —
    /// so seven flat buttons stop reading as one undifferentiated strip. Row two
    /// holds the tools that apply to any measurement: undo/exit, display mode,
    /// unit, and the annotation show/hide toggle once a reading exists. The tool
    /// row stays put while only the type row scrolls.
    private var measureToolbar: some View {
        VStack(spacing: 0) {
            measureTypeRow
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            measureToolRow
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
                    VStack(spacing: 1) {
                        Text(group.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 0) {
                            ForEach(group.types) { type in
                                measureTypeButton(type)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var measureToolRow: some View {
        HStack(spacing: 0) {
            // Backsteps one point at a time so a mis-tap never forces the whole
            // measurement to be restarted; leaves measure mode once there is nothing
            // left to take back.
            toolButton(icon: viewModel.picks.isEmpty ? "xmark" : "arrow.uturn.backward.circle",
                       label: viewModel.picks.isEmpty ? "退出" : "撤销") {
                if viewModel.picks.isEmpty {
                    viewModel.toggleMeasureMode()
                } else {
                    viewModel.undoLastPoint()
                }
            }

            toolRowDivider
            displayModeMenu(compact: true)
            toolRowDivider

            unitMenu

            if !viewModel.measurements.isEmpty {
                toolRowDivider
                toolButton(icon: viewModel.annotationsVisible ? "eye" : "eye.slash", label: "标注") {
                    viewModel.toggleAnnotations()
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var toolRowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 30)
    }

    /// A labelled icon+text button that stretches to share the tool row evenly.
    private func toolButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var unitMenu: some View {
        Menu {
            ForEach(DisplayUnit.allCases, id: \.self) { unit in
                Button(unit.rawValue) { viewModel.setUnit(unit) }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "number")
                    .font(.system(size: 17, weight: .medium))
                Text(viewModel.displayUnit.rawValue)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("单位")
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

    /// Display-mode picker, shared by both toolbars.
    ///
    /// It is offered while measuring too, not just in the orbit toolbar: seeing an internal
    /// bore or rib is often the reason to reach for 透明 or 线框 in the first place, and
    /// leaving measure mode to switch would clear the picks already taken.
    ///
    /// `compact` renders it to the measure toolbar's 44 pt tool row; otherwise it
    /// renders as a regular toolbar item.
    private func displayModeMenu(compact: Bool) -> some View {
        Menu {
            ForEach(DisplayMode.allCases) { mode in
                Button {
                    viewModel.displayMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        } label: {
            if compact {
                VStack(spacing: 3) {
                    Image(systemName: viewModel.displayMode.icon)
                        .font(.system(size: 17, weight: .medium))
                    Text(viewModel.displayMode.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
            } else {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.displayMode.icon).font(.system(size: 20, weight: .medium))
                    Text("显示").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
            }
        }
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

            displayModeMenu(compact: false)

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
    /// Disables the navigation controller's interactive pop (swipe from the left
    /// edge to go back) on the screen this modifier is applied to. The back
    /// button itself keeps working — it pops programmatically and never consults
    /// this gesture recognizer.
    ///
    /// SwiftUI offers no first-party API for this, and switching the recognizer
    /// off with `isEnabled = false` does not stick: the framework re-enables it
    /// whenever navigation state changes (push, pop, navigation-item updates —
    /// and this screen rewrites its toolbar on every measurement tap), so the
    /// swipe came back shortly after every disable. The veto therefore lives at
    /// the delegate level, where `shouldBegin` decides, and is reinstalled on
    /// every SwiftUI update of this screen — the same render pass in which any
    /// re-enable would happen.
    func disableInteractivePopGesture() -> some View {
        background(InteractivePopDisabler())
    }
}

private struct InteractivePopDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PopDisablerVC {
        PopDisablerVC()
    }

    func updateUIViewController(_ uiViewController: PopDisablerVC, context: Context) {
        uiViewController.install()
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

/// Embeds the veto installation into the viewer's hierarchy. `viewDidAppear` is
/// the first point at which `navigationController` is guaranteed to be non-nil;
/// `updateUIViewController` re-asserts the veto on every SwiftUI render of the
/// screen so a framework re-enable cannot outlive the pass that caused it.
private final class PopDisablerVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        install()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    func install() {
        guard let pop = navigationController?.interactivePopGestureRecognizer else { return }
        pop.isEnabled = false
        if pop.delegate !== PopGestureVetoer.shared {
            pop.delegate = PopGestureVetoer.shared
        }
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

/// One labelled group of measurement types in the toolbar's type row.
private struct MeasureTypeGroup {
    let title: String
    let types: [MeasureType]
}
