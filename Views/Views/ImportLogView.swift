//
//  ImportLogView.swift
//  Views
//

import SwiftUI
import UIKit

/// What one recorded line means, which is what decides how it reads.
///
/// The log is stored as plain strings — `FileHistory.note` appends them to a `[String]` in
/// `UserDefaults`, and those lines outlive the build that wrote them — so the meaning is
/// recovered from the text at display time instead of being stored beside it. Nothing here
/// changes what is recorded, and a line this cannot classify reads as `.info`, which is the
/// honest answer for a line written by an older build with different wording.
enum HandoverLogKind {
    /// The handover tried and did not work.
    case failure
    /// A file the viewer has no reader for: it did not import, but nothing is broken.
    case unsupported
    case success
    case scan
    case cleanup
    case handover
    /// Recognised as a record, but not as any of the above.
    case info

    /// Whether this line is one the user has to act on. It defines the 需要处理 section, and
    /// it is the only thing allowed to colour the status row: a log where every line is a
    /// successful import must not read as a warning.
    var isProblem: Bool {
        switch self {
        case .failure, .unsupported: return true
        case .success, .scan, .cleanup, .handover, .info: return false
        }
    }

    var symbol: String {
        switch self {
        case .failure: return "exclamationmark.triangle.fill"
        case .unsupported: return "questionmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .scan: return "magnifyingglass"
        case .cleanup: return "trash"
        case .handover: return "shippingbox"
        case .info: return "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .failure: return .red
        case .unsupported: return .orange
        case .success: return .green
        case .scan, .cleanup, .handover, .info: return .secondary
        }
    }
}

/// One line of handover evidence, split into the parts a row needs, with stable identity.
///
/// Identity has to be a minted `UUID` held in `@State`, not a position and not the string
/// itself. The log used to be rendered with
/// `ForEach(Array(history.handoverLog.enumerated()), id: \.offset)` — identity derived from
/// position, which the `list-patterns` rule rejects: clearing the log or trimming it to its
/// twelve-line window shifts every remaining row, so SwiftUI reuses the wrong rows and stale
/// text stays on screen. `id: \.self` on the string is not a substitute, because two
/// identical lines are entirely possible (`扫描…` twice in a row) and duplicate ids are their
/// own defect. The `UUID` is minted in `ImportLogView.reloadLog()`, where the pairing is made
/// once per refresh; minting it in `body` would produce new ids on every redraw — a new log
/// line, a tap on 复制 — and tear down rows that did not change.
struct HandoverLogEntry: Identifiable {
    let id: UUID
    /// `MM-dd HH:mm:ss`, as written by `FileHistory.note`. Empty if the line carries none.
    let stamp: String
    /// The line without its timestamp and without the indentation that marks a detail step.
    let message: String
    let kind: HandoverLogKind
    /// True for a step *within* an event — a line the recorder indented — as opposed to an
    /// event of its own.
    let isDetail: Bool
}

extension HandoverLogEntry {
    /// Splits one stored line into the parts the row needs.
    ///
    /// The stored shape has to stay a plain string: the log outlives any given build, so a
    /// struct with fields added later cannot be decoded from a line written earlier. Both
    /// facts this reads — the `MM-dd HH:mm:ss` prefix (14 characters, exactly what
    /// `FileHistory.stampFormatter` produces) and the two leading spaces that mark a detail
    /// step — are therefore read back out of the text.
    init(id: UUID = UUID(), line: String) {
        var stamp = ""
        var body = line

        let stampLength = 14
        if line.count > stampLength {
            let separator = line.index(line.startIndex, offsetBy: stampLength)
            // The prefix is only a timestamp if the character after it is the space
            // `note()` puts there; any other line keeps its whole text as the message,
            // which is what an unclassifiable record should do.
            if line[separator] == " " {
                stamp = String(line.prefix(stampLength))
                body = String(line.dropFirst(stampLength + 1))
            }
        }

        let isDetail = body.hasPrefix("  ")
        let message = body.trimmingCharacters(in: .whitespaces)

        self.id = id
        self.stamp = isDetail ? "" : stamp
        self.message = message
        self.isDetail = isDetail
        self.kind = Self.kind(of: message)
    }

    /// Reads a line's kind out of its wording.
    ///
    /// The order below is the whole logic. 不支持 is asked first because it also appears in
    /// lines that say 拒绝 — `拒绝：scheme 不支持` and `收件箱移出（格式不支持）` — and those
    /// are a format this viewer has no reader for, not a broken handover. 失败 is asked before
    /// the success words for the same reason in reverse: `沙盒导入失败` contains `沙盒导入`.
    private static func kind(of message: String) -> HandoverLogKind {
        if message.contains("不支持") { return .unsupported }
        if message.contains("失败") || message.contains("拒绝")
            || message.contains("不一致") || message.contains("不可用") {
            return .failure
        }
        if message.contains("已导入") || message.contains("导入成功")
            || message.contains("沙盒导入") || message.contains("下载完成")
            || message.contains("恢复中断的导入") || message.contains("已获得") {
            return .success
        }
        if message.hasPrefix("扫描") { return .scan }
        if message.hasPrefix("清理") { return .cleanup }
        if message.contains("收到") || message.contains("交接")
            || message.contains("冷启动") || message.contains("下载") {
            return .handover
        }
        return .info
    }
}

