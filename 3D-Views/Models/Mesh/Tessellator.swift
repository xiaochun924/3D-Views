//
//  Tessellator.swift
//  3D-Views
//
//  Converts parsed STEP geometry into SceneKit meshes and edge lines.
//

import Foundation
import SceneKit
import CoreGraphics

enum Tessellator {

    static func build(_ model: STEPModel) -> STEPGeometry {
        let resolver = STEPResolver(model: model)
        var result = STEPGeometry()

        for entity in model.order.compactMap({ model.entities[$0] }) {
            guard let polyline = tessellateCurve(entity, resolver: resolver) else { continue }
            if polyline.count >= 2 {
                result.edgePolylines.append(polyline)
            }
        }

        for face in model.entities(ofType: "ADVANCED_FACE") {
            if let mesh = tessellatePlanarFace(face, resolver: resolver) {
                result.surfaceMeshes.append(mesh)
            }
        }

        for face in model.entities(ofType: "ADVANCED_FACE") {
            if let mesh = tessellateCylindricalFace(face, resolver: resolver) {
                result.surfaceMeshes.append(mesh)
            }
        }

        var allPoints: [SCNVector3] = []
        for p in result.edgePolylines { allPoints.append(contentsOf: p) }
        for m in result.surfaceMeshes {
            for source in m.sources {
                guard source.vectorCount > 0 else { continue }
                let stride = source.dataStride
                source.data.withUnsafeBytes { raw in
                    let ptr = raw.bindMemory(to: Float.self)
                    for i in 0..<source.vectorCount {
                        let base = i * stride / MemoryLayout<Float>.stride
                        allPoints.append(SCNVector3(ptr[base], ptr[base+1], ptr[base+2]))
                    }
                }
            }
        }
        result.points = allPoints

        if !allPoints.isEmpty {
            var minV = allPoints[0], maxV = allPoints[0]
            for p in allPoints {
                minV = SCNVector3(min(minV.x, p.x), min(minV.y, p.y), min(minV.z, p.z))
                maxV = SCNVector3(max(maxV.x, p.x), max(maxV.y, p.y), max(maxV.z, p.z))
            }
            result.boundingBox = (minV, maxV)
        }

        return result
    }

    // MARK: - Curves

    static func tessellateCurve(_ e: STEPEntity, resolver: STEPResolver) -> [SCNVector3]? {
        switch e.type {
        case "LINE":
            let p0 = resolver.point(e.arguments[safe: 1]?.referenceValue)
            let dir = resolver.direction(e.arguments[safe: 2]?.referenceValue)
            guard let p0, let dir else { return nil }
            return [p0, p0 + dir]

        case "CIRCLE":
            guard let placement = resolver.axisPlacement(e.arguments[safe: 1]?.referenceValue),
                  let r = e.arguments[safe: 2]?.doubleValue else { return nil }
            return circlePolyline(center: placement.origin,
                                  axis: placement.axis,
                                  refDir: placement.refDir,
                                  radius: CGFloat(r),
                                  segments: 64)

        case "ELLIPSE":
            guard let placement = resolver.axisPlacement(e.arguments[safe: 1]?.referenceValue),
                  let r1 = e.arguments[safe: 2]?.doubleValue,
                  let r2 = e.arguments[safe: 3]?.doubleValue else { return nil }
            return ellipsePolyline(center: placement.origin,
                                   axis: placement.axis,
                                   refDir: placement.refDir,
                                   r1: CGFloat(r1), r2: CGFloat(r2),
                                   segments: 64)

        case "B_SPLINE_CURVE", "B_SPLINE_CURVE_WITH_KNOTS":
            guard case .list(let ptsRefs) = e.arguments[safe: 3] ?? .list([]) else { return nil }
            var pts: [SCNVector3] = []
            for ref in ptsRefs {
                if let p = resolver.point(ref.referenceValue) { pts.append(p) }
            }
            return pts

        default:
            return nil
        }
    }

    private static func basisVectors(axis: SCNVector3, refDir: SCNVector3) -> (u: SCNVector3, v: SCNVector3) {
        let u = refDir
        let v = axis.cross(u).normalized()
        return (u, v)
    }

