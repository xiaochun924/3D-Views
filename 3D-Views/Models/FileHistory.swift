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

    private init() {
        load()
    }

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
    func receiveExternalFile(at url: URL) -> RecentFile? {
        guard Self.looksLikeCADFile(url) else {
            importFailure = "只能打开 STEP、STP 或 STL 文件。"
            return nil
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let entry = try addFile(sourceURL: url)
            importFailure = nil
            pendingOpen = entry
            return entry
        } catch {
            importFailure = "导入失败：\(error.localizedDescription)"
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
