//
//  FileHistory.swift
//  3D-Views
//

import Foundation
import UniformTypeIdentifiers

struct RecentFile: Codable, Identifiable, Hashable, Equatable {
    let id: UUID
    let fileName: String
    let localPath: String
    let openedAt: Date

    var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Imported").appendingPathComponent(localPath)
    }
}

@MainActor
final class FileHistory: ObservableObject {
    static let shared = FileHistory()

    @Published var files: [RecentFile] = []

    /// The file the system just handed the app (share sheet 「导入」/ open-in),
    /// awaiting navigation. `HomeView` consumes it and pushes the viewer.
    @Published var pendingOpen: RecentFile?

    /// Set when a handover from outside the app could not be carried out, so the
    /// reason can be shown instead of the user being left on the file list with no
    /// idea whether the tap registered. Every early return below is a case that
    /// used to be a silent `nil`.
    @Published var importFailure: String?

    private let userDefaultsKey = "RecentFiles"

    /// The most recent URL handed over from outside the app, and when. Two delivery
    /// hooks are wired up (see `AppDelegate`) because which one the system uses depends
    /// on the app's lifecycle mode; this is what stops a lifecycle that calls both from
    /// importing the same document twice.
    private var lastHandover: (path: String, at: Date)?

    /// What the system has actually told this app about documents opened from outside
    /// it, newest first, persisted so it survives the relaunch it may be reporting on.
    ///
    /// This exists because the failure being chased — the app comes forward and nothing
    /// else happens — reads identically whether the URL was never delivered, was
    /// delivered to a hook that was never installed, or arrived and was rejected. Two
    /// rounds were spent guessing between those; this is the evidence instead. The
    /// 诊断 section in `HomeView` shows it. Temporary: remove with that section once
    /// the handover is confirmed working.
    @Published private(set) var handoverLog: [String] = []

    private let handoverLogKey = "HandoverLog"

    private init() {
        load()
        handoverLog = UserDefaults.standard.stringArray(forKey: handoverLogKey) ?? []
    }

    /// Records one line of handover evidence. Kept to a short window so the 诊断
    /// section stays readable and the defaults entry stays small.
    func note(_ line: String) {
        let stamp = Self.stampFormatter.string(from: Date())
        handoverLog.insert("\(stamp) \(line)", at: 0)
        if handoverLog.count > 12 { handoverLog = Array(handoverLog.prefix(12)) }
        UserDefaults.standard.set(handoverLog, forKey: handoverLogKey)
    }

    /// What the **installed** bundle declares, read back from `Bundle.main` rather than
    /// from the repository. That distinction is the whole point: `Info.plist` is merged
    /// into the built product from `project.yml` at build time, and a side-loaded build
    /// need not be the one in the source tree. If the declarations never made it into
    /// the binary the user is running, no amount of care in the source will show up on
    /// the device. Temporary, alongside `handoverLog`.
    static func bundleFacts() -> [String] {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]

        if let scene = info["UIApplicationSceneManifest"] as? [String: Any] {
            let multiple = scene["UIApplicationSupportsMultipleScenes"] as? Bool
            let text = multiple.map { $0 ? "是" : "否" } ?? "未声明"
            lines.append("场景清单：有（多场景=\(text)）")
        } else {
            lines.append("场景清单：无")
        }

        if let types = info["CFBundleDocumentTypes"] as? [[String: Any]], !types.isEmpty {
            lines.append("文档类型：\(types.count) 项")
            for type in types {
                let ids = (type["LSItemContentTypes"] as? [String])?.joined(separator: ",") ?? "-"
                let exts = (type["CFBundleTypeExtensions"] as? [String])?.joined(separator: ",") ?? "-"
                lines.append("  \(exts) → \(ids)")
            }
        } else {
            lines.append("文档类型：无")
        }

