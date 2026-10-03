//
//  ImportLogView.swift
//  3D-Views
//

import SwiftUI
import UIKit

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
                LabeledContent("分享扩展", value: FileHistory.shareExtensionInstalled ? "已安装" : "未安装")
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
                    ForEach(Array(history.handoverLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("导入记录")
                    Spacer()
                    Button("清空") { history.clearLog() }
                        .font(.footnote)
                        .textCase(nil)
                }
            }

            Section("安装包状态") {
                ForEach(Array(FileHistory.bundleFacts().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("分享扩展是否装上、共享容器是否可用，决定了分享面板点进来之后文件能不能交到本应用手里。全部复制下来即可用于定位。")
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
                    refreshToken += 1
                    history.scheduleInboxSweep(reason: "手动刷新")
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新扫描")
            }
        }
        .onAppear {
            // Looking on entry is the point of the screen: whatever the user came here to
            // read is whatever arrived since the last look.
            history.scheduleInboxSweep(reason: "查看诊断")
        }
    }
}

#Preview {
    NavigationStack { ImportLogView() }
}
