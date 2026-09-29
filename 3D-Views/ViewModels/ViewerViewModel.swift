//
//  ViewerViewModel.swift
//  3D-Views
//

import Foundation
import SceneKit
import SwiftUI
import simd
import OCCTSwift

enum InteractionMode: Equatable {
    case orbit
    case measure
}

enum SnapKind: String {
    case endpoint = "端点"
    case midpoint = "中点"
    case center = "圆心"
    case quadrant = "象限点"
    case face = "面"
    case none = ""

    /// Disambiguation priority: vertices win over edge-derived points, which win over
    /// a bare surface hit. Mirrors the "prefer edges over surfaces, then nearest of the
    /// same type" rule used by production CAD snapping engines.
    var priority: Int {
        switch self {
        case .endpoint, .center, .quadrant: return 0
        case .midpoint: return 1
        case .face: return 2
        case .none: return 3
        }
    }
}

struct SnapPoint {
    let position: SCNVector3
    let kind: SnapKind
}

/// Standard orthographic viewing directions offered by the 「视图」 control.
enum ViewDirection: String, CaseIterable, Identifiable {
    case front = "前视图"
    case back = "后视图"
    case left = "左视图"
    case right = "右视图"
    case top = "俯视图"
    case bottom = "仰视图"
    case iso = "等轴测"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .front, .back: return "rectangle"
        case .left, .right: return "rectangle.portrait"
        case .top, .bottom: return "rectangle.portrait.rotate"
        case .iso: return "cube"
        }
    }
}

enum MeasureType: String, CaseIterable, Identifiable {
    case distance
    case angle
    case radius
    case linear

    var id: String { rawValue }
    var label: String {
        switch self {
        case .distance: return "距离"
        case .angle: return "角度"
        case .radius: return "半径"
        case .linear: return "线性测量"
        }
    }
    var icon: String {
        switch self {
        case .distance: return "ruler"
        case .angle: return "angle"
        case .radius: return "clockwise"
        case .linear: return "move.3d"
        }
    }
    var requiredPoints: Int {
        switch self {
        case .distance, .linear: return 2
        case .angle, .radius: return 3
        }
    }
}

@MainActor
final class ViewerViewModel: ObservableObject {

    @Published var fileName: String = ""
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var scene: SCNScene?
    @Published var mode: InteractionMode = .orbit
    @Published var measureType: MeasureType = .distance
    @Published var displayUnit: DisplayUnit = .millimeter
    @Published var pickedPoints: [SCNVector3] = []
    @Published var pickedKinds: [SnapKind] = []

    @Published var distanceResult: Float?
    @Published var angleResult: Float?
    @Published var radiusResult: Float?
    @Published var radiusCenter: SCNVector3?

    private var measureGroup: SCNNode?
    private var modelNode: SCNNode?
    private var snapPoints: [SnapPoint] = []

    /// Set by `SceneView` once the renderer exists. Only used for screen-space sizing
    /// of annotations and for hit-testing; deliberately not `@Published`, so attaching
    /// it never triggers a view update.
    weak var renderView: SCNView?

    func attach(view: SCNView) {
        renderView = view
    }

    /// Screen-space snap radius, in points. Replaces the old world-space threshold
    /// (`max(maxDim, 10) * 0.04`), which made snapping depend on zoom level instead of
    /// on the finger. 14 pt is a comfortable touch target on iPhone and iPad alike.
    private let snapScreenRadius: CGFloat = 14

    /// Largest model dimension, cached for fallbacks and for camera framing.
    private var modelDim: Float = 10

    /// Distance at which the camera frames the model.
    private var cameraDistance: Float = 24

    init() {
        if let raw = UserDefaults.standard.string(forKey: "defaultUnit"),
           let unit = DisplayUnit(rawValue: raw) {
            displayUnit = unit
        }
    }

    var isComplete: Bool {
        pickedPoints.count == measureType.requiredPoints
    }

    // MARK: - Load

