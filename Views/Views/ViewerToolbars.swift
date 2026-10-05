//
//  ViewerToolbars.swift
//  Views
//

import SwiftUI

/// The viewer's two bottom toolbars, extracted out of `ViewerView` into their own
/// `View` types.
///
/// Why this file exists: a computed property on `ViewerView` is not an invalidation
/// boundary. `resultPanel`, `measureToolbar` and `mainToolbar` all used to be
/// computed properties reading `viewModel` directly, which made the *whole*
/// `ViewerView` body subscribe to every one of the view model's 60-plus `@Published`
/// properties. `previewEntity` and `previewPoint` change on every frame of a
/// press-and-hold, so the entire 1046-line body — toolbars, result card, every menu —
/// was rebuilt at display refresh rate while a finger was held down on the model.
///
/// A separate `struct View` gets its own invalidation boundary, but only if it is
/// given plain values rather than the observed object: reading `viewModel.x` inside a
/// child's body would just move the subscription, not narrow it. So every type here
/// takes the fields it draws and a closure for each action it performs, and nothing
/// else. `previewPoint` changing now reaches `SceneView` and stops there.

// MARK: - Shared pieces

/// One group of measurement types in the toolbar's type row.
///
/// The title is no longer drawn — the row lost its captions — but it stays as the
/// group's identity, which is what the `ForEach` keys the divider placement on.
private struct MeasureTypeGroup {
    let title: String
    let types: [MeasureType]
}

/// The measurement types as displayed groups: distance questions, shape questions
/// answered from one or two picked entities, and whole-model properties that need no
/// pick at all.
private let measureTypeGroups: [MeasureTypeGroup] = [
    MeasureTypeGroup(title: "距离", types: [.distance, .linear]),
    MeasureTypeGroup(title: "形状", types: [.angle, .radius, .area]),
    MeasureTypeGroup(title: "模型", types: [.volume, .boundingBox]),
]

/// A labelled icon+text button at a toolbar's fixed edges — the scrolling type row
/// takes the middle, so these get a fixed width instead of a share.
private struct FixedToolButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
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
}

/// The thin rule between toolbar runs.
private struct ToolRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 30)
    }
}

/// Display-mode picker, offered in the orbit toolbar and again in the measure toolbar.
///
/// Measuring wants it more than orbiting does: seeing an internal bore is often *why*
/// one reaches for 透明 or 线框, and having to leave measure mode to change it made
/// those two picks impossible in the one situation that calls for them. The tradeoff is
/// unchanged either way — switching display mode mid-measurement drops the picks in
/// progress, while a finished reading survives the switch.
///
/// `compact` sizes the label for the measure toolbar, whose controls are a fixed 54×44
/// strip beside a scrolling type list. The orbit toolbar instead shares its width
/// equally between whatever buttons it happens to be showing, so the label there
/// stretches. Sharing one build put that stretch into the measure row, where it had no
/// row to share with and ate the space the type list needed.
private struct DisplayModeMenu: View {
    let mode: DisplayMode
    let compact: Bool
    let onSelect: (DisplayMode) -> Void

