//
//  FileHistory.swift
//  Views
//

import Foundation
import ObjectiveC
import UniformTypeIdentifiers
import UIKit

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
    ///
    /// This is intentionally replayable state rather than a one-shot callback: a cold launch
    /// can finish importing before `HomeView` has mounted. The view receives the current value
    /// through Combine and clears it only after appending the destination.
    @Published var pendingOpen: RecentFile?

    /// Publishes a successfully imported file for the home screen to open. Keeping this as
    /// replayable state is important: URL delivery and the first Inbox scan can finish before
    /// `HomeView` has mounted during a cold launch. Re-publishing the same history row is a
    /// lifecycle duplicate, not a second import.
    func publishPendingOpen(_ entry: RecentFile) {
        guard pendingOpen?.id != entry.id else { return }
        pendingOpen = entry
    }

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
        if supportedExtensions.contains(ext) { return ext }

        // Some document providers hand over a security-scoped URL with no useful
        // filename. The content type is still available from the URL resource values.
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let inferred = type.preferredFilenameExtension?.lowercased(),
           supportedExtensions.contains(inferred) {
            return inferred
        }
        return nil
    }

    private init() {
        // Recovery before `load()`, deliberately: a file restored here is back on disk by the
        // time the history is filtered for missing files, so a row that names it is not
        // dropped a moment before the file reappears.
        let recovered = recoverInterruptedImports()
        load()
        adoptRecoveredImports(recovered)
    }

    /// Finishes an import the previous process was killed in the middle of, and returns the
    /// entries that had to be put back.
    ///
    /// Everything in `Imported/.staging` is a *complete* copy — it is written in full before
    /// the destination is touched — so the only question is what to do with each one. If the
    /// destination exists, the import finished and the crumb is just the leftover of a swap
    /// that got there; if it does not, the process died between the two renames and this is
    /// the import. The caller adds the rows, because a file that came back must be listed —
    /// otherwise the very next collection pass would see an unreferenced file and delete what
    /// recovery just restored.
    private func recoverInterruptedImports() -> [RecentFile] {
        let manager = FileManager.default
        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importedDir = docs.appendingPathComponent("Imported", isDirectory: true)
        let staging = Self.stagingDirectory(in: importedDir)
        guard let names = try? manager.contentsOfDirectory(atPath: staging.path) else { return [] }

        var recovered: [RecentFile] = []
        var stranded = 0
        for name in names.sorted() {
            let crumb = staging.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: crumb.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }

            let destination = importedDir.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) {
                removeQuietly(crumb)
                continue
            }
            do {
                try manager.moveItem(at: crumb, to: destination)
                recovered.append(
                    RecentFile(
                        id: UUID(),
                        fileName: name,
                        localPath: name,
                        // The file's own timestamp, which is the only honest answer for when
                        // this import happened: the row that would have carried the real date
                        // was never written.
                        openedAt: Self.modified(destination)
                    )
                )
                ownedImportNames.insert(name)
            } catch {
                // Left where it is, and the folder is then left alone: a crumb that cannot be
                // moved is still the only complete copy of that file.
                stranded += 1
            }
        }

        if stranded == 0 { try? manager.removeItem(at: staging) }
        return recovered
    }

    /// Lists the imports recovery put back, then runs the launch's one collection pass.
    ///
    /// A recovered file must get a row here or it is indistinguishable from an orphan, and the
    /// collection pass that follows is exactly what would delete it.
    private func adoptRecoveredImports(_ recovered: [RecentFile]) {
        if !recovered.isEmpty {
            let known = Set(files.map(\.localPath))
            let fresh = recovered.filter { !known.contains($0.localPath) }
            if !fresh.isEmpty {
                files = (fresh + files).sorted { $0.openedAt > $1.openedAt }
                if files.count > 20 { files = Array(files.prefix(20)) }
                save()
            }
        }
        // Collection last, and the launch's only pass: everything a launch can make
        // collectable — a dropped row, a restored file, a file the user deleted from Files —
        // has happened by the time this runs.
        pruneStorage(verbose: false)
    }

    /// Copies a file into `Documents/Imported` and makes it the newest history entry.
    ///
    /// The copy is **staged**: the new bytes are written in full under `Imported/.staging/`
    /// and only then take the destination's place. The previous version removed the
    /// destination and then copied onto it, so a copy that failed destroyed the working copy
    /// already sitting there — the one case where a failed re-import cost the user more than
    /// the import was worth. A process killed inside the swap leaves the complete file in the
    /// staging folder, and `recoverInterruptedImports` finishes the job on the next launch.
    func addFile(sourceURL: URL) throws -> RecentFile {
        let manager = FileManager.default
        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importedDir = docs.appendingPathComponent("Imported", isDirectory: true)
        try? manager.createDirectory(at: importedDir, withIntermediateDirectories: true)

        let name = sourceURL.lastPathComponent
        let dest = importedDir.appendingPathComponent(name)

        // A source that already *is* the destination: re-importing a file out of
        // `Imported` itself, which is reachable in Files under 「我的 iPhone」→「3D Views」
        // because the app declares `UIFileSharingEnabled`. Copying a file onto itself is not
        // a no-op — the old code removed the destination first, so the source was gone
        // before it could be read and the import failed *and* took the working copy with it.
        // There is nothing to copy in this case; the row is refreshed below.
        if sourceURL.standardizedFileURL.path != dest.standardizedFileURL.path {
            try stage(sourceURL, at: dest, in: importedDir)
        }

        let entry = RecentFile(
            id: UUID(),
            fileName: name,
            localPath: name,
            openedAt: Date()
        )
        // The destination path is a file's identity here, so importing the same name again
        // refreshes its entry rather than adding a second row pointing at the same file.
        // Without this, a handover that the sandbox scan also finds — or the same file
        // picked twice — lists twice.
        files.removeAll { $0.localPath == entry.localPath }
        files.insert(entry, at: 0)
        // This list *is* the retention policy, and from here on it is a real one: the 21st
        // import drops the oldest row and now also releases that row's bytes on disk. Until
        // this, the row was dropped and the file stayed put, so `Imported` grew without
        // bound behind a list that never showed more than 20 entries.
        if files.count > 20 { files = Array(files.prefix(20)) }
        ownedImportNames.insert(name)
        save()
        // Collection rides along with the moment the referenced set changed, which is the
        // only moment anything becomes collectable.
        pruneStorage(verbose: false)
        return entry
    }

    /// Copies `source` into place, writing the whole file first and only then replacing what
    /// the destination name already holds.
    ///
    /// The order is the point. The copy lands in full under `Imported/.staging/` before the
    /// destination is touched at all, so a copy that fails — a truncated provider file, a
    /// permission the sandbox will not grant — fails *before* it can destroy the working copy
    /// sitting there, which is exactly what remove-then-copy did. From there the swap is two
    /// renames inside one directory.
    ///
    /// A process killed between those renames leaves the complete new file in the staging
    /// folder with no destination to show for it. That is left alone deliberately rather than
    /// cleaned up: it is the only complete copy of that file, and `recoverInterruptedImports`
    /// puts it in place on the next launch.
    private func stage(_ source: URL, at destination: URL, in importedDir: URL) throws {
        let manager = FileManager.default
        let staging = Self.stagingDirectory(in: importedDir)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let crumb = staging.appendingPathComponent(destination.lastPathComponent)
        // A crumb under this name can only be a leftover: recovery empties this folder before
        // any import runs, and only one import is ever in flight on the main actor.
        try? manager.removeItem(at: crumb)
        try manager.copyItem(at: source, to: crumb)

        try? manager.removeItem(at: destination)
        try manager.moveItem(at: crumb, to: destination)
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
            return nil
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Always import the durable App Group copy. The provider URL may stop being readable
        // as soon as the document-open callback returns, so falling back to the original URL
        // after a queue failure only hides the real handoff error.
        guard let queuedName = AppGroup.queue(fileAt: url, preferredName: url.lastPathComponent),
              let pending = AppGroup.pendingURL?.appendingPathComponent(queuedName) else {
            importFailure = "无法保存外部文件：系统提供的文件 URL 不可读取或共享容器不可用。"
            return nil
        }

        do {
            let entry = try addFile(sourceURL: pending)
            try? FileManager.default.removeItem(at: pending)
            importFailure = nil
            publishPendingOpen(entry)
            return entry
        } catch {
            importFailure = "导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Files the system parked in our own sandbox instead of handing the app a URL.
    ///
    /// A handover hands over a URL; a sweep looks for what was left behind. Both are live
    /// now, and they are independent: a file can arrive by either, so a silent URL log does
    /// not mean nothing arrived, and a file waiting here does not mean a URL went missing.
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

        // The App Group inbox first, and it is the live route: `project.yml` embeds the
        // share extension in the app (the main target's dependencies list
        // `- target: Views-Share`), so this is the half that picks up what the extension
        // deposited. It asks nothing of the system — the extension did the copy itself —
        // which is why it is read before any of the routes that depend on iOS handing the
        // app a URL.
        if let pending = AppGroup.pendingURL {
            let pendingNames = (try? manager.contentsOfDirectory(atPath: pending.path)) ?? []
            for name in pendingNames.sorted() {
                let source = pending.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                guard Self.supportedExtension(of: source) != nil else {
                    park(source, in: pending)
                    continue
                }
                if let entry = importQueuedFile(at: source) {
                    imported.append(entry)
                } else {
                    park(source, in: pending)
                }
            }
        }
        if let shared = AppGroup.ensureInbox() {
            // Files only. The inbox also holds the `Unsupported` parking folder below, and
            // counting that folder made 「收件箱待取」 stick at 1 after a single share of a
            // format the viewer cannot read.
            let names = AppGroup.pendingFileNames()
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
                    park(source, in: shared)
                    continue
                }
                if let entry = importSandboxCopy(at: source, removeSource: true) {
                    imported.append(entry)
                }
            }
        }

        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        let inboxNames = (try? manager.contentsOfDirectory(atPath: inbox.path)) ?? []
        for name in inboxNames.sorted() {
            let source = inbox.appendingPathComponent(name)
            // Same guard as the shared inbox above: a folder here is not a handover,
            // and passing one to `supportedExtension` would decide by its last dot.
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            guard Self.supportedExtension(of: source) != nil else {
                // The same treatment the shared inbox gives an unreadable format. Leaving it
                // in place is what made this Inbox undrainable: iOS expects an app to take
                // what it puts here, and a file that can never be imported would be
                // re-reported by every scan, for as long as the app stays installed. The two
                // inboxes used to disagree about this, which is the kind of difference that
                // only shows up as "the count is stuck" months later.
                park(source, in: inbox)
                continue
            }
            if let entry = importSandboxCopy(at: source, removeSource: true) {
                imported.append(entry)
            }
        }

        if let names = try? manager.contentsOfDirectory(atPath: docs.path) {
            for name in names.sorted() {
                let source = docs.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      Self.supportedExtension(of: source) != nil
                else { continue }

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

        // Collection rides along with a real scan — launch, return to the foreground, the
        // 重新扫描 button — and deliberately not with the sweep's silent retries, which run
        // three more times inside a couple of seconds of every activation.
        if verbose { pruneStorage(verbose: true) }

        if !imported.isEmpty {
            importFailure = nil
            publishPendingOpen(imported[0])
        }
        return imported
    }

    /// 消费分享桥接留下的待导入文件。
    ///
    /// 扩展负责把临时文件复制进 App Group Inbox，主 App 在启动、回前台和激活阶段
    /// 调用本方法取走并导入到自己的沙盒；重复调用是幂等的。
    @discardableResult
    func consumePendingShareImportIfNeeded(reason: String) -> [RecentFile] {
        return importFromSandbox(reason: "交接·\(reason)")
    }

    /// The sweep currently waiting to run its retries, so a burst of activation
    /// notifications leaves one pending sweep rather than one per notification.
    private var sweepTask: Task<Void, Never>?

    /// Looks for a handover now, then again a few times over the next few seconds.
    ///
    /// The retries are the part that matters, and they matter for both live routes. A launch
    /// caused by opening a document runs `didFinishLaunching` *before* iOS has finished
    /// copying the file into `Documents/Inbox`, so a single scan at that moment can
    /// legitimately see an empty folder — and the `scenePhase` observer in `HomeView` does
    /// not reliably cover it, because on a cold launch the view can mount already `.active`,
    /// leaving `onChange` with no change to report. Between them, those two are enough to
    /// miss a file that arrived perfectly well. The same retries are what made the share
    /// extension work without the app ever being handed a URL.
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

    /// The single entry point for a URL from outside the app.
    ///
    /// Two doors now lead here and both are live again:
    ///
    /// - `application(_:open:options:)` on `AppDelegate`, and
    /// - `scene(_:openURLContexts:)` / `connectionOptions.urlContexts` on `SceneDelegate`.
    ///
    /// The second is the one that matters for the document-open path: when iOS starts the
    /// app to open a document, the URL arrives in the scene's connection options, not in
    /// `launchOptions`. That distinction is what made this path look dead for three rounds
    /// of measurements — there was no scene to receive it. `receiveExternalFile` recognises
    /// a file it has already taken, so both doors being knocked on is harmless.
    ///
    /// It dispatches on scheme now. The sentence that used to stand here said there was
    /// nothing to special-case, on the reasoning that the scheme existed only to serve
    /// `extensionContext.open`; `CFBundleURLTypes` was restored to the plist afterwards, and
    /// that sentence became false. An unhandled `views://` URL fell through to the file
    /// path, was found to carry no CAD extension, and was answered with 「只能打开 STEP、STP…」.
    func handleIncomingURL(_ url: URL, source: String) {
        if url.scheme?.lowercased() == Self.customScheme {
            handleCustomScheme(url, source: source)
            return
        }
        receiveExternalFile(at: url, source: source)
    }

    /// The scheme this app registers in `CFBundleURLSchemes` (`project.yml`).
    static let customScheme = "views"

    /// Handles `views://…` — the one route here that is *addressed* rather than delivered.
    ///
    /// Shape: `views://import?file=<the model's address>`. The host is deliberately not
    /// checked, so `import`, `open` and an empty host all behave the same, and both `file`
    /// and `url` are accepted as the parameter name. That slack is the point: this route
    /// exists to be typed into a web page, a note or a shortcut, and refusing a link over a
    /// synonym is a poor trade for a check nobody benefits from.
    ///
    /// An `http(s)` address is downloaded first — see `receiveRemoteFile`. A `file://`
    /// address goes straight to the local path, which makes this form a plain alias for an
    /// ordinary file hand-over. Anything else is refused *with the shape that would have
    /// worked*, because a hand-typed link is the only way to arrive here wrong.
    private func handleCustomScheme(_ url: URL, source: String) {

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            importFailure = "链接无法解析：\(url.absoluteString)"
            return
        }

        let queryItems = components.queryItems ?? []
        let addressed = queryItems
            .first { $0.name == "file" || $0.name == "url" }?
            .value

        // The share extension uses the same scheme as a wake-up signal after depositing
        // the file into App Group/Inbox. There is deliberately no model URL here: the
        // inbox is the payload, and the scan publishes pendingOpen after it finds it.
        if queryItems.contains(where: { $0.name == "handoff" && $0.value == "1" }) {
            consumePendingShareImportIfNeeded(reason: "扩展唤起")
            scheduleInboxSweep(reason: "扩展唤起")
            return
        }

        guard let addressed, !addressed.isEmpty else {
            importFailure = "链接里没有模型地址。正确写法：\(Self.customScheme)://import?file=https://…/part.step"
            return
        }

        guard let target = URL(string: addressed) else {
            importFailure = "链接里的地址无法解析：\(addressed)"
            return
        }

        switch target.scheme?.lowercased() {
        case "http", "https":
            Task { await self.receiveRemoteFile(at: target, source: source) }
        case "file":
            receiveExternalFile(at: target, source: "\(source)（\(Self.customScheme) 转本地）")
        default:
            importFailure = "只支持 http／https／file 地址，收到「\(target.scheme ?? "无 scheme")」。"
        }
    }

    /// Downloads a model named by an `http(s)` address, then imports it through the same
    /// door a locally handed-over file uses.
    ///
    /// The download deliberately imports nothing itself. It lands the bytes under the remote
    /// file's own name and calls `receiveExternalFile` — so the format gate, the dedup, the
    /// copy into `Documents/Imported`, the history row and the `pendingOpen` navigation all
    /// stay in exactly one place, and the remote route cannot drift away from the local one.
    ///
    /// The name has to be restored by hand. `URLSession.download(from:)` writes to a randomly
    /// named file in the system temp directory, and every gate downstream reads the *path
    /// extension* to decide what a file is: a random name would be refused as an unknown
    /// type. That temp file is also removed as soon as this returns, whichever way it
    /// returns, so it is moved somewhere this function owns before anything else touches it.
    @discardableResult
    func receiveRemoteFile(at url: URL, source: String) async -> RecentFile? {

        // Refused before the download rather than after it: an address whose own file name
        // cannot be a model should not cost the user megabytes of mobile data to rule out.
        guard Self.looksLikeCADFile(url) else {
            if let refusal = Self.unsupportedFormatMessage(for: url) {
                importFailure = refusal
            } else {
                importFailure = "链接结尾不是可打开的文件名（\(url.lastPathComponent)）。"
            }
            return nil
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            importFailure = "下载失败：无法建立临时目录（\(error.localizedDescription)）。"
            return nil
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        var downloaded: URL?
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                importFailure = "下载失败：服务器返回 \(http.statusCode)。"
                return nil
            }
            let name = url.lastPathComponent.isEmpty ? "downloaded.step" : url.lastPathComponent
            let landed = staging.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temporary, to: landed)
            downloaded = landed
        } catch {
            importFailure = "下载失败：\(error.localizedDescription)"
            return nil
        }

        guard let downloaded else {
            importFailure = "下载失败：没有得到文件。"
            return nil
        }

        return receiveExternalFile(at: downloaded, source: "\(source) 下载完成")
    }

    /// Imports one file found inside our own sandbox. Never throws: a scan runs over
    /// whatever happens to be there, and one unreadable file must not stop the rest.
    private func importSandboxCopy(at source: URL, removeSource: Bool) -> RecentFile? {
        do {
            let entry = try addFile(sourceURL: source)
            if removeSource { try? FileManager.default.removeItem(at: source) }
            return entry
        } catch {
            return nil
        }
    }

    /// Imports a file already parked in the App Group. `addFile` stages into the app's
    /// Documents/Imported directory, so this path must not queue the source again.
    private func importQueuedFile(at source: URL) -> RecentFile? {
        do {
            let entry = try addFile(sourceURL: source)
            try? FileManager.default.removeItem(at: source)
            return entry
        } catch {
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
    /// The picker path works, which makes this the only way to learn what UTI Files tags a
    /// `.step`/`.stl` with on the real device. It used to be recorded so that the catch-all
    /// `public.data` entry in `CFBundleDocumentTypes` could be narrowed from "any data file"
    /// back to the real type. That declaration went with the document-open path, so the value
    /// is now simply what the log line says it is: the extension and the UTI, side by side.
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

    // MARK: - Storage collection

    /// The names the app itself put into `Documents/Imported`.
    ///
    /// Collection has to tell two unreferenced files apart: one this app imported and then
    /// dropped from history, and one somebody placed in the folder by hand. Both have no
    /// row, and deleting the second would destroy something the app never owned — the folder
    /// is browsable in Files because the app declares `UIFileSharingEnabled`. Only a name
    /// recorded here is ever collected.
    private var ownedImportNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: ownedImportsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: ownedImportsKey) }
    }

    /// Whether `files` currently describes what is on disk.
    ///
    /// False until `load()` has read the stored history successfully. It is the interlock
    /// that keeps an unreadable history from being read as "nothing is referenced" — with
    /// garbage in that defaults entry, collection would otherwise delete every import the
    /// user has.
    private var historyIsAuthoritative = false

    private let ownedImportsKey = "OwnedImportNames"

    /// Where a staged import waits before it takes the destination's name: inside `Imported`
    /// so the final move is a rename within one directory, and dot-named so it stays out of
    /// the way in Files.
    private static let stagingFolderName = ".staging"

    private static func stagingDirectory(in importedDir: URL) -> URL {
        importedDir.appendingPathComponent(stagingFolderName, isDirectory: true)
    }

    /// How long a leftover `tmp/` staging folder is left alone: long enough that no live
    /// import could own it, short enough that a crash does not hold the disk for days.
    private static let tempStagingMaxAge: TimeInterval = 24 * 60 * 60

    /// The names of the temporary folders two other code paths create and normally clean up
    /// themselves. Named here because collection recognises them by exactly these prefixes.
    private static let remoteStagingPrefix = "RemoteImport-"
    private static let sldprtStagingPrefix = "sldprt-"

    /// How much of a parking folder is kept, and for how long the rest survives.
    private static let parkingKeepNewest = 20
    private static let parkingMaxAge: TimeInterval = 30 * 24 * 60 * 60

    /// The one entry point for storage collection, so every caller collects the same things
    /// in the same order.
    ///
    /// Called where the referenced set changes — the history being restored, a file being
    /// imported, a scan being run — rather than on a timer. Those are the only moments
    /// anything becomes collectable, and a viewer that is open for seconds at a time would
    /// spend most of a timer's ticks finding nothing.
    private func pruneStorage(verbose: Bool) {
        pruneImportedStorage()
        pruneStaleFingerprints()

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // The shared inbox is collected through its URL rather than through `ensureInbox()`:
        // collection is not a reason to create a folder.
        if let shared = AppGroup.inboxURL { _ = pruneParking(in: shared) }
        _ = pruneParking(in: docs.appendingPathComponent("Inbox", isDirectory: true))
        _ = pruneStagingDirectories()
    }

    /// Releases the bytes of imports that history no longer refers to, plus the crumbs an
    /// interrupted import can leave behind.
    ///
    /// This is what makes the 20-entry list an actual retention policy. The row for the 21st
    /// oldest import was always dropped; its file was not, so `Imported` grew a file at a
    /// time behind a list that never showed more than 20 — invisible from inside the app,
    /// and only obvious to anyone who opened the folder in Files.
    @discardableResult
    private func pruneImportedStorage() -> Int {
        guard historyIsAuthoritative else { return 0 }

        let manager = FileManager.default
        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importedDir = docs.appendingPathComponent("Imported", isDirectory: true)
        guard let names = try? manager.contentsOfDirectory(atPath: importedDir.path) else { return 0 }

        let live = Set(files.map(\.localPath))
        let owned = ownedImportNames.union(live)
        var removed = 0
        var surviving = Set<String>()

        for name in names {
            let url = importedDir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            // Folders are skipped, which is what keeps `.staging` out of this loop: it is
            // emptied by recovery at launch, not by collection.
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }

            guard owned.contains(name), !live.contains(name) else {
                surviving.insert(name)
                continue
            }
            if removeQuietly(url) { removed += 1 }
        }

        // The ownership record only has to describe what is actually in the folder, or it
        // would grow a name at a time for as long as the app is installed.
        let stillOwned = owned.intersection(surviving)
        if stillOwned != ownedImportNames { ownedImportNames = stillOwned }
        return removed
    }

    /// Keeps one inbox's parking folder from turning into an archive nobody ever opens.
    ///
    /// Parking is what makes an inbox drainable, and the parked folder was itself never
    /// collected: a user who keeps sharing a format this viewer cannot read grew it one file
    /// at a time, forever. The newest `parkingKeepNewest` are kept whatever their age; the
    /// rest go once they pass `parkingMaxAge`. Nothing that exists *only* here is lost —
    /// parking moves a copy iOS made of a file whose original is still where the user shared
    /// it from.
    @discardableResult
    private func pruneParking(in inbox: URL) -> Int {
        let manager = FileManager.default
        let parked = AppGroup.parkingURL(in: inbox)
        guard let names = try? manager.contentsOfDirectory(atPath: parked.path), !names.isEmpty else {
            return 0
        }

        var entries: [(url: URL, at: Date)] = []
        for name in names {
            let url = parked.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            entries.append((url: url, at: Self.modified(url)))
        }
        entries.sort { $0.at > $1.at }

        let cutoff = Date().addingTimeInterval(-Self.parkingMaxAge)
        var removed = 0
        for (index, entry) in entries.enumerated()
        where index >= Self.parkingKeepNewest || entry.at < cutoff {
            if removeQuietly(entry.url) { removed += 1 }
        }
        return removed
    }

    /// Removes the temporary directories an earlier process left behind.
    ///
    /// `receiveRemoteFile` cleans its own staging folder with a `defer`, and the viewer
    /// removes the STEP it converts a SolidWorks part into — but a `defer` does not run when
    /// the app is killed, so a download or a conversion interrupted by a crash leaves the
    /// whole file in `tmp/` until the system gets round to reclaiming it. The two prefixes
    /// are checked before anything is deleted: this must never reach outside the app's own
    /// staging.
    @discardableResult
    private func pruneStagingDirectories() -> Int {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: staging.path) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Self.tempStagingMaxAge)
        var removed = 0
        for name in names
        where name.hasPrefix(Self.remoteStagingPrefix) || name.hasPrefix(Self.sldprtStagingPrefix) {
            let url = staging.appendingPathComponent(name)
            guard Self.modified(url) < cutoff else { continue }
            if removeQuietly(url) { removed += 1 }
        }
        return removed
    }

    /// Drops scan fingerprints whose file is no longer there.
    ///
    /// A fingerprint can only ever answer "have I already taken this exact file", and for a
    /// path that no longer exists it cannot answer anything — it just rides along in the
    /// defaults entry until the 200-entry cap pushes it out, making the set unreadable as a
    /// picture of what is under `Documents` in the meantime.
    @discardableResult
    private func pruneStaleFingerprints() -> Int {
        let fingerprints = sandboxScanFingerprints
        let existing = Set(fingerprints.filter { mark in
            guard let path = mark.split(separator: "|", maxSplits: 1).first else { return false }
            return FileManager.default.fileExists(atPath: String(path))
        })
        guard existing.count != fingerprints.count else { return 0 }
        sandboxScanFingerprints = existing
        return fingerprints.count - existing.count
    }

    /// Moves one un-importable file out of an inbox and into that inbox's parking folder,
    /// under a name that is still free there.
    ///
    /// The free name is not a detail: the same document shared twice parks twice, and
    /// `moveItem` onto an existing name fails — which would leave the second copy in the
    /// inbox for good, the exact state parking exists to prevent.
    private func park(_ source: URL, in inbox: URL) {
        let manager = FileManager.default
        let parked = AppGroup.parkingURL(in: inbox)
        try? manager.createDirectory(at: parked, withIntermediateDirectories: true)
        try? manager.moveItem(at: source, to: Self.freeURL(for: source.lastPathComponent, in: parked))
    }

    /// A URL in `directory` that no file occupies, suffixing `-2`, `-3`… as needed. The same
    /// rule `AppGroup` applies to a deposit, for the same reason: two files must both
    /// survive the arrival of the second.
    private static func freeURL(for name: String, in directory: URL) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }

    /// Removes `url` and reports whether it is gone afterwards. `try? removeItem` alone
    /// cannot: it counts a removal that failed as a removal that happened, which is the kind
    /// of quiet overstatement this file has paid for before.
    private func removeQuietly(_ url: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.removeItem(at: url)
            return true
        } catch {
            return !manager.fileExists(atPath: url.path)
        }
    }

    /// When a file was last written, or `distantPast` when that cannot be read — so an
    /// unreadable timestamp never reads as "just now" and keeps something alive forever.
    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            // No stored history at all: nothing is referenced, and that reading *is*
            // authoritative. Collection still runs afterwards, because an import interrupted
            // before its first save can leave a complete file in the staging folder.
            historyIsAuthoritative = true
            return
        }
        guard let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else {
            // A defaults entry that cannot be decoded says nothing about which files are
            // still referenced. Reading it as "no rows, therefore nothing is referenced"
            // would delete every import on disk, so `historyIsAuthoritative` stays false and
            // collection is skipped rather than guessed at.
            return
        }
        let live = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        files = live
        historyIsAuthoritative = true
        // Rows whose file is gone used to stay in the defaults entry forever, re-filtered on
        // every launch, which left the list the app shows and the list it stores as two
        // different things. Persisting the filtered list is what makes the pruning real — and
        // it has to happen before collection, which reads `files` as the set of paths that
        // must survive.
        if live.count != decoded.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