    func loadFile(url: URL) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let ext = url.pathExtension.lowercased()
        guard ext == "step" || ext == "stp" || ext == "stl" else {
            loadError = "不支持的文件格式。"
            return
        }

        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let geometry: SCNGeometry
            var shape: OCCTSwift.Shape?

            if ext == "step" || ext == "stp" {
                let loaded = try OCCTSwift.Shape.loadSTEP(from: url)
                shape = loaded
                guard let mesh = loaded.mesh(linearDeflection: 0.1, angularDeflection: 0.2) else {
                    loadError = "STEP 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
            } else {
                guard let loaded = OCCTSwift.Shape.readSTL(from: url.path) else {
                    loadError = "STL 文件读取失败。"
                    return
                }
                shape = loaded
                guard let mesh = loaded.mesh(linearDeflection: 0.1) else {
                    loadError = "STL 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
            }

            let (bbMin, bbMax) = geometry.boundingBox
            let sizeX = bbMax.x - bbMin.x
            let sizeY = bbMax.y - bbMin.y
            let sizeZ = bbMax.z - bbMin.z
            let maxDim = max(max(sizeX, sizeY), sizeZ)
            modelDim = max(maxDim, 1)
            cameraDistance = modelDim * 2.4

            let center = SCNVector3(
                (bbMin.x + bbMax.x) / 2,
                (bbMin.y + bbMax.y) / 2,
                (bbMin.z + bbMax.z) / 2
            )

            // Real B-rep edge polylines. Previously the app duplicated the *triangle*
            // mesh and rendered it with `fillMode = .lines`, which draws every
            // tessellation triangle edge (thousands of hairlines) rather than the
            // model's actual edges — the main cause of the "unclear model" report.
            //
            // Only drewable for BREP formats: an STL has no genuine edge structure, so
            // its edge set is just every facet boundary — the same noise again.
            let isBrep = (ext == "step" || ext == "stp")
            let edgeGeometry = isBrep
                ? shape.flatMap { $0.edgeMesh(deflection: 0.1) }
                       .flatMap { Self.makeEdgeGeometry(from: $0) }
                : nil

            let built = Self.buildScene(
                geometry: geometry,
                edgeGeometry: edgeGeometry,
                center: center,
                cameraDistance: cameraDistance
            )
            scene = built
            fileName = url.lastPathComponent

            let mNode = built.rootNode.childNode(withName: "model", recursively: true)
            modelNode = mNode

            if let mNode {
                snapPoints = buildSnapDatabase(shape: shape, geometry: geometry, modelNode: mNode)
            } else {
                snapPoints = []
            }

            clearMeasure()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Edge geometry

    /// Builds a single line-primitive geometry from the kernel's edge polylines.
    private static func makeEdgeGeometry(from data: OCCTSwift.EdgeMeshData) -> SCNGeometry? {
        let verts = data.vertices
        guard verts.count >= 2 else { return nil }

        var indices: [UInt32] = []
        indices.reserveCapacity(verts.count * 2)

        let starts = data.segmentStarts
        for i in 0..<starts.count {
            let start = starts[i]
            // `segmentStarts` carries a trailing sentinel equal to `vertices.count`
            // in some versions; treating the last entry as an empty range makes both
            // layouts safe.
            let end = (i + 1 < starts.count) ? starts[i + 1] : verts.count
            guard start >= 0, end <= verts.count, end - start >= 2 else { continue }
            for k in start..<(end - 1) {
                indices.append(UInt32(k))
                indices.append(UInt32(k + 1))
            }
        }

        guard indices.count >= 2 else { return nil }

        let source = SCNGeometrySource(vertices: verts.map {
            SCNVector3($0.x, $0.y, $0.z)
        })
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [source], elements: [element])
    }

    // MARK: - Snap Database

    private func buildSnapDatabase(shape: OCCTSwift.Shape?,
                                   geometry: SCNGeometry,
                                   modelNode: SCNNode) -> [SnapPoint] {
        let toWorld: (SIMD3<Double>) -> SCNVector3 = { local in
            modelNode.convertPosition(
                SCNVector3(Float(local.x), Float(local.y), Float(local.z)), to: nil)
        }

        var result: [SnapPoint] = []

        guard let shape else {
            // STL fallback: the mesh has no B-rep topology, so the vertices are the
            // only meaningful snap candidates.
            return Self.extractVertices(from: geometry).map {
                SnapPoint(position: modelNode.convertPosition($0, to: nil), kind: .endpoint)
            }
        }

        var seen = Set<SIMD3<Int64>>()
        for v in shape.vertices() {
            let key = quantize(v)
            if seen.insert(key).inserted {
                result.append(SnapPoint(position: toWorld(v), kind: .endpoint))
            }
        }

        let edgePolys = shape.allEdgePolylinesIndexed(deflection: 0.1, maxPointsPerEdge: 500)
        for (_, pts) in edgePolys {
            guard pts.count >= 2 else { continue }

            if let circle = detectCircle(pts) {
                result.append(SnapPoint(position: toWorld(circle.center), kind: .center))

                let refDir = simd_normalize(pts[0] - circle.center)
                let perpDir = simd_cross(circle.normal, refDir)
                for d in [refDir, perpDir, -refDir, -perpDir] {
                    result.append(SnapPoint(position: toWorld(circle.center + circle.radius * d),
                                            kind: .quadrant))
                }
            } else {
                let mid = pts[pts.count / 2]
                result.append(SnapPoint(position: toWorld(mid), kind: .midpoint))
            }
        }

        return result
    }

    private struct CircleInfo {
        let center: SIMD3<Double>
        let radius: Double
        let normal: SIMD3<Double>
    }

    private func detectCircle(_ pts: [SIMD3<Double>]) -> CircleInfo? {
        let n = pts.count
        guard n >= 3 else { return nil }

        let p1 = pts[0]
        let p2 = pts[min(n / 3, n - 1)]
        let p3 = pts[min(2 * n / 3, n - 1)]

        let u = p2 - p1
        let v = p3 - p1
        let normalRaw = simd_cross(u, v)
        let normalLen = simd_length(normalRaw)
        guard normalLen > 1e-8 else { return nil }
        let normal = normalRaw / normalLen

        let uu = simd_dot(u, u)
        let vv = simd_dot(v, v)
        let uv = simd_dot(u, v)
        let det = uu * vv - uv * uv
        guard abs(det) > 1e-8 else { return nil }

        let a = (uu / 2 * vv - vv / 2 * uv) / det
        let b = (uu * vv / 2 - uv * uu / 2) / det
        let center = p1 + a * u + b * v
        let radius = simd_length(p1 - center)
        guard radius > 1e-6 else { return nil }

        let tol = radius * 0.03
        for p in pts {
            let r = simd_length(p - center)
            if abs(r - radius) > tol { return nil }
            let dist = simd_dot(p - center, normal)
            if abs(dist) > radius * 0.02 { return nil }
        }
        return CircleInfo(center: center, radius: radius, normal: normal)
    }

    private func quantize(_ p: SIMD3<Double>) -> SIMD3<Int64> {
        let scale = 1000.0
        return SIMD3(Int64((p.x * scale).rounded()),
                     Int64((p.y * scale).rounded()),
                     Int64((p.z * scale).rounded()))
    }

    static func extractVertices(from geometry: SCNGeometry) -> [SCNVector3] {
        guard let source = geometry.sources(for: .vertex).first else { return [] }
        let stride = source.dataStride
        let offset = source.dataOffset
        let bytesPerComponent = source.bytesPerComponent
        let vectorCount = source.vectorCount
        let data = source.data

        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(vectorCount)

        data.withUnsafeBytes { rawPtr in
            for i in 0..<vectorCount {
                let start = i * stride + offset
                let x = rawPtr.load(fromByteOffset: start, as: Float.self)
                let y = rawPtr.load(fromByteOffset: start + bytesPerComponent, as: Float.self)
                let z = rawPtr.load(fromByteOffset: start + 2 * bytesPerComponent, as: Float.self)
                vertices.append(SCNVector3(x, y, z))
            }
        }
        return vertices
    }

    // MARK: - Scene

    static func buildScene(geometry: SCNGeometry,
                           edgeGeometry: SCNGeometry?,
                           center: SCNVector3,
                           cameraDistance: Float) -> SCNScene {
        let scene = SCNScene()

        // A neutral machined-steel grey reads far better against the light backdrop
        // than the previous mid-green, which sat at almost the same luminance as the
        // background and flattened facet-to-facet shading differences.
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.35, alpha: 1.0)
        mat.shininess = 0.18
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        geometry.materials = [mat]

        // The kernel returns geometry in its own arbitrary coordinate frame, so a
        // container node carries the recentring offset. An explicit child `position`
        // is used rather than `SCNNode.pivot`, whose sign convention is easy to get
        // backwards and which would silently mirror the model instead of centring it.
        let modelRoot = SCNNode()
        modelRoot.name = "modelRoot"
        modelRoot.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(modelRoot)

        let modelNode = SCNNode(geometry: geometry)
        modelNode.name = "model"
        modelRoot.addChildNode(modelNode)

        if let edgeGeometry {
            let edgeMat = SCNMaterial()
            edgeMat.diffuse.contents = UIColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1.0)
            edgeMat.lightingModel = .constant
            edgeMat.isDoubleSided = true
            // Depth-tested against the shaded surface so hidden edges stay hidden,
            // but not depth-writing, which removes the stipple that a coplanar
            // overlay otherwise produces.
            edgeMat.readsFromDepthBuffer = true
            edgeMat.writesToDepthBuffer = false
            edgeGeometry.materials = [edgeMat]

            // A hair of outward inflation keeps the wireframe off the shaded surface
            // in the depth buffer. It is applied through an explicit anchor pair rather
            // than `SCNNode.pivot` so the expansion is provably about the model centre:
            // v -> center + 1.0015 * (v - center).
            let edgeAnchor = SCNNode()
            edgeAnchor.name = "edgeAnchor"
            edgeAnchor.position = center
            edgeAnchor.scale = SCNVector3(1.0015, 1.0015, 1.0015)

            let edgeNode = SCNNode(geometry: edgeGeometry)
            edgeNode.name = "edges"
            edgeNode.position = SCNVector3(-center.x, -center.y, -center.z)
            edgeAnchor.addChildNode(edgeNode)
            modelNode.addChildNode(edgeAnchor)
        }

        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.automaticallyAdjustsZRange = false
        camera.zNear = Double(max(cameraDistance * 0.01, 0.01))
        camera.zFar = Double(cameraDistance * 12)
        camera.wantsHDR = false
        camera.bloomIntensity = 0

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, cameraDistance * 0.32, cameraDistance)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Three lights instead of four: a key, a fill and low ambient. The removed
        // back light contributed little and cost a full extra shading pass.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1100
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(cameraDistance * 0.6, cameraDistance, cameraDistance * 0.6)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 450
        fillLight.color = UIColor(white: 0.85, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-cameraDistance * 0.7, cameraDistance * 0.25, cameraDistance * 0.5)
        fillNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 320
        ambient.color = UIColor(white: 0.78, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Camera control

    /// The camera actually being rendered through.
    ///
    /// Deliberately not `childNode(withName: "camera")`: with
    /// `allowsCameraControl` enabled SceneKit may install its own camera and assign
    /// it to the view's `pointOfView`, in which case moving a named node would have
    /// no visible effect. Commanding the live `pointOfView` works either way.
    private var cameraNode: SCNNode? {
        renderView?.pointOfView
            ?? scene?.rootNode.childNode(withName: "camera", recursively: true)
    }

    func resetView() {
        guard let camNode = cameraNode else { return }
        camNode.position = SCNVector3(0, cameraDistance * 0.32, cameraDistance)
        camNode.look(at: SCNVector3(0, 0, 0))
    }

    func setViewDirection(_ direction: ViewDirection) {
        guard let camNode = cameraNode else { return }
        let r = cameraDistance
        let target = SCNVector3(0, 0, 0)

        switch direction {
        case .front:
            camNode.position = SCNVector3(0, 0, r)
            camNode.look(at: target)
        case .back:
            camNode.position = SCNVector3(0, 0, -r)
            camNode.look(at: target)
        case .left:
            camNode.position = SCNVector3(-r, 0, 0)
            camNode.look(at: target)
        case .right:
            camNode.position = SCNVector3(r, 0, 0)
            camNode.look(at: target)
        case .top:
            camNode.position = SCNVector3(0, r, 0)
            // Straight down: the default up vector is parallel to the view direction,
            // so supply an explicit up in the model's -Z.
            camNode.look(at: target, up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        case .bottom:
            camNode.position = SCNVector3(0, -r, 0)
            camNode.look(at: target, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        case .iso:
            camNode.position = SCNVector3(r * 0.58, r * 0.52, r * 0.62)
            camNode.look(at: target)
        }
    }

    // MARK: - Measure

    /// World units that one screen point spans at the given world position.
    ///
    /// Calibrated by projecting a known world offset perpendicular to the view, so it
    /// is exact for perspective and orthographic cameras alike and needs no assumption
    /// about the camera's field-of-view axis.
    private func unitsPerPoint(at anchor: SCNVector3, in view: SCNView) -> CGFloat {
        let fallback = CGFloat(modelDim) * 0.003
        guard let pov = view.pointOfView else { return fallback }

        let m = pov.simdWorldTransform
        var right = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let len = simd_length(right)
        guard len > 1e-6 else { return fallback }
        right /= len

        let probe = max(modelDim, 1) * 0.02
        let a = view.projectPoint(anchor)
        let b = view.projectPoint(SCNVector3(anchor.x + right.x * probe,
                                             anchor.y + right.y * probe,
                                             anchor.z + right.z * probe))
        let dx = CGFloat(b.x - a.x)
        let dy = CGFloat(b.y - a.y)
        let screenLen = (dx * dx + dy * dy).squareRoot()
        guard screenLen > 0.01 else { return fallback }
        return CGFloat(probe) / screenLen
    }

    /// Convenience entry point used by `SceneView`, which has already attached itself
    /// through `attach(view:)`.
    func handleTap(screenPoint: CGPoint) {
        guard let view = renderView else { return }
        handleTap(screenPoint: screenPoint, in: view)
    }

    func handleTap(screenPoint: CGPoint, in view: SCNView) {
        guard mode == .measure else { return }
        guard let (snapped, kind) = snap(screenPoint: screenPoint, in: view) else { return }

        if pickedPoints.count >= measureType.requiredPoints {
            pickedPoints = [snapped]
            pickedKinds = [kind]
        } else {
            pickedPoints.append(snapped)
            pickedKinds.append(kind)
        }

        computeResults()
        updateMeasureVisuals(in: view)
    }

    /// Screen-space snapping.
    ///
    /// Every candidate is projected to the viewport and compared in 2D points, so the
    /// effective tolerance is constant on screen at any zoom level. Candidates hidden
    /// behind the front-most surface under the tap are rejected.
    private func snap(screenPoint: CGPoint, in view: SCNView) -> (SCNVector3, SnapKind)? {
        let modelHits = view.hitTest(screenPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ]).filter { $0.node === modelNode }

        let cameraPosition = view.pointOfView?.worldPosition
        var frontWorld: SCNVector3?
        var frontDistance = Float.greatestFiniteMagnitude
        if let cameraPosition {
            for hit in modelHits {
                let d = Self.distance(cameraPosition, hit.worldCoordinates)
                if d < frontDistance {
                    frontDistance = d
                    frontWorld = hit.worldCoordinates
                }
            }
        }

        let occlusionTolerance = max(modelDim, 1) * 0.004
        var bestKind: SnapKind?
        var bestPoint: SCNVector3?
        var bestScreenDistance = CGFloat.greatestFiniteMagnitude
        var bestPriority = Int.max

        for candidate in snapPoints {
            let projected = view.projectPoint(candidate.position)
            guard projected.z >= 0, projected.z <= 1 else { continue }

            let dx = CGFloat(projected.x) - screenPoint.x
            let dy = CGFloat(projected.y) - screenPoint.y
            let screenDistance = (dx * dx + dy * dy).squareRoot()
            guard screenDistance <= snapScreenRadius else { continue }

            if let cameraPosition, frontWorld != nil {
                let d = Self.distance(cameraPosition, candidate.position)
                if d - frontDistance > occlusionTolerance { continue }
            }

            let priority = candidate.kind.priority
            if priority < bestPriority ||
                (priority == bestPriority && screenDistance < bestScreenDistance) {
                bestPriority = priority
                bestScreenDistance = screenDistance
                bestKind = candidate.kind
                bestPoint = candidate.position
            }
        }

        if let bestPoint, let bestKind {
            return (bestPoint, bestKind)
        }

        // Nothing close enough: fall back to the surface directly under the tap. Tapping
        // empty space is ignored rather than adding a stray point.
        if let frontWorld {
            return (frontWorld, .face)
        }
        return nil
    }

    private static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func computeResults() {
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil

        guard pickedPoints.count == measureType.requiredPoints else { return }

        switch measureType {
        case .distance, .linear:
            let a = pickedPoints[0], b = pickedPoints[1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            distanceResult = (dx*dx + dy*dy + dz*dz).squareRoot()

        case .angle:
            let v1 = SCNVector3(pickedPoints[0].x - pickedPoints[1].x,
                                 pickedPoints[0].y - pickedPoints[1].y,
                                 pickedPoints[0].z - pickedPoints[1].z)
            let v2 = SCNVector3(pickedPoints[2].x - pickedPoints[1].x,
                                 pickedPoints[2].y - pickedPoints[1].y,
                                 pickedPoints[2].z - pickedPoints[1].z)
            let dot = v1.x*v2.x + v1.y*v2.y + v1.z*v2.z
            let m1 = (v1.x*v1.x + v1.y*v1.y + v1.z*v1.z).squareRoot()
            let m2 = (v2.x*v2.x + v2.y*v2.y + v2.z*v2.z).squareRoot()
            guard m1 > 1e-6, m2 > 1e-6 else { return }
            let cosAngle = max(-1, min(1, dot / (m1 * m2)))
            angleResult = acos(cosAngle) * 180 / Float.pi

        case .radius:
            if let (center, radius) = Self.circumcircle(
                pickedPoints[0], pickedPoints[1], pickedPoints[2]
            ) {
                radiusCenter = center
                radiusResult = radius
            }
        }
    }

    static func circumcircle(_ p1: SCNVector3, _ p2: SCNVector3, _ p3: SCNVector3)
        -> (SCNVector3, Float)? {
        let u = SCNVector3(p2.x-p1.x, p2.y-p1.y, p2.z-p1.z)
        let v = SCNVector3(p3.x-p1.x, p3.y-p1.y, p3.z-p1.z)

        let uu = u.x*u.x + u.y*u.y + u.z*u.z
        let vv = v.x*v.x + v.y*v.y + v.z*v.z
        let uv = u.x*v.x + u.y*v.y + u.z*v.z

        let det = uu * vv - uv * uv
        guard abs(det) > 1e-8 else { return nil }

        let a = (uu/2 * vv - vv/2 * uv) / det
        let b = (uu * vv/2 - uv * uu/2) / det

        let cx = p1.x + a*u.x + b*v.x
        let cy = p1.y + a*u.y + b*v.y
        let cz = p1.z + a*u.z + b*v.z
        let center = SCNVector3(cx, cy, cz)

        let dx = cx - p1.x, dy = cy - p1.y, dz = cz - p1.z
        let radius = (dx*dx + dy*dy + dz*dz).squareRoot()
        return (center, radius)
    }

    /// Removes the most recently picked point and recomputes.
    func undoLastPoint() {
        guard !pickedPoints.isEmpty else { return }
        pickedPoints.removeLast()
        if !pickedKinds.isEmpty { pickedKinds.removeLast() }
        computeResults()
        updateMeasureVisuals(in: renderView)
    }

    func selectMeasureType(_ type: MeasureType) {
        measureType = type
        clearMeasure()
    }

    func clearMeasure() {
        pickedPoints = []
        pickedKinds = []
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil
        measureGroup?.removeFromParentNode()
        measureGroup = nil
    }

    /// Changes the display unit and remembers it, so `SettingsView` and the viewer
    /// toolbar stay in agreement across launches.
    func setUnit(_ unit: DisplayUnit) {
        displayUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: "defaultUnit")
    }

    func toggleMeasureMode() {
        mode = mode == .measure ? .orbit : .measure
        if mode == .orbit { clearMeasure() }
    }

    // MARK: - Visuals

    /// Rebuilds the measurement annotations.
    ///
    /// Marker, line and label sizes are derived from the live camera through
    /// `unitsPerPoint(at:in:)`, so they hold a constant size on screen instead of the
    /// previous arbitrary fraction of the model's bounding box.
    private func updateMeasureVisuals(in view: SCNView?) {
        measureGroup?.removeFromParentNode()

        guard let scene else { return }

        let anchor = labelAnchor() ?? SCNVector3(0, 0, 0)
        let unitsPerPoint = view.map { self.unitsPerPoint(at: anchor, in: $0) }
            ?? CGFloat(modelDim) * 0.003

        let markerRadius = Float(unitsPerPoint) * 3.0
        let lineRadius = Float(unitsPerPoint) * 0.9

        let group = SCNNode()
        group.name = "measure_group"

        for (i, point) in pickedPoints.enumerated() {
            let kind = i < pickedKinds.count ? pickedKinds[i] : .none
            addMarker(at: point, kind: kind, index: i, radius: markerRadius, to: group)
        }

        if pickedPoints.count >= 2 {
            for i in 0..<pickedPoints.count-1 {
                addCylinderLine(from: pickedPoints[i], to: pickedPoints[i+1],
                                lineRadius: lineRadius, to: group)
            }
        }

        if measureType == .radius, let center = radiusCenter, radiusResult != nil {
            let centerSphere = SCNSphere(radius: CGFloat(markerRadius * 0.8))
            let cm = SCNMaterial()
            cm.diffuse.contents = UIColor.systemBlue
            cm.emission.contents = UIColor.systemBlue
            cm.lightingModel = .constant
            centerSphere.materials = [cm]
            let cn = SCNNode(geometry: centerSphere)
            cn.position = center
            cn.name = "measure_dot"
            group.addChildNode(cn)

            addCylinderLine(from: center, to: pickedPoints[0],
                            lineRadius: lineRadius, to: group, color: .systemBlue)
        }

        if let labelString = currentLabelString(), let labelAnchor = labelAnchor() {
            let text = SCNText(string: labelString, extrusionDepth: 0.1)
            text.font = UIFont.boldSystemFont(ofSize: 10)
            text.firstMaterial?.diffuse.contents = UIColor.label
            text.firstMaterial?.lightingModel = .constant

            let labelNode = SCNNode(geometry: text)
            let (tMin, tMax) = text.boundingBox
            let textHeight = tMax.y - tMin.y
            if textHeight > 1e-6 {
                let desiredHeight = Float(unitsPerPoint) * 13
                let s = desiredHeight / textHeight
                labelNode.scale = SCNVector3(s, s, s)
            }
            // Centre the text on its own origin so the billboard rotates about the
            // anchor point instead of the baseline's left edge.
            labelNode.pivot = SCNMatrix4MakeTranslation(
                (tMin.x + tMax.x) / 2, (tMin.y + tMax.y) / 2, (tMin.z + tMax.z) / 2)
            labelNode.position = SCNVector3(labelAnchor.x,
                                            labelAnchor.y + markerRadius * 2.5,
                                            labelAnchor.z)
            labelNode.name = "measure_label"
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            labelNode.constraints = [billboard]
            group.addChildNode(labelNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }

    private func addMarker(at point: SCNVector3, kind: SnapKind, index: Int,
                           radius markerRadius: Float, to group: SCNNode) {
        let color: UIColor
        switch kind {
        case .endpoint: color = UIColor.systemRed
        case .center: color = UIColor.systemBlue
        case .midpoint: color = UIColor.systemOrange
        case .quadrant: color = UIColor.systemPurple
        case .face: color = UIColor.systemTeal
        case .none: color = UIColor.systemRed
        }

        let sphere = SCNSphere(radius: CGFloat(markerRadius))
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color
        mat.lightingModel = .constant
        sphere.materials = [mat]
        let marker = SCNNode(geometry: sphere)
        marker.position = point
        marker.name = "measure_dot"
        group.addChildNode(marker)

        let tag = kind == .none ? "\(index + 1)" : kind.rawValue
        let text = SCNText(string: tag, extrusionDepth: 0.2)
        text.font = UIFont.boldSystemFont(ofSize: 10)
        text.firstMaterial?.diffuse.contents = UIColor.white
        text.firstMaterial?.emission.contents = UIColor.black
        text.firstMaterial?.lightingModel = .constant
        let textNode = SCNNode(geometry: text)

        let (tMin, tMax) = text.boundingBox
        let textHeight = tMax.y - tMin.y
        if textHeight > 1e-6 {
            let s = (markerRadius * 1.6) / textHeight
            textNode.scale = SCNVector3(s, s, s)
        }
        textNode.pivot = SCNMatrix4MakeTranslation(
            (tMin.x + tMax.x) / 2, (tMin.y + tMax.y) / 2, (tMin.z + tMax.z) / 2)
        textNode.position = SCNVector3(point.x, point.y + markerRadius * 2.2, point.z)
        textNode.name = "measure_num"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        textNode.constraints = [billboard]
        group.addChildNode(textNode)
    }

    private func addCylinderLine(from a: SCNVector3, to b: SCNVector3,
                                 lineRadius: Float, to group: SCNNode,
                                 color: UIColor = UIColor.systemRed) {
        let dx = b.x-a.x, dy = b.y-a.y, dz = b.z-a.z
        let dist = (dx*dx + dy*dy + dz*dz).squareRoot()
        guard dist > 1e-6 else { return }
        let cylinder = SCNCylinder(radius: CGFloat(lineRadius), height: CGFloat(dist))
        let cylMat = SCNMaterial()
        cylMat.diffuse.contents = color
        cylMat.lightingModel = .constant
        cylinder.materials = [cylMat]
        let cylNode = SCNNode(geometry: cylinder)
        cylNode.name = "measure_line"
        cylNode.position = SCNVector3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2)
        cylNode.look(at: b)
        cylNode.eulerAngles.x += Float.pi / 2
        group.addChildNode(cylNode)
    }

    private func currentLabelString() -> String? {
        switch measureType {
        case .distance, .linear:
            guard let d = distanceResult else { return nil }
            return displayUnit.format(d)
        case .angle:
            guard let a = angleResult else { return nil }
            return String(format: "%.1f°", a)
        case .radius:
            guard let r = radiusResult else { return nil }
            return displayUnit.format(r)
        }
    }

    private func labelAnchor() -> SCNVector3? {
        guard !pickedPoints.isEmpty else { return nil }
        if pickedPoints.count == 1 { return pickedPoints[0] }
        let sum = pickedPoints.dropFirst().reduce(pickedPoints[0]) {
            SCNVector3($0.x + $1.x, $0.y + $1.y, $0.z + $1.z)
        }
        let n = Float(pickedPoints.count)
        return SCNVector3(sum.x/n, sum.y/n, sum.z/n)
    }
}