    var body: some View {
        Menu {
            ForEach(DisplayMode.allCases) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    Label(candidate.label, systemImage: candidate.icon)
                }
            }
        } label: {
            VStack(spacing: compact ? 3 : 4) {
                Image(systemName: mode.icon)
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
}

/// A bottom toolbar button that shares its width equally with its neighbours.
private struct WidenedToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Measure toolbar

/// The measure-mode toolbar: one compact row.
///
/// Exit/undo sits fixed on the left, exit's counterpart and the two menus fixed on the
/// right, and the seven measurement types scroll in between. Display mode is offered
/// here too — see `DisplayModeMenu` for why.
///
/// The unit menu used to sit beside it and is gone. It was the only place the unit
/// could be changed from the viewer, but it is a setting, not a control: it is set
/// once and then left alone, while this row is the scarcest space in the app — it has
/// to hold eight measurement types beside a scrolling list. 设置 already carries 默认
/// 单位 and the model reads that same `defaultUnit` key at init, so removing this
/// costs no capability, only a detour through the settings sheet.
struct MeasureToolbar: View {
    /// Empty picks turn the leading button from 撤销 into 退出 — one button does both,
    /// because there is nothing to undo until something has been picked.
    let picksIsEmpty: Bool
    let measureType: MeasureType
    let displayMode: DisplayMode
    let snapMode: SnapMode

    let onExitOrUndo: () -> Void
    let onSelectMeasureType: (MeasureType) -> Void
    let onSelectDisplayMode: (DisplayMode) -> Void
    let onSelectSnapMode: (SnapMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            FixedToolButton(
                icon: picksIsEmpty ? "xmark" : "arrow.uturn.backward.circle",
                label: picksIsEmpty ? "退出" : "撤销",
                action: onExitOrUndo
            )

            ToolRowDivider()

            measureTypeRow

            ToolRowDivider()

            DisplayModeMenu(mode: displayMode, compact: true, onSelect: onSelectDisplayMode)

            ToolRowDivider()

            snapModeMenu
        }
        .padding(.vertical, 5)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var measureTypeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(measureTypeGroups.enumerated(), id: \.element.title) { index, group in
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

    private func measureTypeButton(_ type: MeasureType) -> some View {
        let accent = Color(red: 0.3, green: 0.8, blue: 0.9)
        let selected = measureType == type
        return Button { onSelectMeasureType(type) } label: {
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

    private var snapModeMenu: some View {
        Menu {
            ForEach(SnapMode.allCases) { mode in
                Button {
                    onSelectSnapMode(mode)
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: snapMode.icon)
                    .font(.system(size: 17, weight: .medium))
                Text(snapMode.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary)
            .frame(width: 54, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("捕捉模式")
    }
}

// MARK: - Orbit toolbar

/// The orbit-mode toolbar: measure, reset, annotations, display mode, view direction,
/// settings.
struct MainToolbar: View {
    /// Finished measurements survive leaving measure mode on purpose — the readings get
    /// checked while orbiting. This is their orbit-side control, and it only earns its
    /// space once there is something to control.
    let hasMeasurements: Bool
    let annotationsVisible: Bool
    let displayMode: DisplayMode

    let onToggleMeasureMode: () -> Void
    let onResetView: () -> Void
    let onToggleAnnotations: () -> Void
    let onClearAllMeasurements: () -> Void
    let onSelectDisplayMode: (DisplayMode) -> Void
    let onSelectViewDirection: (ViewDirection) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            WidenedToolbarButton(icon: "ruler", label: "测量", action: onToggleMeasureMode)
            WidenedToolbarButton(icon: "arrow.2.squarepath", label: "复位", action: onResetView)

            if hasMeasurements {
                annotationsMenu
            }

            DisplayModeMenu(mode: displayMode, compact: false, onSelect: onSelectDisplayMode)

            Menu {
                ForEach(ViewDirection.allCases) { direction in
                    Button {
                        onSelectViewDirection(direction)
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
            .contentShape(Rectangle())

            WidenedToolbarButton(icon: "slider.horizontal.3", label: "设置", action: onOpenSettings)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Orbit-side control over the finished measurements: hide them all for a clean look
    /// at the part, or wipe the history without entering measure mode.
    private var annotationsMenu: some View {
        Menu {
            Button {
                onToggleAnnotations()
            } label: {
                Label(annotationsVisible ? "隐藏测量标注" : "显示测量标注",
                      systemImage: annotationsVisible ? "eye.slash" : "eye")
            }
            Button(role: .destructive) {
                onClearAllMeasurements()
            } label: {
                Label("清除全部测量", systemImage: "trash")
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: annotationsVisible ? "ruler.fill" : "ruler")
                    .font(.system(size: 20, weight: .medium))
                Text("标注").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("测量标注")
    }
}

// MARK: - Measure hint

/// The instruction capsule shown while a measurement is still collecting picks.
///
/// Kept up until the measurement has all the picks it needs, not just until the first
/// one: entity measurements often need two, and hiding the hint after one tap left the
/// user with no idea what was still wanted. The tally underneath doubles as the
/// selection status — which is why the old dedicated selection panel is gone. One
/// capsule, nothing else floating.
struct MeasureHint: View {
    let instruction: String
    let pickTally: String?

    var body: some View {
        VStack {
            Spacer().frame(height: 6)
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Text(instruction)
                        .font(.system(size: 13, weight: .medium))
                    if let pickTally {
                        Text(pickTally)
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
}

// MARK: - Loading scrim

/// Full-screen loading state.
///
/// A scrim so the loading state is unmistakable on large files (a parse can take many
/// seconds) and the user does not mistake a busy app for a frozen one. The spinner
/// actually animates now because the OCCT parse runs in a detached task instead of
/// blocking the main actor.
///
/// The fade is driven by the `.animation(_:value:)` on the caller's `ZStack` — a
/// `.transition` alone does nothing: a transition only plays inside an animated
/// transaction, and nothing here called `withAnimation`, so the scrim used to pop in
/// and out regardless.
struct LoadingScrim: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .transition(.opacity)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.4)
                Text("加载中...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text("大文件解析可能需要一些时间")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .transition(.opacity)
        }
    }
}
