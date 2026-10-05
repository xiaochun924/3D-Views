//
//  AppGroup.swift
//  Views
//
//  Compiled into **both** the app and the share extension. Everything the two
//  processes have to agree on lives here: the group identifier, the inbox they hand
//  files through, and the note the extension leaves behind for the app to read.
//

import Foundation

/// The App Group the app and the share extension share.
///
/// The identifier has to appear in **both** targets' entitlements, and those
/// entitlements have to be applied by whatever signs the IPA. A build made with
/// `CODE_SIGNING_ALLOWED=NO` carries none of them, and on such a build
/// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` — so the
/// whole handover silently degrades to "the extension took the file and dropped it".
/// `SettingsView` reports which of the two states the installed build is in, because
/// that is the difference between a working handover and a silent one.
enum AppGroup {
    /// The group the self-signed install is provisioned with.
    static let identifier = "group.ffcd1c12e1a9728e.1"

    // `views://import?handoff=1` is a best-effort wake-up signal used after the extension
    // deposits a file. It is not the data channel: the App Group inbox remains authoritative
    // when iOS refuses or ignores `extensionContext.open`. The URL is kept out of this shared
    // helper because only the extension initiates it and only the host consumes it.

    private static let inboxFolderName = "Inbox"
    private static let pendingFolderName = "Pending"
    private static let handoffAtKey = "SharedHandoffAt"
    private static let handoffNamesKey = "SharedHandoffNames"
    private static let handoffFailuresKey = "SharedHandoffFailures"

    /// The shared container, or `nil` when the entitlement did not survive signing.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isAvailable: Bool { containerURL != nil }

    /// Where the extension puts what the share sheet gave it. Deliberately a plain
    /// getter — a property that creates directories as a side effect is a trap.
    /// `ensureInbox()` is the one that makes the folder.
    static var inboxURL: URL? {
        containerURL?.appendingPathComponent(inboxFolderName, isDirectory: true)
    }

    static var pendingURL: URL? {
        containerURL?.appendingPathComponent(pendingFolderName, isDirectory: true)
    }

