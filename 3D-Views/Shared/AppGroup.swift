//
//  AppGroup.swift
//  3D-Views
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

    /// The scheme the extension uses to pull the host app forward after a share.
    /// Registered by the app target under `CFBundleURLTypes`.
    static let wakeUpScheme = "3dviews"

    private static let inboxFolderName = "Inbox"
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

    @discardableResult
    static func ensureInbox() -> URL? {
        guard let inbox = inboxURL else { return nil }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
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
    static func pendingFileCount() -> Int {
        guard let inbox = inboxURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path)
        else { return 0 }
        return names.count
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
