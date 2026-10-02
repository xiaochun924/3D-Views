import Foundation

internal struct SLDPRTConversionResult: Sendable {
    internal let stepURL: URL
    internal let warnings: [String]
    internal let solids: Int
    internal let faces: Int
    internal let bodies: [String]
    internal let containerFormat: String
    internal let modellerVersion: Int
}

internal enum SLDPRTConverter {
    private static func bodies(in xt: XTFile) -> [XTNode] {
        guard let root = xt.get(xt.rootIndex) else { return [] }
        switch root.type {
        case 101:
            return xt.chain(xt.deref(root, "body"), "next")
        case 12:
            return [root]
        case 74, 176:
            return (root.f["entries"]?.intsValue ?? []).compactMap { xt.get($0) }.filter { $0.type == 12 }
        default:
            return []
        }
    }

    private static func faceCount(_ xt: XTFile, _ body: XTNode) -> Int {
        var count = 0
        for region in xt.chain(xt.deref(body, "region"), "next") {
            for shell in xt.chain(xt.deref(region, "shell"), "next") {
                count += xt.chain(xt.deref(shell, "face"), "next").count
                count += xt.chain(xt.deref(shell, "front_face"), "next_front").count
            }
        }
        return count
    }

    internal static func convert(data: Data, fileName: String) throws -> SLDPRTConversionResult {
        guard let extraction = slExtractTransmits(Array(data)) else {
            throw SLDPRTConvertError(code: "no_parasolid_geometry", message: "no Parasolid transmit found in the SolidWorks part")
        }

        var warnings: [String] = []
        var best: (faces: Int, xt: XTFile, bodies: [XTNode])?
        for transmit in extraction.partitions() {
            guard let xt = try? readXT(transmit.data) else { continue }
            let currentBodies = bodies(in: xt)
            let count = currentBodies.reduce(0) { $0 + faceCount(xt, $1) }
            if best == nil || count > best!.faces {
                best = (count, xt, currentBodies)
            }
        }

        var chosen: [(XTFile, XTNode, String)] = []
        var modellerVersion = 0
        if let selected = best, selected.faces > 0 {
            let solidBodies = selected.bodies.filter { $0.f["body_type"]?.intValue == 1 }
            guard !solidBodies.isEmpty else {
                throw SLDPRTConvertError(code: "empty_step", message: "the live partition contains no solid bodies")
            }
            modellerVersion = selected.xt.modellerVersion
            for (index, body) in solidBodies.enumerated() {
                chosen.append((selected.xt, body, solidBodies.count == 1 ? "Body" : "Body\(index + 1)"))
            }
        } else {
            for transmit in extraction.parts() {
                guard let xt = try? readXT(transmit.data) else { continue }
                for body in bodies(in: xt) where body.f["body_type"]?.intValue == 1 && faceCount(xt, body) > 0 {
                    chosen.append((xt, body, transmit.name.isEmpty ? "Body\(chosen.count + 1)" : transmit.name))
                    modellerVersion = modellerVersion == 0 ? xt.modellerVersion : modellerVersion
                }
            }
            guard !chosen.isEmpty else {
                throw SLDPRTConvertError(code: "empty_step", message: "no solid body with faces was found")
            }
            warnings.append("imported_bodies: live partition is empty; feature bodies were used")
        }

        let mapped = try slWriteStep(chosen, fileName, &warnings)
        guard mapped.solids > 0, (mapped.text.contains("MANIFOLD_SOLID_BREP") || mapped.text.contains("BREP_WITH_VOIDS")) else {
            throw SLDPRTConvertError(code: "empty_step", message: "conversion produced no solid body")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sldprt-\(UUID().uuidString)")
            .appendingPathExtension("step")
        try mapped.text.write(to: url, atomically: true, encoding: .utf8)
        return SLDPRTConversionResult(stepURL: url, warnings: warnings, solids: mapped.solids, faces: mapped.faces, bodies: chosen.map { $0.2 }, containerFormat: extraction.format, modellerVersion: modellerVersion)
    }

    internal static func convert(url: URL) throws -> SLDPRTConversionResult {
        try convert(data: Data(contentsOf: url), fileName: url.lastPathComponent)
    }
}
