//
//  STLParser.swift
//  3D-Views
//
//  Parses ASCII STL files into a mesh. Binary STL is also supported.
//

import Foundation
import SceneKit

enum STLParser {

    /// Parse an STL file (ASCII or binary). Returns SceneKit geometry.
    static func parse(data: Data) -> SCNGeometry? {
        if let ascii = String(data: data, encoding: .ascii),
           ascii.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("solid") {
            return parseASCII(ascii)
        }
        return parseBinary(data)
    }

    private static func parseASCII(_ text: String) -> SCNGeometry? {
        var vertices: [SCNVector3] = []
        var currentVerts: [SCNVector3] = []

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard let keyword = parts.first?.lowercased() else { continue }
            switch keyword {
            case "facet":
                currentVerts = []
            case "vertex":
                if parts.count >= 4, let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    currentVerts.append(SCNVector3(x, y, z))
                }
            case "endfacet":
                if currentVerts.count == 3 {
                    vertices.append(contentsOf: currentVerts)
                }
                currentVerts = []
            default:
                break
            }
        }
        guard !vertices.isEmpty else { return nil }
        return buildGeometry(vertices: vertices)
    }

    private static func parseBinary(_ data: Data) -> SCNGeometry? {
        guard data.count >= 84 else { return nil }
        let triangleCount = data.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self) }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(Int(triangleCount) * 3)

        var offset = 84
        for _ in 0..<triangleCount {
            guard offset + 50 <= data.count else { break }
            let v1x = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: Float.self) }
            let v1y = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 16, as: Float.self) }
            let v1z = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: Float.self) }
            let v2x = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 24, as: Float.self) }
            let v2y = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 28, as: Float.self) }
            let v2z = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 32, as: Float.self) }
            let v3x = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 36, as: Float.self) }
            let v3y = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 40, as: Float.self) }
            let v3z = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 44, as: Float.self) }
            vertices.append(SCNVector3(v1x, v1y, v1z))
            vertices.append(SCNVector3(v2x, v2y, v2z))
            vertices.append(SCNVector3(v3x, v3y, v3z))
            offset += 50
        }
        guard !vertices.isEmpty else { return nil }
        return buildGeometry(vertices: vertices)
    }

    private static func buildGeometry(vertices: [SCNVector3]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices)
        var indices: [Int32] = []
        for i in 0..<(vertices.count / 3) {
            indices.append(Int32(i * 3))
            indices.append(Int32(i * 3 + 1))
            indices.append(Int32(i * 3 + 2))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.72, green: 0.80, blue: 0.92, alpha: 1.0)
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        geo.materials = [mat]
        return geo
    }
}
