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
                    Spacer().frame(height: 60)
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
            HStack {
                Image(systemName: viewModel.measureType.icon)
                    .foregroundColor(.blue)
                Text(viewModel.measureType.label)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
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
                            .foregroundColor(copiedToPasteboard ? .green : .blue)
                    }
                    .accessibilityLabel("复制测量结果")
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

            VStack(spacing: 6) {
                // What the number belongs to. A distance between two faces is a
                // different fact from the same number between two edges, and the
                // chips carry the exact entities — color-matched to their markers.
                if !viewModel.picks.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(viewModel.picks.enumerated()), id: \.element.id) { entry in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(uiColor: entry.element.entity.markerColor))
                                    .frame(width: 7, height: 7)
                                Text(entry.element.entity.description)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                }
                Text(mainResultValue)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: mainResultValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.vertical, 12)

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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Wide tablets get a centered card, not a reading stretched across the screen.
        .frame(maxWidth: 440)
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

    /// The clipboard form: the labeled reading plus whatever breakdown the panel
    /// shows underneath, so a pasted value carries its meaning with it.
    private var resultSummary: String {
        var lines = ["\(viewModel.measureType.label)：\(mainResultValue)"]
        if (viewModel.measureType == .distance || viewModel.measureType == .linear),
           let delta = deltaVector {
            lines.append("ΔX \(viewModel.displayUnit.format(delta.x))")
            lines.append("ΔY \(viewModel.displayUnit.format(delta.y))")
            lines.append("ΔZ \(viewModel.displayUnit.format(delta.z))")
        }
        if viewModel.measureType == .radius, let r = viewModel.radiusResult {
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

    /// The measure-mode toolbar: one compact row.
    ///
    /// Exit/undo sits fixed on the left, the unit menu fixed on the right, and the
    /// seven measurement types — grouped 距离 (distance kinds), 形状 (angle, radius,
    /// area), 模型 (volume, bounding box) — scroll in between. Everything else this
    /// mode once carried was folded away: the hint capsule carries the pick tally,
    /// finished readings archive themselves onto the model, and display mode plus
    /// the annotation controls live in the orbit toolbar. Fewer floating panels,
    /// less model occlusion.
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

            unitMenu
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
            .frame(width: 54, height: 44)
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

    /// Display-mode picker for the orbit toolbar.
    ///
    /// It used to be offered while measuring too — seeing an internal bore is often
    /// why one reaches for 透明 or 线框 — but that row is part of the clutter this
    /// pass removes. The tradeoff: switching display mode mid-measurement drops the
    /// picks in progress; a finished reading survives the switch either way.
    private func displayModeMenu() -> some View {
        Menu {
            ForEach(DisplayMode.allCases) { mode in
                Button {
                    viewModel.displayMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: viewModel.displayMode.icon).font(.system(size: 20, weight: .medium))
                Text("显示").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
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

/// One labelled group of measurement types in the toolbar's type row.
private struct MeasureTypeGroup {
    let title: String
    let types: [MeasureType]
}