/// One line of the build-and-share readout, with stable identity.
///
/// The same defect as `HandoverLogEntry` above: `bundleFacts()` reads the installed bundle
/// and the share chain's own records, and returns a *variable-length* array — the handoff
/// record adds a line, and the finishing trail adds one per step it took — so position
/// identity shifts every row below an added or removed line. `id: \.self` is again not a
/// substitute: `bundleFacts()` can legitimately emit the same text twice. The `UUID` is
/// minted in `ImportLogView.reloadFacts()`, once per refresh.
struct BundleFactEntry: Identifiable {
    let id: UUID
    let text: String
}

/// What the status row says, at the size it says it.
private struct ImportVerdict {
    let symbol: String
    let tint: Color
    let text: String
    let detail: String
}

/// One log row: an icon carrying the kind, the message, and — for an event rather than a step
/// inside one — the time it happened.
///
/// The timestamp is shown only on the event line. A detail step was recorded in the same
/// second as the event it belongs to (`note()` stamps both as they are written), so repeating
/// it on every step is the same fact twice, and dropping it is what makes the indentation
/// read as grouping rather than as a stray space.
private struct ImportLogRow: View {
    let entry: HandoverLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(entry.kind.tint)
                .frame(width: 14, alignment: .center)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                if !entry.stamp.isEmpty {
                    Text(entry.stamp)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, entry.isDetail ? 18 : 0)
    }
}

/// The import log, on its own screen.
///
/// It used to sit at the top of the file list, which was the wrong place twice over: it
/// pushed the actual content down on every launch, and it stayed invisible whenever the list
/// had something else to show. What it is for is answering one question — did the handover
/// arrive, and if not, which step failed — so it belongs behind a deliberate tap.
///
/// This screen reads in three layers, in the order those questions are asked: a one-line
/// verdict, then only the lines that did *not* work, then the full record for when the first
/// two are not enough. The full record is what the previous version led with — twelve
/// monospaced lines of equal weight, where the one failed handover had to be found by
/// reading. Everything is still here and 复制全部 still copies all of it; what changed is
/// which part is asked for first.
struct ImportLogView: View {
    @StateObject private var history = FileHistory.shared
    @State private var copied = false
    /// The log paired with identity, held rather than derived — see `HandoverLogEntry`.
    @State private var logEntries: [HandoverLogEntry] = []
    /// The build-and-share readout, paired with identity for the same reason.
    ///
    /// `bundleFacts()` is not observable — it reads the installed bundle and `UserDefaults`
    /// on every call — so this is also what makes the section re-read at all. It replaced
    /// `.id(refreshToken)`, which rebuilt the *entire* `List` from scratch on every refresh:
    /// correct, but it threw away SwiftUI's diffing for every section to fix one.
    @State private var factEntries: [BundleFactEntry] = []

    /// Pairs the current log with fresh identity and rebuilds the log rows.
    ///
    /// One function rather than two calls at each site, because the pairing and the rebuild
    /// have to happen together: `FileHistory` holds plain `[String]`, and a row whose
    /// identity is derived from its position in that array is the pattern `list-patterns`
    /// rejects.
    private func reloadLog() {
        logEntries = history.handoverLog.map { HandoverLogEntry(line: $0) }
    }

    /// Pairs the build-and-share readout with fresh identity.
    ///
    /// Separate from `reloadLog()` because the two read different things and change on
    /// different occasions: the log lives in `UserDefaults` and changes when a handover
    /// happens *or* when 清空 is tapped, while the facts come from the installed binary plus
    /// the share chain's own records and change when a different build is installed or a
    /// share is attempted. So this is called on two of the three occasions `reloadLog()` is —
    /// entry and 重新扫描 — and deliberately not on 清空, which cannot alter either.
    private func reloadFacts() {
        factEntries = FileHistory.bundleFacts().map { BundleFactEntry(id: UUID(), text: $0) }
    }

    /// The lines that did not work, newest first — already the log's order.
    private var problems: [HandoverLogEntry] {
        logEntries.filter { $0.kind.isProblem }
    }

