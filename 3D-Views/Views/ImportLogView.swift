//
//  ImportLogView.swift
//  3D-Views
//

import SwiftUI
import UIKit

/// One line of handover evidence, with stable identity.
///
/// The log used to be rendered with
/// `ForEach(Array(history.handoverLog.enumerated()), id: \.offset)`, which is the exact
/// pattern `list-patterns` rejects: identity derived from position. Clearing the log or
/// trimming it to its twelve-line window shifts every remaining row, so SwiftUI reuses
/// the wrong rows and stale text stays on screen. `id: \.self` on the string is not a
/// substitute — two identical lines are possible and duplicate ids are their own defect.
///
/// The identity has to be assigned where the line is paired for display, not derived in
/// `body`: a `UUID` made during body evaluation changes on every redraw — a new log line,
/// a tap on 复制 — and tears down rows that did not change. `ImportLogView.logEntries`
/// holds the pairing in `@State` and rebuilds it only when asked to.
struct HandoverLogEntry: Identifiable {
    let id: UUID
    let text: String
}

/// The import log, on its own screen.
///
/// It used to sit at the top of the file list, which was the wrong place twice over: it
/// pushed the actual content down on every launch, and it stayed invisible whenever the
/// list had something else to show. What it is for is answering one question — did the
/// handover arrive, and if not, which step failed — so it belongs behind a deliberate
/// tap, where it can also be long enough to be useful.
struct ImportLogView: View {
    @StateObject private var history = FileHistory.shared
    @State private var copied = false
    @State private var refreshToken = 0
    /// The log paired with identity, held rather than derived.
    ///
    /// It has to live in `@State`: `HandoverLogEntry` mints a `UUID`, so building the
    /// array inside `body` would produce new ids on every evaluation — a new line, a tap
    /// on 复制, anything — and every row would be torn down and rebuilt. Held here, the
    /// ids are made once per refresh and survive until the log actually changes.
    @State private var logEntries: [HandoverLogEntry] = []

    /// Pairs the current log with fresh identity and forces the list to rebuild.
    ///
    /// One function rather than two calls at each site, because the pairing and the
    /// rebuild have to happen together: `FileHistory` holds plain `[String]`, and a row
    /// whose identity is derived from its position in that array is the exact pattern
    /// `list-patterns` rejects — clearing the log or trimming it to its twelve-line
    /// window shifts every remaining row.
    private func reloadLog() {
        logEntries = history.handoverLog.map { HandoverLogEntry(id: UUID(), text: $0) }
        refreshToken += 1
    }

    var body: some View {
        List {
            Section {
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
                LabeledContent("分享扩展", value: FileHistory.shareExtensionInstalled ? "已安装" : "未安装（故障）")
            } header: {
                Text("交接状态")
            } footer: {
                Text("下面每一行都是「系统把文件交给本应用」或「本应用去找文件」时的现场记录，最新的在最上面。")
                    .font(.system(size: 10))
            }
            Section {
                if history.handoverLog.isEmpty {
                    Text("尚无记录")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logEntries) { entry in
                        Text(entry.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
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
            }

            Section("安装包状态") {
                // `bundleFacts()` reads `Bundle.main` — it is not observable and cannot
                // tell the list it changed. It is rebuilt with `refreshToken` for the same
                // reason the log is: 重新扫描 is the button that asks for a fresh reading.
                ForEach(Array(FileHistory.bundleFacts().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                // Rewritten with the mechanism it describes: this paragraph used to explain
                // that no extension was in use and that an empty inbox was expected, which
                // was true only of the reverted document-open build. On the current build
                // those same readings are the failure signal, so the old text actively
                // argued against the evidence.
                Text("「分享扩展：未安装」是故障，不是预期结果：当前导入靠扩展把文件放进共享容器，扩展不在包里就没有任何东西能接收分享。依次看三件事——扩展是否已安装、共享容器是否可用、收件箱里有没有待取文件；分享之后收件箱应当出现文件，随后被本应用取走而归零。全部复制下来即可用于定位。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .id(refreshToken)
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
                    // (`FileHistory.scheduleInboxSweep`). Bumping the token *before*
                    // starting it rebuilt the list from data the sweep had not yet
                    // produced, so the button looked dead until it was pressed a second
                    // time. It stays a single bump — the retries exist precisely because
                    // the file may not have landed yet, and waiting for them would put a
                    // 2.5-second pause behind the button. What changed is *where* the bump
                    // happens: after the synchronous first pass, so the list is rebuilt
                    // from the reading the button just took.
                    history.scheduleInboxSweep(reason: "手动刷新")
                    reloadLog()
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
        }
    }
}

#Preview {
    NavigationStack { ImportLogView() }
}