    @discardableResult
    static func ensureInbox() -> URL? {
        guard let inbox = inboxURL else { return nil }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    @discardableResult
    static func ensurePending() -> URL? {
        guard let pending = pendingURL else { return nil }
        try? FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        return pending
    }

    /// Copies a document received by the main app into a durable App Group queue. The source
    /// URL may be security-scoped or temporary, so it is copied while the handover is live.
    @discardableResult
    static func queue(fileAt source: URL, preferredName: String? = nil) -> String? {
        guard let pending = ensurePending() else { return nil }
        let raw = preferredName.flatMap { $0.isEmpty ? nil : $0 } ?? source.lastPathComponent
        var name = sanitize(raw)
        if !source.pathExtension.isEmpty, (name as NSString).pathExtension.isEmpty {
            name += "." + source.pathExtension
        }
        let existing = pending.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: existing.path) {
            let sourceValues = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let existingValues = try? existing.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if sourceValues?.fileSize == existingValues?.fileSize,
               sourceValues?.contentModificationDate == existingValues?.contentModificationDate {
                return existing.lastPathComponent
            }
        }
        let destination = uniqueURL(for: name, in: pending)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination.lastPathComponent
        } catch {
            return nil
        }
    }

    /// The folder an inbox parks what the app cannot read, so the inbox itself can be
    /// drained.
    ///
    /// A format with no reader cannot be imported and must not be deleted either — this
    /// copy is the only one the app holds of what the user shared — so it is moved aside:
    /// still findable, no longer standing in the way of the files that can be imported.
    /// The name lives here because the app parks into two different inboxes (the shared
    /// container and `Documents/Inbox`) and has to collect both the same way.
    static let parkingFolderName = "Unsupported"

    static func parkingURL(in inbox: URL) -> URL {
        inbox.appendingPathComponent(parkingFolderName, isDirectory: true)
    }

    /// Copies one file into the shared inbox and returns the name it landed under.
    ///
    /// Always a copy: the URL the share sheet hands over points at a temporary file
    /// that the system reclaims as soon as the extension returns, so moving it would
    /// leave the app an inbox entry with nothing behind it. Returns `nil` when the
    /// container is unreachable or the copy fails.
    @discardableResult
    static func deposit(fileAt source: URL, preferredName: String? = nil) -> String? {
        guard let inbox = ensureInbox() else { return nil }

        let raw = preferredName.flatMap { $0.isEmpty ? nil : $0 } ?? source.lastPathComponent
        var name = sanitize(raw)

        // A provider's `suggestedName` is often bare ("drawing"), and inheriting the
        // source's extension is what keeps the app's own extension-based gate able to
        // recognise the file at all.
        let sourceExtension = source.pathExtension
        if !sourceExtension.isEmpty, (name as NSString).pathExtension.isEmpty {
            name += "." + sourceExtension
        }

        let destination = uniqueURL(for: name, in: inbox)

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination.lastPathComponent
        } catch {
            return nil
        }
    }

    /// What the extension left for the app, so the app can say "the share arrived"
    /// even when nothing else about it is observable.
    static func recordHandoff(names: [String], failures: [String] = []) {
        guard let defaults = UserDefaults(suiteName: identifier) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: handoffAtKey)
        defaults.set(names, forKey: handoffNamesKey)
        defaults.set(failures, forKey: handoffFailuresKey)
    }

    static var lastHandoff: (at: Date, names: [String], failures: [String])? {
        guard let defaults = UserDefaults(suiteName: identifier),
              let stamp = defaults.object(forKey: handoffAtKey) as? TimeInterval
        else { return nil }
        return (
            Date(timeIntervalSince1970: stamp),
            defaults.stringArray(forKey: handoffNamesKey) ?? [],
            defaults.stringArray(forKey: handoffFailuresKey) ?? []
        )
    }

    /// Whether anything is waiting in the shared inbox — the count `SettingsView`
    /// shows and the app uses to decide whether a sweep is worth logging.
    ///
    /// Files only, and that is the whole fix. The inbox also holds the `Unsupported`
    /// parking folder the app keeps for shares it has no reader for, and counting that
    /// folder as a waiting file is not a small mistake: it made 「收件箱待取」 read 1
    /// forever after a single unsupported share, so every later handover looked like it
    /// had failed against a number that could never fall back to zero.
    static func pendingFileCount() -> Int {
        pendingFileNames().count
    }

    /// The files waiting in the shared inbox, folders excluded. An unreachable container
    /// reads as "nothing waiting" rather than as an error, because that is what the
    /// caller can act on.
    static func pendingFileNames() -> [String] {
        guard let inbox = inboxURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path)
        else { return [] }
        let manager = FileManager.default
        return names.filter { name in
            var isDirectory: ObjCBool = false
            let path = inbox.appendingPathComponent(name).path
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
            return !isDirectory.boolValue
        }
    }

    // MARK: - Extension liveness

    private static let extensionStartKey = "SharedExtensionStartedAt"

    /// Written by the share extension the moment it is up, before it has looked at a
    /// single attachment.
    ///
    /// A missing handoff record cannot tell "iOS never launched the extension at all"
    /// from "iOS launched it and it died before it could record anything" — and those
    /// two need completely different fixes. This is the earliest line the extension is
    /// able to leave, so the two cases stop looking the same from the app's side.
    static func recordExtensionStart() {
        UserDefaults(suiteName: identifier)?.set(Date(), forKey: extensionStartKey)
    }

    /// When the share extension last came up, or nil if it never has.
    static var lastExtensionStart: Date? {
        UserDefaults(suiteName: identifier)?.object(forKey: extensionStartKey) as? Date
    }

    // MARK: - Finishing trail

    private static let finishTrailKey = "SharedFinishTrail"

    /// Every step the extension takes *after* the handover, in order, newest last.
    ///
    /// This exists for one reason: the extension writes nothing at all before calling
    /// `completeRequest`, so the app could previously say "the extension came up" and "the
    /// file was handed over" and still not tell these two apart —
    ///
    ///   * the extension was killed, so `completeRequest` never ran;
    ///   * it finished normally and the sheet closed, it just never brought the host app
    ///     forward.
    ///
    /// They look identical on screen — the sheet goes away, the home screen appears — so
    /// the symptom cannot separate them, and the two need different fixes. With this trail,
    /// **which step the last entry names** is the answer.
    ///
    /// Each entry is `"<epoch seconds>|<text>"`. The moment and the text are kept in one
    /// string rather than two parallel arrays because the only thing this trail is good for
    /// is order and timing, and two arrays can drift apart.
    ///
    /// The finishing path calls this from the main actor, which is safe: the container is
    /// already mounted by then (`recordExtensionStart` and `recordHandoff` both ran first),
    /// so this is a warm in-memory defaults write and not another first mount — the mount is
    /// the one thing in this file that must not be moved onto the main thread.
    static func recordFinishStep(_ step: String) {
        guard let defaults = UserDefaults(suiteName: identifier) else { return }
        var trail = defaults.stringArray(forKey: finishTrailKey) ?? []
        trail.append("\(Date().timeIntervalSince1970)|\(step)")
        // One share takes a dozen steps at most. The cap exists only so no odd path can grow
        // this into an unbounded array; the trail is never this long.
        if trail.count > 40 { trail.removeFirst(trail.count - 40) }
        defaults.set(trail, forKey: finishTrailKey)
    }

    /// The finishing trail, oldest first. Entries accumulate across shares, so a reader that
    /// wants a single run filters by `lastExtensionStart`.
    static var finishTrail: [(at: Date, step: String)] {
        guard let defaults = UserDefaults(suiteName: identifier),
              let trail = defaults.stringArray(forKey: finishTrailKey)
        else { return [] }
        return trail.compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
            return (Date(timeIntervalSince1970: seconds), String(parts[1]))
        }
    }

    // MARK: - Helpers

    /// Strips the path separators and the traversal a share sheet's file name could
    /// in principle carry, so a deposit can never escape the inbox.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "shared-file" }
        return cleaned
    }

    /// A file name that is free in `directory`, suffixing `-2`, `-3`… as needed.
    /// Two shares of the same document name must both survive; overwriting the first
    /// would look exactly like a lost import.
    private static func uniqueURL(for name: String, in directory: URL) -> URL {
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
}