        let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            .compactMap { $0["UTTypeIdentifier"] as? String }
        let imported = (info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
            .compactMap { $0["UTTypeIdentifier"] as? String }
        let exportedText = exported.isEmpty ? "无" : exported.joined(separator: ",")
        let importedText = imported.isEmpty ? "无" : imported.joined(separator: ",")
        lines.append("导出 UTI：\(exportedText)")
        lines.append("导入 UTI：\(importedText)")

        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        lines.append("Bundle ID：\(bundleID)")

        return lines
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    func addFile(sourceURL: URL) throws -> RecentFile {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importedDir = docs.appendingPathComponent("Imported")
        try? FileManager.default.createDirectory(at: importedDir, withIntermediateDirectories: true)

        let dest = importedDir.appendingPathComponent(sourceURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        // The copy *is* the import. This used to be `try?`, which failed into silence
        // while the entry was still listed and navigated to afterwards — so a failed
        // import left behind a recent row that opened onto nothing, which looks exactly
        // like the import never having run. A throw here can be reported. The
        // `removeItem` above stays best-effort: a file that was not there is not a
        // problem.
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let entry = RecentFile(
            id: UUID(),
            fileName: sourceURL.lastPathComponent,
            localPath: sourceURL.lastPathComponent,
            openedAt: Date()
        )
        files.insert(entry, at: 0)
        if files.count > 20 { files = Array(files.prefix(20)) }
        save()
        return entry
    }

    /// Receives a file handed over from outside the app — the share sheet's
    /// 「导入到"3D Views"」 or a document browser open-in. Nothing here runs until the
    /// URL is copied into our own sandbox: the system may back the URL with a
    /// security-scoped document, and reading it outside the access scope throws.
    /// Inbox copies report no scope, so the calls are harmless no-ops there.
    ///
    /// Only the formats the viewer understands are accepted — the app is registered
    /// for STEP/STL, but the share sheet can still offer it for neighbouring types.
    @discardableResult
    func receiveExternalFile(at url: URL, source: String) -> RecentFile? {
        // Logged before the dedup check below, so a lifecycle that knocks on both doors
        // still leaves evidence of both knocks — that is the reading that says which
        // door the system is actually using, and its absence says the URL never arrived.
        note("\(source) 收到：\(url.lastPathComponent)")

        // Both delivery hooks lead here, and the system may use either or both
        // depending on the app's lifecycle mode. The first sighting wins; a repeat of
        // the same file within a couple of seconds is the second hook carrying the
        // same handover, not a second handover. Without this the file would be
        // imported twice and listed twice.
        let handedOverPath = url.standardizedFileURL.path
        if let last = lastHandover,
           last.path == handedOverPath,
           Date().timeIntervalSince(last.at) < 2 {
            return nil
        }
        lastHandover = (handedOverPath, Date())

        guard Self.looksLikeCADFile(url) else {
            importFailure = "只能打开 STEP、STP 或 STL 文件。"
            note("  拒绝：类型不支持（扩展名「\(url.pathExtension)」）")
            return nil
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        note("  安全作用域：\(scoped ? "已获得" : "未提供")")

        do {
            let entry = try addFile(sourceURL: url)
            importFailure = nil
            pendingOpen = entry
            note("  已导入：\(entry.fileName)")
            return entry
        } catch {
            importFailure = "导入失败：\(error.localizedDescription)"
            note("  导入失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a URL handed over from another app names a file this viewer can open.
    ///
    /// The path extension alone is not enough. A share sheet's temporary copy can arrive
    /// under a URL that has no path extension at all — the name still carries one, and
    /// the UTI the sender tagged it with carries one too — and dropping those on the
    /// floor is the silent half of "the app opened but no file came in". All three are
    /// consulted, and only a URL that fails every one of them is rejected.
    private static func looksLikeCADFile(_ url: URL) -> Bool {
        let supported: Set<String> = ["step", "stp", "stl"]

        if supported.contains(url.pathExtension.lowercased()) { return true }

        let declared = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?
            .preferredFilenameExtension?
            .lowercased()
        if let declared, supported.contains(declared) { return true }

        // The last dot-component of the name, which catches a temporary URL that kept
        // its file name but lost its path extension.
        let named = url.lastPathComponent
            .split(separator: ".", omittingEmptySubsequences: true)
            .last
            .map { String($0).lowercased() }
        if let named, supported.contains(named) { return true }

        return false
    }

    func removeFile(_ file: RecentFile) {
        try? FileManager.default.removeItem(at: file.fileURL)
        files.removeAll { $0.id == file.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else {
            return
        }
        files = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