    private static func circlePolyline(center: SCNVector3, axis: SCNVector3,
                                       refDir: SCNVector3, radius: CGFloat, segments: Int) -> [SCNVector3] {
        let (u, v) = basisVectors(axis: axis, refDir: refDir)
        var pts: [SCNVector3] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments) * 2 * .pi
            let p = center + u * (Float(radius) * cos(t)) + v * (Float(radius) * sin(t))
            pts.append(p)
        }
        return pts
    }

    private static func ellipsePolyline(center: SCNVector3, axis: SCNVector3,
                                        refDir: SCNVector3, r1: CGFloat, r2: CGFloat, segments: Int) -> [SCNVector3] {
        let (u, v) = basisVectors(axis: axis, refDir: refDir)
        var pts: [SCNVector3] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments) * 2 * .pi
            let p = center + u * (Float(r1) * cos(t)) + v * (Float(r2) * sin(t))
            pts.append(p)
        }
        return pts
    }

    // MARK: - Planar faces

    static func tessellatePlanarFace(_ face: STEPEntity, resolver: STEPResolver) -> SCNGeometry? {
        guard face.type == "ADVANCED_FACE" else { return nil }
        guard case .list(let loopsRefs) = face.arguments[safe: 1] ?? .list([]),
              let surfaceRef = face.arguments[safe: 2]?.referenceValue,
              let surface = resolver.model[surfaceRef], surface.type == "PLANE" else {
            return nil
        }

        guard let placement = resolver.axisPlacement(surface.arguments[safe: 1]?.referenceValue) else {
            return nil
        }
        let normal = placement.axis
        let u = placement.refDir
        let v = normal.cross(u).normalized()
        let origin = placement.origin

        guard let firstLoopRef = loopsRefs.first?.referenceValue,
              let loop = resolver.model[firstLoopRef] else { return nil }
        guard case .list(let edgeRefs) = loop.arguments[safe: 1] ?? .list([]) else { return nil }

        var polygon: [SCNVector3] = []
        for edgeRef in edgeRefs {
            guard let edge = resolver.model[edgeRef.referenceValue],
                  edge.type == "EDGE_CURVE",
                  let curveRef = edge.arguments[safe: 3]?.referenceValue,
                  let curve = resolver.model[curveRef] else { continue }
            if let poly = tessellateCurve(curve, resolver: resolver) {
                polygon.append(contentsOf: poly)
            }
        }
        guard polygon.count >= 3 else { return nil }

        var cleaned: [SCNVector3] = []
        for p in polygon {
            if cleaned.last == nil || (cleaned.last! - p).length() > 1e-6 {
                cleaned.append(p)
            }
        }
        guard cleaned.count >= 3 else { return nil }

        let pts2D = cleaned.map { p -> CGPoint in
            let rel = p - origin
            return CGPoint(x: CGFloat(rel.dot(u)), y: CGFloat(rel.dot(v)))
        }
        guard let triangles = earClip(pts2D) else { return nil }

        let vertices = cleaned.map { SCNVector3($0.x, $0.y, $0.z) }
        let source = SCNGeometrySource(vertices: vertices)
        var indices: [Int32] = []
        for tri in triangles {
            indices.append(Int32(tri.a))
            indices.append(Int32(tri.b))
            indices.append(Int32(tri.c))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        geo.materials = [mat]
        return geo
    }

    // MARK: - Cylindrical faces

    static func tessellateCylindricalFace(_ face: STEPEntity, resolver: STEPResolver) -> SCNGeometry? {
        guard case .list(let loopsRefs) = face.arguments[safe: 1] ?? .list([]),
              let surfaceRef = face.arguments[safe: 2]?.referenceValue,
              let surface = resolver.model[surfaceRef],
              surface.type == "CYLINDRICAL_SURFACE",
              let radius = surface.arguments[safe: 2]?.doubleValue,
              let placement = resolver.axisPlacement(surface.arguments[safe: 1]?.referenceValue)
        else { return nil }

        var circles: [(center: SCNVector3, points: [SCNVector3])] = []
        for loopRef in loopsRefs {
            guard let loop = resolver.model[loopRef.referenceValue],
                  case .list(let edgeRefs) = loop.arguments[safe: 1] ?? .list([]) else { continue }
            for edgeRef in edgeRefs {
                guard let edge = resolver.model[edgeRef.referenceValue],
                      edge.type == "EDGE_CURVE",
                      let curveRef = edge.arguments[safe: 3]?.referenceValue,
                      let curve = resolver.model[curveRef],
                      curve.type == "CIRCLE",
                      let poly = tessellateCurve(curve, resolver: resolver)
                else { continue }
                let sum = poly.reduce(SCNVector3(0,0,0), +)
                let c = SCNVector3(sum.x / Float(poly.count),
                                   sum.y / Float(poly.count),
                                   sum.z / Float(poly.count))
                circles.append((c, poly))
            }
        }
        guard circles.count >= 1 else { return nil }

        let axis = placement.axis
        let refDir = placement.refDir
        let (u, v) = basisVectors(axis: axis, refDir: refDir)

        circles.sort { $0.center.dot(axis) < $1.center.dot(axis) }

        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        let segments = 48

        func ring(at center: SCNVector3) -> [SCNVector3] {
            (0...segments).map { i in
                let t = Float(i) / Float(segments) * 2 * .pi
                return center + u * (Float(radius) * cos(t)) + v * (Float(radius) * sin(t))
            }
        }

        if circles.count == 1 {
            let c = circles[0].center
            let r1 = ring(at: c)
            let r2 = ring(at: c + axis * 1.0)
            let base = vertices.count
            vertices.append(contentsOf: r1)
            vertices.append(contentsOf: r2)
            for i in 0..<segments {
                indices.append(contentsOf: [
                    Int32(base + i), Int32(base + i + 1), Int32(base + segments + 1 + i),
                    Int32(base + i), Int32(base + segments + 1 + i), Int32(base + segments + i)
                ])
            }
        } else {
            for k in 0..<(circles.count - 1) {
                let r1 = ring(at: circles[k].center)
                let r2 = ring(at: circles[k+1].center)
                let base = vertices.count
                vertices.append(contentsOf: r1)
                vertices.append(contentsOf: r2)
                for i in 0..<segments {
                    indices.append(contentsOf: [
                        Int32(base + i), Int32(base + i + 1), Int32(base + segments + 1 + i),
                        Int32(base + i), Int32(base + segments + 1 + i), Int32(base + segments + i)
                    ])
                }
            }
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.65, green: 0.75, blue: 0.88, alpha: 1.0)
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        geo.materials = [mat]
        return geo
    }

    // MARK: - Ear clipping (2D)

    struct Tri { let a, b, c: Int }

    static func earClip(_ polygon: [CGPoint]) -> [Tri]? {
        guard polygon.count >= 3 else { return nil }
        var remaining = Array(0..<polygon.count)
        var tris: [Tri] = []
        var guardIterations = 0
        while remaining.count > 3 && guardIterations < 10000 {
            guardIterations += 1
            var found = false
            for i in 0..<remaining.count {
                let i0 = remaining[(i - 1 + remaining.count) % remaining.count]
                let i1 = remaining[i]
                let i2 = remaining[(i + 1) % remaining.count]
                let a = polygon[i0], b = polygon[i1], c = polygon[i2]
                if cross2D(a, b, c) <= 0 { continue }
                var hasInside = false
                for j in remaining {
                    if j == i0 || j == i1 || j == i2 { continue }
                    if pointInTriangle(polygon[j], a, b, c) { hasInside = true; break }
                }
                if !hasInside {
                    tris.append(Tri(a: i0, b: i1, c: i2))
                    remaining.remove(at: i)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        if remaining.count == 3 {
            tris.append(Tri(a: remaining[0], b: remaining[1], c: remaining[2]))
        }
        return tris
    }

    private static func cross2D(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private static func pointInTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        let c1 = cross2D(a, b, p), c2 = cross2D(b, c, p), c3 = cross2D(c, a, p)
        return c1 >= 0 && c2 >= 0 && c3 >= 0
    }
}
