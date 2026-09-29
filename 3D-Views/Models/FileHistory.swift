//
//  FileHistory.swift
//  3D-Views
//

import Foundation

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

    private let userDefaultsKey = "RecentFiles"

    private init() {
        load()
    }

    func addFile(sourceURL: URL) -> RecentFile {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importedDir = docs.appendingPathComponent("Imported")
        try? FileManager.default.createDirectory(at: importedDir, withIntermediateDirectories: true)

        let dest = importedDir.appendingPathComponent(sourceURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: sourceURL, to: dest)

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
