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

        // The document-type and exported-UTI blocks that used to print here were deleted
        // when the declarations themselves were, on the reasoning that a row of 无 only
        // invites another round of tuning a path that is not in use. That reasoning no
        // longer holds: the document-open path IS the only path now, and these declarations
        // are its entire entry point. They also live only in the *installed* bundle —
        // `Info.plist` is merged from `project.yml` at build time, and a side-loaded build
        // need not be the one in the source tree, so what is compiled here proves nothing
        // about what is running on the device.
        //
        // Printed raw rather than summarised. The question being asked is precisely
        // "did the declaration survive into the binary", and a count would hide a
        // declaration that arrived with the wrong rank or the wrong type list.
        if let types = info["CFBundleDocumentTypes"] as? [[String: Any]] {
            lines.append("文档类型：\(types.count) 条")
            for type in types {
                let name = type["CFBundleTypeName"] as? String ?? "?"
                let rank = type["LSHandlerRank"] as? String ?? "未声明"
                let contents = (type["LSItemContentTypes"] as? [String]) ?? []
                lines.append("  \(name)｜rank=\(rank)｜\(contents.joined(separator: ","))")
            }
        } else {
            lines.append("文档类型：未声明")
        }

        if let exported = info["UTExportedTypeDeclarations"] as? [[String: Any]] {
            lines.append("自定义类型：\(exported.count) 条")
            for type in exported {
                let id = type["UTTypeIdentifier"] as? String ?? "?"
                let tags = (type["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
                let exts = (tags as? [String])?.joined(separator: ",") ?? "?"
                lines.append("  \(id)｜\(exts)")
            }
        } else {
            lines.append("自定义类型：未声明")
        }

        // Whether the app is willing to open a document in place, which is what decides
        // whether Files hands over a copy it made or a URL pointing at the original. It is
        // the setting most likely to be the difference between "the app opened and the file
        // did not arrive" and "the file arrived under a name we did not expect".
        let inPlace = (info["LSSupportsOpeningDocumentsInPlace"] as? Bool)
            .map { $0 ? "true" : "false" } ?? "未声明"
        lines.append("就地打开：\(inPlace)")

        // Kept for the same reason as the App Group block above, and reworded because the
        // extension is no longer the thing that fills this container: the document-open
        // path does not touch the App Group at all, so `未安装` here is the expected value
        // rather than a finding. It is still worth a line, because it is what tells a
        // reader that the build on the device is the one this source tree describes.

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

        // The extension is deliberately not embedded any more, so "未安装" is the expected
        // reading and must not be mistaken for a fault. Saying which of the two it is here
        // keeps the diagnostic page honest: the same line, two opposite meanings.
        //
        // This is only ever shown, never acted on. The document-open path below does not
        // consult it, so a missing .appex changes what the reader should conclude — not
        // what the app does.
        lines.append("分享扩展：\(shareExtensionInstalled ? "已安装" : "未安装（按当前方案，正常）")")

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
        // The extension is embedded again, so this line is load-bearing rather than
        // forward-looking: an unsigned `.appex` inside a self-signed IPA is a real failure
        // mode, and this is the only place it would show. `无` now means the extension is
        // missing or was not signed, not that none was expected.
        lines.append("扩展签名：\(sealState(of: Bundle.main.bundleURL.appendingPathComponent("PlugIns/Views-Share.appex")))")

        // Whether the extension has ever actually been brought up. "Not installed",
        // "installed but never started" and "started but never finished" are three
        // different faults, and a missing handoff record only rules out the third — this
        // line is what separates the other two.
        //
        // With the extension back in the bundle this should read a fresh timestamp after
        // every share. 从未 on a build whose 扩展签名 line reads 有 means the share sheet
        // never launched the extension at all, which is a different bug from the extension
        // running and failing to hand anything over — the handoff lines below split those.
        if let started = AppGroup.lastExtensionStart {
            lines.append("扩展启动于：\(stampFormatter.string(from: started))")
        } else {
            lines.append("扩展启动于：从未")
        }

        // A record left by the extension, so it goes quiet along with it. Kept for the same
        // reason as the line above.
        if let handoff = AppGroup.lastHandoff {
            let names = handoff.names.isEmpty ? "无" : handoff.names.joined(separator: ",")
            let failures = handoff.failures.isEmpty ? "" : "｜失败 \(handoff.failures.count) 个"
            lines.append("上次分享：\(stampFormatter.string(from: handoff.at)) \(names)\(failures)")
        } else {
            lines.append("上次分享：无")
        }

        // Whether the scene the app is running in was built by us or by SwiftUI. This is the
        // one fact that decides whether a handed-over URL can be received at all: the
        // document-open path delivers into `connectionOptions.urlContexts` on the scene, so
        // with no `SceneDelegate` of our own there is nothing to receive it and the app is
        // launched for a file it then never sees. Reporting the delegate's own class name
        // answers it directly, instead of inferring it from the absence of a log line.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let delegate = scene.delegate {
            lines.append("场景代理：\(type(of: delegate))")
        } else {
            lines.append("场景代理：无（场景未连接）")
        }

        // ---- 声明名 vs 运行时名：这条比对本身曾经是错的（2026-10-04 修）----
        //
        // 早先这里把「plist 里声明的类名」与 `"\(模块名).\(type(of: delegate))"` 相比。
        // 那是**两套不同规则**的名字，恒不相等：
        //   * `type(of:)` 走 Swift 反射，`String(describing:)` 拿到的是 **Objective-C 运行时名**，
        //     对 `PRODUCT_NAME = 3D-Views` 它是 `_D_Views`（ObjC 标识符不能以数字开头，补前缀）；
        //   * `Self.moduleName` 取的是 **Swift 模块名**，同一个 PRODUCT_NAME 下是 `3D_Views`
        //     （非标识符字符换成下划线）。
        // 于是诊断页永远打印「场景代理名：**不一致**」，无论 plist 写的是哪一个 —— 那是假警报，
        // 会把人引向一个不是阻塞点的键。更名成 `Views` 后两边恰好都是 `Views`，假警报自动消失，
        // 但比对逻辑本身仍然是拿两种名字在比，换个 PRODUCT_NAME 就会复发，所以这里改成
        // **两侧都用 ObjC 运行时名**。
        //
        // 声明名（plist 里那个字符串）按 ObjC 语义解析：`Views.SceneDelegate` 的模块段就是
        // ObjC 模块名。运行时名用 `NSStringFromClass`/`object_getClassName` 取真实注册名。
        //
        // 注意：即使这里显示「一致」，也**不代表导入能work** —— 实测过两版都收不到 URL
        // （见图 project.yml 里 UISceneDelegateClassName 的注释）。这一行只回答「plist 有没有
        // 指名一个真实存在的类」，不回答「这个键是不是阻塞点」。
        lines.append("模块名（Swift）：\(Self.moduleName)")
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let delegate = scene.delegate {
            // 真实的 ObjC 运行时名；`object_getClassName` 对桥接过的 delegate 实例最直接。
            let runtimeName = String(cString: object_getClassName(delegate))
            let declared = Bundle.main.object(
                forInfoDictionaryKey: "UIApplicationSceneManifest"
            ) as? [String: Any]
            let declaredName = ((declared?["UISceneConfigurations"] as? [String: Any])?[
                "UIWindowSceneSessionRoleApplication"
            ] as? [[String: Any]])?.first?["UISceneDelegateClassName"] as? String
            lines.append("声明名：\(declaredName ?? "未声明")｜运行时名：\(runtimeName)")
            if let declaredName {
                // 同时按两种写法判等：plist 写 Swift 模块名（Views.SceneDelegate）或
                // ObjC 名（_D_Views.SceneDelegate）都算命中，只要类真实存在。
                let swiftStyle = "\(Self.moduleName).\(runtimeName.split(separator: ".").last ?? "")"
                let objcStyle = runtimeName
                let matches = (declaredName == objcStyle) || (declaredName == swiftStyle)
                lines.append(
                    matches
                        ? "场景代理名：一致（plist 的 \(declaredName) 指向真实注册的 \(runtimeName)）"
                        : "场景代理名：**不一致**（plist 写的是 \(declaredName)，运行时注册的是 \(runtimeName)）"
                )
            }
        }

        return lines
    }

    /// 这个二进制编译成的 **Swift 模块名**，取自运行时而不是构建设置。
    ///
    /// 注意它与 **ObjC 运行时名不是一回事**：`PRODUCT_NAME` 为 `3D-Views` 时，Swift 模块名是
    /// `3D_Views`（非标识符字符换下划线），而 ObjC 名是 `_D_Views`（不能以数字开头，补前缀）。
    /// 早先诊断页把这两者放在一起比较，于是恒报「不一致」——详见调用处的注释。
    /// 更名成 `Views` 后两者恰好相同，但这个 helper 返回的**始终是 Swift 侧的名字**，
    /// 要 ObjC 名请用 `object_getClassName`。
    ///
    /// `String(reflecting:)` 作用于一个类型会给出完全限定名，所以第一个点之前就是模块名。
    /// `FileHistory` 正是本模块内的一个类型，这让它成为一个合法的取样对象。
    private static var moduleName: String {
        String(reflecting: FileHistory.self).split(separator: ".").first.map(String.init) ?? "?"
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
        lines.append("=== 3D Views 导入诊断 ===")
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

        // The App Group inbox first. Nothing embeds a share extension at the moment, so this
        // loop normally finds nothing — it is kept because the extension is a two-line
        // change away from coming back (see project.yml), and this is the half that picks up
        // after it. When it *is* live it is the route that asks nothing of the system: the
        // extension did the copy itself, and this just picks it up.
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

    /// 消费分享桥接留下的待导入文件。
    ///
    /// 扩展负责把临时文件复制进 App Group Inbox，主 App 在启动、回前台和激活阶段
    /// 调用本方法取走并导入到自己的沙盒；重复调用是幂等的。
    @discardableResult
    func consumePendingShareImportIfNeeded(reason: String) -> [RecentFile] {
        if let handoff = AppGroup.lastHandoff {
            let names = handoff.names.isEmpty ? "无" : handoff.names.joined(separator: "、")
            let failures = handoff.failures.isEmpty ? "无" : handoff.failures.joined(separator: "、")
            note("分享交接消费\(reason)：清单=\(names)｜失败=\(failures)｜收件箱待取=\(AppGroup.pendingFileCount())")
        } else {
            note("分享交接消费\(reason)：无交接清单｜收件箱待取=\(AppGroup.pendingFileCount())")
        }
        return importFromSandbox(reason: "分享交接\(reason)")
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
    /// There is still no `3dviews://` scheme to special-case: it existed only to serve
    /// `extensionContext.open`, which a share extension is not allowed to use.
    func handleIncomingURL(_ url: URL, source: String) {
        receiveExternalFile(at: url, source: source)
    }

    /// How many files the share extension has left waiting. Shown in `SettingsView`.
    ///
    /// The extension is embedded again, so this is a live reading rather than a
    /// formality: it is normally 0 because the app takes the files out on activation, and
    /// a number that stays above 0 after a share means the handover landed in the
    /// container but nothing consumed it. Read from the App Group rather than assumed,
    /// because the group container also survives an app update.
    func sharedInboxFileCount() -> Int {
        AppGroup.pendingFileCount()
    }

    /// Whether the installed bundle actually carries the share extension. Read from the
    /// built product rather than the source tree: a side-loaded build need not be the one
    /// in the repository, and a missing `.appex` changes what the failure means.
    ///
    /// Only ever shown, never acted on — no import path branches on this. With the
    /// extension removed from the bundle it should read `false`; `true` would mean the
    /// installed build is not the one this source tree describes.
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
