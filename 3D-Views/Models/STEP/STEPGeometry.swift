//
//  STEPGeometry.swift
//  3D-Views
//
//  Resolves STEP entities into concrete geometric primitives.
//

import Foundation
import SceneKit

/// Resolved geometric primitives extracted from a STEP model.
struct STEPGeometry {
    /// Tessellated surface meshes (already in model coordinates).
    var surfaceMeshes: [SCNGeometry] = []
    /// Polylines representing edges / curves.
    var edgePolylines: [[SCNVector3]] = []
    /// All standalone points (fallback / debug).
    var points: [SCNVector3] = []
    /// Bounding box.
    var boundingBox: (min: SCNVector3, max: SCNVector3)?
}

/// A resolver that walks the entity graph.
struct STEPResolver {
    let model: STEPModel

    // MARK: - Point / vector helpers

    func point(_ id: Int?) -> SCNVector3? {
        guard let e = model[id], e.type == "CARTESIAN_POINT",
              case .list(let coords) = e.arguments[safe: 1],
              coords.count == 3 else { return nil }
        let x = coords[safe: 0]?.doubleValue ?? 0
        let y = coords[safe: 1]?.doubleValue ?? 0
        let z = coords[safe: 2]?.doubleValue ?? 0
        return SCNVector3(x, y, z)
    }

    func direction(_ id: Int?) -> SCNVector3? {
        guard let e = model[id], e.type == "DIRECTION",
              case .list(let coords) = e.arguments[safe: 1],
              coords.count == 3 else { return nil }
        let x = coords[safe: 0]?.doubleValue ?? 0
        let y = coords[safe: 1]?.doubleValue ?? 0
        let z = coords[safe: 2]?.doubleValue ?? 0
        let v = SCNVector3(x, y, z)
        return v.normalized()
    }

    /// Position of an AXIS2_PLACEMENT_3D: returns (origin, axis, refDir).
    func axisPlacement(_ id: Int?) -> (origin: SCNVector3, axis: SCNVector3, refDir: SCNVector3)? {
        guard let e = model[id], e.type == "AXIS2_PLACEMENT_3D" else { return nil }
        let origin = point(e.arguments[safe: 1]?.referenceValue) ?? SCNVector3(0, 0, 0)
        let axis = direction(e.arguments[safe: 2]?.referenceValue) ?? SCNVector3(0, 0, 1)
        let refDir = direction(e.arguments[safe: 3]?.referenceValue) ?? SCNVector3(1, 0, 0)
        return (origin, axis.normalized(), refDir.normalized())
    }
}

extension STEPValue {
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    var referenceValue: Int? {
        switch self {
        case .reference(let i): return i
        default: return nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension SCNVector3 {
    func normalized() -> SCNVector3 {
        let len = sqrt(x*x + y*y + z*z)
        guard len > 1e-12 else { return self }
        return SCNVector3(x / Float(len), y / Float(len), z / Float(len))
    }
    static func - (l: SCNVector3, r: SCNVector3) -> SCNVector3 {
        SCNVector3(l.x - r.x, l.y - r.y, l.z - r.z)
    }
    static func + (l: SCNVector3, r: SCNVector3) -> SCNVector3 {
        SCNVector3(l.x + r.x, l.y + r.y, l.z + r.z)
    }
    static func * (l: SCNVector3, s: Float) -> SCNVector3 {
        SCNVector3(l.x * s, l.y * s, l.z * s)
    }
    func dot(_ r: SCNVector3) -> Float { x*r.x + y*r.y + z*r.z }
    func cross(_ r: SCNVector3) -> SCNVector3 {
        SCNVector3(y*r.z - z*r.y, z*r.x - x*r.z, x*r.y - y*r.x)
    }
    func length() -> Float { sqrt(x*x + y*y + z*z) }
}