    /// The one-line answer, from the three facts that decide it rather than from the log.
    ///
    /// The log is evidence about the past; these three are the state right now. A green row
    /// means "nothing is broken and nothing is waiting", which is deliberately not the same
    /// claim as "no handover ever failed" — that is what 需要处理 is for.
    private var verdict: ImportVerdict {
        if !FileHistory.shareExtensionInstalled {
            return ImportVerdict(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                text: "分享扩展未安装",
                detail: "当前导入靠扩展把文件放进共享容器；扩展不在包里，就没有任何东西能接收分享。"
            )
        }
        if !AppGroup.isAvailable {
            return ImportVerdict(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                text: "共享容器不可用",
                detail: "扩展放进来的文件读不到，分享会静默失败。"
            )
        }
        let pending = history.sharedInboxFileCount()
        if pending > 0 {
            return ImportVerdict(
                symbol: "clock.badge.exclamationmark",
                tint: .orange,
                text: "收件箱有 \(pending) 个文件待取",
                detail: "文件已到达共享容器，但还没被取走。点右上角「重新扫描」。"
            )
        }
        if !problems.isEmpty {
            return ImportVerdict(
                symbol: "clock.badge.exclamationmark",
                tint: .orange,
                text: "最近有 \(problems.count) 条未成功的记录",
                detail: "不是当前故障，逐条见下方「需要处理」。"
            )
        }
        return ImportVerdict(
            symbol: "checkmark.circle.fill",
            tint: .green,
            text: "状态正常",
            detail: "扩展已安装，共享容器可用，收件箱已排空。"
        )
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: verdict.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(verdict.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict.text)
                            .font(.subheadline.weight(.semibold))
                        Text(verdict.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                LabeledContent("共享容器") {
                    if AppGroup.isAvailable {
                        Label("可用", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else {
                        Label("不可用", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("收件箱待取", value: "\(history.sharedInboxFileCount()) 个")
                // "未安装（正常）" was written for the document-open build, where the
                // absence of an extension was the design. On the current build the same
                // reading means nothing can receive a share at all, so it is labelled as
                // the failure it is rather than reassured away.
                LabeledContent(
                    "分享扩展",
                    value: FileHistory.shareExtensionInstalled ? "已安装" : "未安装（故障）"
                )
            } header: {
                Text("状态")
            }

            // Only when there is something in it. An empty section, or a "没有失败记录" row
            // that has to be read to learn nothing, is the clutter this screen was carrying.
            if !problems.isEmpty {
                Section {
                    ForEach(problems) { entry in
                        ImportLogRow(entry: entry)
                    }
                } header: {
                    Text("需要处理（\(problems.count)）")
                } footer: {
                    Text("这些行是没能导入成功的记录，最新的在最上面。")
                        .font(.system(size: 10))
                }
            }

            Section {
                if logEntries.isEmpty {
                    Text("尚无记录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logEntries) { entry in
                        ImportLogRow(entry: entry)
                    }
                }
            } header: {
                HStack {
                    Text("导入记录")
                    Spacer()
                    Button("清空") {
                        history.clearLog()
                        reloadLog()
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            } footer: {
                Text("全部记录，最新在最上面；缩进的行是上一条事件的其中一步。")
                    .font(.system(size: 10))
            }

            Section {
                // Collapsed, and counted rather than listed. `bundleFacts()` is the longest
                // thing on this screen — the finishing trail alone adds a line per step the
                // extension took — and it is the one part that is not asked about until the
                // two sections above have failed to explain something. The count says whether
                // it is worth opening; 复制全部 still copies every line whether it is open or
                // not.
                DisclosureGroup {
                    ForEach(factEntries) { entry in
                        Text(entry.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("构建与分享链路（\(factEntries.count) 项）")
                }
            }

            Section {
                DisclosureGroup {
                    // Rewritten with the mechanism it describes: this paragraph used to explain
                    // that no extension was in use and that an empty inbox was expected, which
                    // was true only of the reverted document-open build. On the current build
                    // those same readings are the failure signal, so the old text actively
                    // argued against the evidence.
                    Text("「分享扩展：未安装」是故障，不是预期结果：当前导入靠扩展把文件放进共享容器，扩展不在包里就没有任何东西能接收分享。依次看三件事——扩展是否已安装、共享容器是否可用、收件箱里有没有待取文件；分享之后收件箱应当出现文件，随后被本应用取走而归零。全部复制下来即可用于定位。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } label: {
                    Text("排查说明")
                }
            }
        }
        .navigationTitle("导入诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = history.diagnosticsReport()
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("复制全部")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // The sweep is asynchronous, with retries at 300/1000/2500 ms
                    // (`FileHistory.scheduleInboxSweep`). The two reloads used to run the
                    // other way round — the token was bumped *before* the sweep started —
                    // which rebuilt the rows from data the sweep had not produced yet, so
                    // the button looked dead until it was pressed a second time. They now
                    // follow the synchronous first pass, so what is read back is what the
                    // sweep just found.
                    //
                    // The retries are deliberately not awaited: they exist precisely because
                    // the file may not have landed yet, and waiting for them would put a
                    // 2.5-second pause behind the button. Pressing it again after they fire
                    // picks up a late arrival, which is what the button is for.
                    history.scheduleInboxSweep(reason: "手动刷新")
                    reloadLog()
                    reloadFacts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新扫描")
            }
        }
        .onAppear {
            // Looking on entry is the point of the screen: whatever the user came here to
            // read is whatever arrived since the last look. The rebuild follows the sweep
            // for the same reason the toolbar button does it that way — the first pass is
            // synchronous, so what is read back is what the sweep just found.
            history.scheduleInboxSweep(reason: "查看诊断")
            reloadLog()
            reloadFacts()
        }
    }
}

#Preview {
    NavigationStack { ImportLogView() }
}
