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

    /// What `importFromSandbox` has already taken from under `Documents`, so a file the
    /// user copied in is imported once rather than on every scan.
    private let sandboxScanKey = "SandboxScanFingerprints"

    /// The formats the viewer can actually open, in one place because three gates consult
    /// it: the handover from another app, the sandbox scan, and the rejection message.
    ///
    /// Every entry here has a real reader behind it, which is the only thing that makes it
    /// honest to list. Five of them are the kernel's own: `Shape.loadSTEP`, `readSTL`,
    /// `loadIGES`, `loadOBJ` and `loadBREP`. `sldprt` is different in kind — OpenCASCADE
    /// has never had a SolidWorks reader, so the file is first turned into STEP text by
    /// the bundled port of sldprt2step (`Models/SLDPRT/`) and only then handed to
    /// `Shape.loadSTEP` like any other STEP file. It still ends up as real B-rep
    /// topology, so face/edge/vertex measurement keeps working.
    static let supportedExtensions: Set<String> = [
        "step", "stp",
        "stl",
        "iges", "igs",
        "obj",
        "brep",
        "sldprt"
    ]

    /// The formats a CAD user is most likely to try and that this viewer still cannot
    /// open, mapped to the advice worth showing. Kept apart from `supportedExtensions`
    /// because the useful part is the message, not the gate.
    ///
    /// `.sldprt` used to head this list. It no longer does: the app now carries a port of
    /// sldprt2step that pulls the embedded Parasolid B-rep out of the container itself, so
    /// a SolidWorks part opens like anything else. The assembly and drawing containers are
    /// a different problem — they reference other files and hold no single self-contained
    /// B-rep — and Parasolid's own `.x_t`/`.x_b` transmits are still unsupported, so the
    /// advice below still earns its place.
    static let knownUnsupportedFormats: [String: String] = [
        "sldasm": "SolidWorks 装配体",
        "slddrw": "SolidWorks 工程图",
        "x_t": "Parasolid",
        "x_b": "Parasolid",
        "jt": "JT"
    ]

    /// The path extension of a URL when it names a file this viewer can open, `nil`
    /// otherwise. Case-insensitive: `PART.STEP` is the same format as `part.step`.
    static func supportedExtension(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext) ? ext : nil
    }

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

        // When the installed binary was written. Side-loading is how this app is installed,
        // and a stale build behaves exactly like a broken one — six rounds were run against
        // devices whose build could not be identified from the app itself. The executable's
        // timestamp changes on every rebuild, so it names the build well enough to tell
        // "the new one is not on the device" from "it is, and still fails".
        if let executable = Bundle.main.executableURL {
            let written = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date
            let text = written.map { stampFormatter.string(from: $0) } ?? "未知"
            lines.append("构建于：\(text)")
        }

        // The App Group is what the share extension and the app use to see each other, and
        // it is the one piece of this that the build cannot verify: the IPA is produced
        // with CODE_SIGNING_ALLOWED=NO, so the entitlement is absent from the package and
        // has to be re-applied by whatever signs it for the device. If that did not
        // happen, the container silently does not exist and the handover fails with no
        // error anywhere — so the state is reported here rather than left to be inferred.
        if AppGroup.isAvailable, let container = AppGroup.containerURL {
            lines.append("App Group：可用")
            lines.append("  \(AppGroup.identifier)")
            lines.append("  收件箱待取：\(AppGroup.pendingFileCount()) 个")
            lines.append("  \(container.path)")
        } else {
            lines.append("App Group：不可用（签名未带 \(AppGroup.identifier)）")
        }

        lines.append("分享扩展：\(shareExtensionInstalled ? "已安装" : "未安装")")

        // Whether the signing tool signed the nested pieces, not just the outer app.
        //
        // The CI package is built with `CODE_SIGNING_ALLOWED=NO`, so every `_CodeSignature`
        // in it is the work of whatever signed it for the device. A signed main bundle
        // with an unsigned `.appex` is the one failure that is indistinguishable from
        // "the extension is installed but the system never starts it": iOS refuses to
        // load an extension whose signature it cannot verify, and tells the app nothing.
        // Reading the seal back is the only way to tell those two apart from in here.
        func sealState(of url: URL) -> String {
            let seal = url.appendingPathComponent("_CodeSignature/CodeResources")
            guard FileManager.default.fileExists(atPath: seal.path) else { return "无" }
            let size = (try? FileManager.default.attributesOfItem(atPath: seal.path))?[.size] as? Int ?? 0
            return "有（\(size) 字节）"
        }

        lines.append("主包签名：\(sealState(of: Bundle.main.bundleURL))")
        if let plugins = Bundle.main.builtInPlugInsURL {
            let appex = plugins.appendingPathComponent("3D-Views-Share.appex")
            lines.append("扩展签名：\(sealState(of: appex))")
        } else {
            lines.append("扩展签名：扩展目录不可得")
        }

        // Whether the extension has ever actually been brought up. "Not installed",
        // "installed but never started" and "started but never finished" are three
        // different faults, and a missing handoff record only rules out the third — this
        // line is what separates the other two.
        if let started = AppGroup.lastExtensionStart {
            lines.append("扩展启动于：\(stampFormatter.string(from: started))")
        } else {
            lines.append("扩展启动于：从未")
        }

        if let handoff = AppGroup.lastHandoff {
            let names = handoff.names.isEmpty ? "无" : handoff.names.joined(separator: ",")
            let failures = handoff.failures.isEmpty ? "" : "｜失败 \(handoff.failures.count) 个"
            lines.append("上次分享：\(stampFormatter.string(from: handoff.at)) \(names)\(failures)")
        } else {
            lines.append("上次分享：无")
        }

        return lines
    }

    /// Empties the record. The log is meant to be read right after something failed, and a
    /// twelve-line window fills up fast; without a way to clear it, a fresh attempt is
    /// indistinguishable from an old one still sitting there.
    func clearLog() {
        handoverLog = []
        UserDefaults.standard.removeObject(forKey: handoverLogKey)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// Everything the diagnostics screen shows, as one block of text.
    ///
    /// The screen exists because this has to be read on a device that cannot be attached to
    /// a debugger — so the fastest way to see it is to copy it out in one piece rather than
    /// transcribe a dozen rows of a monospaced list by hand.
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("=== 3D-Views 导入诊断 ===")
        lines.append("生成时间：\(Self.stampFormatter.string(from: Date()))")
        lines.append("")
        lines.append("--- 安装包声明 ---")
        lines.append(contentsOf: Self.bundleFacts())
        lines.append("")
        lines.append("--- 导入记录（新→旧）---")
        if handoverLog.isEmpty {
            lines.append("（空）")
        } else {
            lines.append(contentsOf: handoverLog)
        }
        lines.append("")
        lines.append("--- 目录实况 ---")
        lines.append(contentsOf: Self.directoryFacts())
        return lines.joined(separator: "\n")
    }

    /// What is actually sitting in the folders that matter, listed by hand rather than
    /// inferred. The scan reports how many candidates it saw; this reports their names,
    /// which is what tells "the file never arrived" apart from "it arrived under a name
    /// the extension gate does not accept".
    static func directoryFacts() -> [String] {
        let manager = FileManager.default
        var lines: [String] = []

        func describe(_ label: String, _ url: URL?) {
            guard let url else {
                lines.append("\(label)：路径不可得")
                return
            }
            guard let names = try? manager.contentsOfDirectory(atPath: url.path) else {
                lines.append("\(label)：目录不存在")
                lines.append("  \(url.path)")
                return
            }
            lines.append("\(label)：\(names.count) 项")
            lines.append("  \(url.path)")
            for name in names.sorted().prefix(20) {
                lines.append("    \(name)")
            }
        }

        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        describe("共享收件箱", AppGroup.inboxURL)
        describe("Documents/Inbox", docs.appendingPathComponent("Inbox", isDirectory: true))
        describe("Documents/Imported", docs.appendingPathComponent("Imported", isDirectory: true))
        describe("Documents", docs)

        // The container-wide sweep. Every round so far has assumed the file lands in one
        // of the four folders above; if iOS hands it over some other way it would be
        // invisible here and we would keep "fixing" the wrong layer. Walk the container
        // and name any model file sitting outside those folders, whatever its depth.
        let container = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .deletingLastPathComponent()   // …/Library
            .deletingLastPathComponent()   // …（容器根）
        lines.append("")
        lines.append("--- 容器全域扫描（\(container.path)）---")
        let strays = Self.strayModelFiles(in: container)
        if strays.isEmpty {
            lines.append("未发现散落的模型文件")
        } else {
            for stray in strays.prefix(30) {
                lines.append("  \(stray)")
            }
        }

        return lines
    }

    /// Model-extension files anywhere under the container, minus the folders the scan
    /// already sweeps and minus the app's own `Imported` copies (which are the *result*
    /// of a successful import, not evidence of a delivery we missed).
    private static func strayModelFiles(in container: URL, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        let manager = FileManager.default
        let containerPath = container.standardizedFileURL.path
        guard let entries = try? manager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [String] = []
        for entry in entries {
            let path = entry.standardizedFileURL.path
            let relative = path.hasPrefix(containerPath)
                ? String(path.dropFirst(containerPath.count))
                : path
            // `Imported` holds the *results* of successful imports, so reporting them
            // would drown the one signal that matters: a file somewhere we never look.
            if relative.hasPrefix("/Documents/Imported") { continue }

            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                // `Library/Preferences` is plists only; skipping it saves depth.
                if relative == "/Library/Preferences" { continue }
                found.append(contentsOf: Self.strayModelFiles(in: entry, depth: depth + 1))
            } else if Self.supportedExtensions.contains(entry.pathExtension.lowercased()) {
                found.append(relative)
            }
        }
        return found
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
        // The destination path is a file's identity here, so importing the same name again
        // refreshes its entry rather than adding a second row pointing at the same file.
        // Without this, a handover that the sandbox scan also finds — or the same file
        // picked twice — lists twice.
        files.removeAll { $0.localPath == entry.localPath }
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
            // A format we can name gets named, and told what to do about it. Everything
            // else keeps the generic line. The previous message listed only the formats
            // that worked, which left a SolidWorks user staring at "只能打开 STEP、STP
            // 或 STL 文件" with no idea that a two-tap export in their own app fixes it.
            if let refusal = Self.unsupportedFormatMessage(for: url) {
                importFailure = refusal
            } else {
                importFailure = "只能打开 " + Self.supportedExtensions.sorted()
                    .map { $0.uppercased() }
                    .joined(separator: "、") + " 文件。"
            }
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

    /// Files the system parked in our own sandbox instead of handing the app a URL.
    ///
    /// Three different routes bring a file in from outside, and only the first delivers a
    /// URL: the document handovers above, a copy iOS drops in `Documents/Inbox`, and a
    /// copy placed in `Documents` itself — that folder is browsable in Files under
    /// 「我的 iPhone」→「3D Views」 because the app declares `UIFileSharingEnabled`. The last
    /// two are found by looking rather than by being told, which is exactly why the
    /// handover hooks can stay silent while the app is nonetheless launched for a file.
    ///
    /// `Inbox` is drained as it is read: iOS expects an app to take what it put there, and
    /// a file left in place would be imported again on every launch. Files directly under
    /// `Documents` are copied and left where they are — those belong to the user, placed
    /// deliberately — with a fingerprint recorded so the same file is not re-imported each
    /// time the app comes forward.
    ///
    /// Returns what it imported, newest scan first, and is safe to call on every launch
    /// and every return to the foreground: every half is idempotent by construction.
    @discardableResult
    func importFromSandbox(verbose: Bool = true, reason: String? = nil) -> [RecentFile] {
        let manager = FileManager.default
        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var imported: [RecentFile] = []
        var fingerprints = sandboxScanFingerprints
        var gainedFingerprint = false

        // The App Group inbox first, because it is the only route that asks nothing of
        // the system: the share extension did the copy itself, and this just picks it up.
        var sharedCount = -1
        if let shared = AppGroup.ensureInbox() {
            let names = (try? manager.contentsOfDirectory(atPath: shared.path)) ?? []
            sharedCount = names.count
            for name in names.sorted() {
                let source = shared.appendingPathComponent(name)
                // Folders are skipped before anything else, and that guard is not
                // optional: the parking folder below is itself an entry in this very
                // directory, so a version of this loop that treated every entry as a
                // file would try to move `Unsupported` into `Unsupported/Unsupported`
                // on every scan — failing, and logging a line about it, forever. That
                // is exactly what happened the first time this was written.
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                guard Self.supportedExtension(of: source) != nil else {
                    // A file the viewer cannot open used to be skipped and left where it
                    // was — which made the shared inbox permanently un-drainable. The
                    // sweep reports its size, so one unsupported file turns 「收件箱待取」
                    // into a number that never falls to zero, and every later handover
                    // reads as a failure against that stale count. Moving it aside keeps
                    // the inbox honest: the file is still there if it is ever wanted, but
                    // it no longer stands in the way of the ones that can be imported.
                    let parked = shared.appendingPathComponent("Unsupported", isDirectory: true)
                    try? manager.createDirectory(at: parked, withIntermediateDirectories: true)
                    try? manager.moveItem(at: source, to: parked.appendingPathComponent(name))
                    note("  收件箱移出（格式不支持）：\(name)")
                    continue
                }
                if let entry = importSandboxCopy(at: source, removeSource: true) {
                    imported.append(entry)
                }
            }
        }

        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        let inboxNames = (try? manager.contentsOfDirectory(atPath: inbox.path)) ?? []
        var inboxFileCount = 0
        for name in inboxNames.sorted() {
            let source = inbox.appendingPathComponent(name)
            // Same guard as the shared inbox above: a folder here is not a handover,
            // and passing one to `supportedExtension` would decide by its last dot.
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            inboxFileCount += 1
            guard Self.supportedExtension(of: source) != nil else { continue }
            if let entry = importSandboxCopy(at: source, removeSource: true) {
                imported.append(entry)
            }
        }

        var docCandidates = 0
        if let names = try? manager.contentsOfDirectory(atPath: docs.path) {
            for name in names.sorted() {
                let source = docs.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      Self.supportedExtension(of: source) != nil
                else { continue }
                docCandidates += 1

                let mark = Self.fingerprint(of: source)
                guard !fingerprints.contains(mark) else { continue }
                if let entry = importSandboxCopy(at: source, removeSource: false) {
                    imported.append(entry)
                    fingerprints.insert(mark)
                    gainedFingerprint = true
                }
            }
        }

        if gainedFingerprint { sandboxScanFingerprints = fingerprints }

        // Unconditional, and that is the whole point of this line. Six rounds of
        // configuration guessing were run against a log that only spoke when an import
        // *succeeded* — so "the scan ran and found nothing", "the scan never ran" and
        // "the new build was never installed" all looked identical, and whichever one
        // was assumed drove the next wrong change. One line now tells them apart.
        // Also speaks on a quiet pass when it actually found something. The sweep's later
        // retries are exactly where a file that landed after launch turns up, and an
        // import happening there must not be the one event the log omits.
        if verbose || !imported.isEmpty {
            let sharedText = sharedCount < 0 ? "容器不可用" : "\(sharedCount) 项"
            // Which pass this was. Several scans run within a second of each other —
            // launch, return to the foreground, the sweep's retries, this screen opening —
            // and without the reason they are identical rows that cannot be told apart,
            // which is how a real handover gets misread as a refresh.
            let origin = reason.map { "（\($0)）" } ?? ""
            note("扫描\(origin)：共享 \(sharedText)｜Inbox \(inboxFileCount) 个文件（\(inboxNames.count) 项）｜Documents \(docCandidates) 个候选｜导入 \(imported.count) 个")
        }

        if !imported.isEmpty {
            importFailure = nil
            pendingOpen = imported[0]
        }
        return imported
    }

    /// The sweep currently waiting to run its retries, so a burst of activation
    /// notifications leaves one pending sweep rather than one per notification.
    private var sweepTask: Task<Void, Never>?

    /// Looks for a handover now, then again a few times over the next few seconds.
    ///
    /// The retries are the part that matters. A launch caused by opening a document runs
    /// `didFinishLaunching` *before* iOS has finished copying the file into
    /// `Documents/Inbox`, so a single scan at that moment can legitimately see an empty
    /// folder — and the `scenePhase` observer in `HomeView` does not reliably cover it,
    /// because on a cold launch the view can mount already `.active`, leaving `onChange`
    /// with no change to report. Between them, those two are enough to miss a file that
    /// arrived perfectly well. It is also what makes the share extension work without
    /// the app ever being handed a URL.
    func scheduleInboxSweep(reason: String) {
        importFromSandbox(reason: reason)
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            for delay in [300, 1000, 2500] {
                try? await Task.sleep(for: .milliseconds(delay))
                if Task.isCancelled { return }
                // Quiet unless something turns up. Three retries per activation would
                // otherwise bury the one line that matters, and the retries are exactly
                // where a late-arriving file shows itself.
                self?.importFromSandbox(verbose: false, reason: reason)
            }
        }
    }

    /// The single entry point for a URL from outside the app, whichever door it used.
    ///
    /// The app registers `3dviews://` so the share extension has something to call when
    /// it tries to pull the app forward. That URL names no file — it means "go and look
    /// in the shared inbox" — and handing it to `receiveExternalFile` would reject it as
    /// an unsupported type and raise a false 「无法导入」 alert.
    func handleIncomingURL(_ url: URL, source: String) {
        if url.scheme?.lowercased() == AppGroup.wakeUpScheme {
            note("\(source)：收到本 App 链接")
            scheduleInboxSweep(reason: source)
            return
        }
        receiveExternalFile(at: url, source: source)
    }

    /// How many files the share extension has left waiting. Shown in `SettingsView`.
    func sharedInboxFileCount() -> Int {
        AppGroup.pendingFileCount()
    }

    /// Whether the installed bundle actually carries the share extension. Read from the
    /// built product rather than the source tree: a side-loaded build need not be the one
    /// in the repository, and a missing `.appex` changes what the failure means.
    static var shareExtensionInstalled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: plugins.path)
        else { return false }
        return names.contains { $0.hasSuffix(".appex") }
    }

    /// Imports one file found inside our own sandbox. Never throws: a scan runs over
    /// whatever happens to be there, and one unreadable file must not stop the rest.
    private func importSandboxCopy(at source: URL, removeSource: Bool) -> RecentFile? {
        do {
            let entry = try addFile(sourceURL: source)
            if removeSource { try? FileManager.default.removeItem(at: source) }
            note("  沙盒导入：\(entry.fileName)")
            return entry
        } catch {
            note("  沙盒导入失败：\(source.lastPathComponent)（\(error.localizedDescription)）")
            return nil
        }
    }

    /// Identifies a file by where it is, how big it is, and when it last changed — enough
    /// to tell "the same file, still sitting there" apart from "a file just put there".
    private static func fingerprint(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let changed = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(url.standardizedFileURL.path)|\(size)|\(changed)"
    }

    private var sandboxScanFingerprints: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: sandboxScanKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: sandboxScanKey) }
    }

    /// Whether a URL handed over from another app names a file this viewer can open.
    ///
    /// The path extension alone is not enough. A share sheet's temporary copy can arrive
    /// under a URL that has no path extension at all — the name still carries one, and
    /// the UTI the sender tagged it with carries one too — and dropping those on the
    /// floor is the silent half of "the app opened but no file came in". All three are
    /// consulted, and only a URL that fails every one of them is rejected.
    private static func looksLikeCADFile(_ url: URL) -> Bool {
        let supported = Self.supportedExtensions

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

    /// The type the system actually tags a file with — path extension plus the UTI from
    /// `contentType` — for a file that reached the app through the in-app picker.
    ///
    /// That path works, which makes it the only way to learn what UTI Files tags a
    /// `.step`/`.stl` with on the real device. It is what the catch-all `public.data`
    /// entry in `CFBundleDocumentTypes` is currently standing in for: once the real UTI
    /// is known, the declaration can be narrowed from "any data file" back to the
    /// specific type, which is what it ought to name.
    static func describeType(of url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "无扩展名" : url.pathExtension
        let identifier = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?
            .identifier
        return "\(ext) / \(identifier ?? "UTI 未知")"
    }

    /// The message for a file that is recognisably a CAD format we cannot read, or `nil`
    /// when the extension means nothing in particular.
    ///
    /// Separate from the gate above because the two want different things: the gate is a
    /// yes/no on the path extension, and this is the sentence shown to a person. Only the
    /// second benefits from knowing *which* format was refused — a SolidWorks part gets
    /// the export advice, a stray `.txt` gets the generic list.
    static func unsupportedFormatMessage(for url: URL) -> String? {
        guard let label = knownUnsupportedFormats[url.pathExtension.lowercased()] else {
            return nil
        }
        return "暂不支持 \(label)（.\(url.pathExtension.lowercased())）原生格式。"
            + "请在原软件里另存为 STEP 或 IGES 后再打开。"
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
