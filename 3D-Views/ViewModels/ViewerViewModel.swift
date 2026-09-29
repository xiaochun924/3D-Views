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
    case edge = "边"
    case face = "面"
    case none = ""

    /// Disambiguation priority: vertices win over edge-derived points, which win over
    /// a bare surface hit. Mirrors the "prefer edges over surfaces, then nearest of the
    /// same type" rule used by production CAD snapping engines.
    var priority: Int {
        switch self {
        case .endpoint, .center, .quadrant: return 0
        case .midpoint, .edge: return 1
        case .face: return 2
        case .none: return 3
        }
    }
}

/// A picked topological entity.
///
/// Measuring *entities* rather than raw points is what every mainstream CAD package
/// does, and it is the only way to get a true minimum distance between two faces or
/// an analytic radius: the kernel can answer those questions about a `TopoDS_Face`
/// or `TopoDS_Edge`, but not about a floating point in space.
///
/// The associated index addresses the same enumeration `Shape.face(at:)`,
/// `Shape.edge(at:)` and `Shape.vertices()` walk — one entry per distinct sub-shape,
/// in `TopExp_Explorer` order — so it round-trips straight into
/// `Shape.subShape(type:index:)`.
enum PickEntity: Equatable {
    /// No B-rep topology behind the pick (an STL import, or a point in mid-air).
    case freePoint
    case vertex(Int)
    case edge(Int)
    case face(Int)

    /// Compact tag for the on-model marker, matching the wording of the instructions.
    var shortLabel: String {
        switch self {
        case .freePoint: return "P"
        case .vertex(let i): return "V\(i + 1)"
        case .edge(let i): return "E\(i + 1)"
        case .face(let i): return "F\(i + 1)"
        }
    }

    var description: String {
        switch self {
        case .freePoint: return "点"
        case .vertex(let i): return "顶点 \(i + 1)"
        case .edge(let i): return "边 \(i + 1)"
        case .face(let i): return "面 \(i + 1)"
        }
    }
}

struct SnapPoint {
    let position: SCNVector3
    let kind: SnapKind
    /// Topological entity this candidate belongs to, when one is known.
    let entity: PickEntity?
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

    /// Picks required when the model has real B-rep topology.
    ///
    /// Fewer than `requiredPoints`, because the kernel supplies the reference
    /// geometry the user would otherwise have to describe by hand: an angle is two
    /// faces or two edges (not three points), and a radius is a single circular edge
    /// or cylindrical face (not three points on a circle).
    var requiredEntityPicks: Int {
        switch self {
        case .distance, .linear, .angle: return 2
        case .radius: return 1
        }
    }

    /// Hint shown while a measurement is in progress, in entity terms.
    var entityHint: String {
        switch self {
        case .distance:
            return "点选两个面或边，直接量取最小距离"
        case .linear:
            return "点选两点、两个顶点或两条边量取线性距离"
        case .angle:
            return "点选两个面或两条边，量取夹角"
        case .radius:
            return "点选一条圆边或一个回转面，量取半径"
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
    /// The topological entity behind each entry of `pickedPoints`; parallel array.
    @Published var pickedEntities: [PickEntity] = []
    /// Non-fatal explanation shown under the result, e.g. why an angle can't be formed.
    @Published var measureMessage: String?

    @Published var distanceResult: Float?
    @Published var angleResult: Float?
    @Published var radiusResult: Float?
    @Published var radiusCenter: SCNVector3?

    /// The kernel's own closest points for the current distance measurement.
    ///
    /// When present the annotation line joins these instead of the tapped positions,
    /// so it shows the true minimum-distance segment — which for two faces or two
    /// edges is generally nowhere near where the finger landed.
    @Published var closestPointA: SCNVector3?
    @Published var closestPointB: SCNVector3?

    /// The entity the finger is currently over, reported by a press-and-hold before the
    /// measurement is committed. Every desktop CAD app has this second state — OCCT's
    /// highlight presentation as against its selection presentation — because measuring
    /// the wrong face is otherwise only discoverable after committing.
    @Published var previewEntity: PickEntity?

    /// Where on that entity the finger is, for placing the preselect marker.
    @Published var previewPoint: SCNVector3?

    private var measureGroup: SCNNode?
    private var previewGroup: SCNNode?

    /// Snap kind of the preselect, kept private because it only colours the highlight.
    private var previewKind: SnapKind?
    private var modelNode: SCNNode?
    private var snapPoints: [SnapPoint] = []

    /// The loaded kernel shape. Kept alive for the lifetime of the model because
    /// entity measurements (`ShapeDistance`, `Face.angle`, `Edge.circleProperties`)
    /// need the B-rep, not just the tessellation drawn on screen.
    private var shape: OCCTSwift.Shape?

    /// Whether the loaded file carried real B-rep topology (STEP) rather than a mesh
    /// (STL). An STL read back by the kernel is a shell of triangles, so its "faces"
    /// are individual facets and entity measurement would be meaningless on it.
    private var isBrep = false

    /// Maps a SceneKit triangle ordinal to the B-rep face it was meshed from.
    ///
    /// `Mesh.sceneKitGeometry()` keeps only vertices, normals and indices, so the
    /// face association has to be captured at load time: `trianglesWithFaces()` is
    /// written in the same order as `Mesh.indices`, which is the order SceneKit
    /// numbers its triangles, which is what `SCNHitTestResult.faceIndex` reports.
    private var triangleToFace: [Int32] = []

    /// Edge index → its polyline already converted to world space, for screen-space
    /// edge picking. World space because `allowsCameraControl` moves the camera, never
    /// the model, so these never change after load and taps stay cheap.
    private var edgeWorldPolylines: [(edgeIndex: Int, points: [SCNVector3])] = []

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
        pickedPoints.count == requiredPickCount
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
            var loadedShape: OCCTSwift.Shape?
            var meshTrianglesWithFaces: [OCCTSwift.Triangle] = []

            if ext == "step" || ext == "stp" {
                let loaded = try OCCTSwift.Shape.loadSTEP(from: url)
                loadedShape = loaded
                guard let mesh = loaded.mesh(linearDeflection: 0.1, angularDeflection: 0.2) else {
                    loadError = "STEP 文件网格化失败。"
                    return
                }
                meshTrianglesWithFaces = mesh.trianglesWithFaces()
                geometry = mesh.sceneKitGeometry()
            } else {
                guard let loaded = OCCTSwift.Shape.readSTL(from: url.path) else {
                    loadError = "STL 文件读取失败。"
                    return
                }
                loadedShape = loaded
                guard let mesh = loaded.mesh(linearDeflection: 0.1) else {
                    loadError = "STL 文件网格化失败。"
                    return
                }
                meshTrianglesWithFaces = mesh.trianglesWithFaces()
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
            let brep = (ext == "step" || ext == "stp")
            let edgeGeometry = brep
                ? loadedShape.flatMap { $0.edgeMesh(deflection: 0.1) }
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

            // Publish the kernel state for entity measurement. `triangleToFace` is
            // indexed by SceneKit's triangle ordinal (see `SCNHitTestResult.faceIndex`),
            // and `edgePolylines` by the same edge index `Shape.edge(at:)` accepts.
            shape = brep ? loadedShape : nil
            isBrep = brep
            triangleToFace = brep ? meshTrianglesWithFaces.map(\.faceIndex) : []

            let mNode = built.rootNode.childNode(withName: "model", recursively: true)
            modelNode = mNode

            if let mNode {
                edgeWorldPolylines = brep ? Self.buildEdgePolylines(loadedShape, modelNode: mNode) : []
                snapPoints = buildSnapDatabase(shape: shape, geometry: geometry, modelNode: mNode)
            } else {
                edgeWorldPolylines = []
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

    /// Edge index → world-space polyline, for screen-space edge picking.
    ///
    /// `allEdgePolylinesIndexed` is a single batch call (O(edges)); the older
    /// per-edge `edgePolyline(at:)` loop it replaces was O(edges²) and cost ~20 s on
    /// a 12k-edge part. The `edgeIndex` it reports is the very index `Shape.edge(at:)`
    /// and `Edge.index` use, so a hit here addresses the same edge everywhere else.
    ///
    /// `maxPointsPerEdge` must be inside `2...Sampling.maximumSampleCount`
    /// (10,000,000) or the result comes back empty (#558); 64 is plenty to hit an edge
    /// on screen while keeping the per-tap projection loop short.
    private static func buildEdgePolylines(
        _ shape: OCCTSwift.Shape?,
        modelNode: SCNNode
    ) -> [(edgeIndex: Int, points: [SCNVector3])] {
        guard let shape else { return [] }

        let polylines = shape.allEdgePolylinesIndexed(deflection: 0.1, maxPointsPerEdge: 64)
        var result: [(edgeIndex: Int, points: [SCNVector3])] = []
        result.reserveCapacity(polylines.count)

        for entry in polylines {
            guard entry.points.count >= 2 else { continue }
            let world = entry.points.map { p in
                modelNode.convertPosition(
                    SCNVector3(Float(p.x), Float(p.y), Float(p.z)), to: nil)
            }
            result.append((edgeIndex: entry.edgeIndex, points: world))
        }
        return result
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
            // only meaningful snap candidates and none of them addresses an entity.
            return Self.extractVertices(from: geometry).map {
                SnapPoint(position: modelNode.convertPosition($0, to: nil),
                          kind: .endpoint,
                          entity: .freePoint)
            }
        }

        // `vertices()[i]` and `subShape(type: .vertex, index: i)` walk the same
        // `TopTools_IndexedMapOfShape`, so the enumerated index is a usable entity
        // reference; duplicates are dropped from the *snap list* only, and the index
        // kept is the first occurrence's.
        var seen = Set<SIMD3<Int64>>()
        for (index, v) in shape.vertices().enumerated() {
            let key = quantize(v)
            if seen.insert(key).inserted {
                result.append(SnapPoint(position: toWorld(v),
                                        kind: .endpoint,
                                        entity: .vertex(index)))
            }
        }

        let edgePolys = shape.allEdgePolylinesIndexed(deflection: 0.1, maxPointsPerEdge: 500)
        for (edgeIndex, pts) in edgePolys {
            guard pts.count >= 2 else { continue }
            let entity = PickEntity.edge(edgeIndex)

            // Let OCCT classify the curve instead of fitting a circle to samples.
            // `circleProperties` is only non-nil when the kernel itself reports
            // `curveType == .circle`, so a spline that happens to be round no longer
            // masquerades as a circle. The reported radius is still a three-point fit
            // on OCCT's own uniform parameter samples, but the *classification* (and
            // the axis / angular range that come with it) is the kernel's.
            if let circle = shape.edge(at: edgeIndex)?.circleProperties {
                result.append(SnapPoint(position: toWorld(circle.center),
                                        kind: .center,
                                        entity: entity))

                let axis = simd_normalize(circle.axis)
                var refDir = pts[0] - circle.center
                // Project onto the circle plane; `pts[0]` is a point *on* the circle
                // so this only removes numeric drift along the axis.
                refDir -= simd_dot(refDir, axis) * axis
                let refLen = simd_length(refDir)
                if refLen > 1e-9 {
                    refDir /= refLen
                    let perpDir = simd_cross(axis, refDir)
                    for d in [refDir, perpDir, -refDir, -perpDir] {
                        result.append(SnapPoint(position: toWorld(circle.center + circle.radius * d),
                                                kind: .quadrant,
                                                entity: entity))
                    }
                }
            } else {
                let mid = pts[pts.count / 2]
                result.append(SnapPoint(position: toWorld(mid),
                                        kind: .midpoint,
                                        entity: entity))
            }
        }

        return result
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
        guard let (snapped, kind, entity) = snap(screenPoint: screenPoint, in: view) else { return }
        commitPick(point: snapped, kind: kind, entity: entity, in: view)
    }

    // MARK: - Preselect

    /// Reports the entity under the finger while a press-and-hold is in progress.
    ///
    /// Nothing is committed here: this exists so the entity about to be measured can be
    /// highlighted first. Every mainstream CAD application keeps preselection and
    /// selection as two distinct states (in OCCT, the highlight presentation as against
    /// the selection presentation) because a face picked by eye on a phone is easy to
    /// get wrong, and without a preview the mistake only surfaces after committing.
    func handlePreview(screenPoint: CGPoint, in view: SCNView) {
        guard mode == .measure else { return }

        guard let (point, kind, entity) = snap(screenPoint: screenPoint, in: view) else {
            clearPreview()
            return
        }

        // Skip the rebuild when the highlight would not change: a drag across one face
        // fires many updates, and each one projects every snap point and re-highlights.
        if entity == previewEntity, let current = previewPoint,
           Self.distance(current, point) < max(modelDim, 1) * 0.001 {
            return
        }

        previewPoint = point
        previewKind = kind
        previewEntity = entity
        updatePreviewVisuals(in: view)
    }

    /// Commits the preselected entity and drops the highlight.
    ///
    /// This is the release half of press-and-hold. The tap recognizer is made to wait
    /// for the hold to fail, so a hold that has begun never also delivers a tap and this
    /// is the only path that commits its pick — and it commits exactly the entity the
    /// user was watching highlighted. Holding over empty space commits nothing.
    func commitPreview(in view: SCNView) {
        defer { clearPreview() }
        guard mode == .measure,
              let entity = previewEntity,
              let point = previewPoint else { return }
        commitPick(point: point, kind: previewKind ?? .face, entity: entity, in: view)
    }

    /// Drops the preselect highlight without committing anything.
    func clearPreview() {
        previewPoint = nil
        previewKind = nil
        previewEntity = nil
        previewGroup?.removeFromParentNode()
        previewGroup = nil
    }

    /// Shared commit for both interaction paths — a quick tap and the release of a
    /// press-and-hold — so the two can never diverge in how they fill the arrays.
    private func commitPick(point: SCNVector3, kind: SnapKind, entity: PickEntity,
                            in view: SCNView) {
        if pickedPoints.count >= requiredPickCount {
            pickedPoints = [point]
            pickedKinds = [kind]
            pickedEntities = [entity]
        } else {
            pickedPoints.append(point)
            pickedKinds.append(kind)
            pickedEntities.append(entity)
        }

        computeResults()
        updateMeasureVisuals(in: view)
    }

    /// How many picks the current model and measurement type need.
    ///
    /// Entity measurement is only meaningful when the kernel kept real B-rep topology
    /// (STEP). An STL is a triangle shell, so it stays on the point-based path and
    /// keeps `requiredPoints`.
    var requiredPickCount: Int {
        isBrep ? measureType.requiredEntityPicks : measureType.requiredPoints
    }

    /// Whether this model measures entities rather than bare points. Drives the
    /// instructions and the result panel wording.
    var usesEntityMeasurement: Bool { isBrep }

    /// The entities picked so far, named the way the instructions name them.
    var pickedEntityNames: [String] {
        pickedEntities.prefix(pickedPoints.count).map(\.description)
    }

    /// Name of the entity currently under the finger, if any.
    var previewEntityName: String? {
        previewEntity?.description
    }

    /// Screen-space snapping.
    ///
    /// Every candidate is projected to the viewport and compared in 2D points, so the
    /// effective tolerance is constant on screen at any zoom level. Candidates hidden
    /// behind the front-most surface under the tap are rejected.
    ///
    /// Returns the topological entity the snap resolved to alongside the position, so
    /// the measurement can be computed against the kernel's geometry rather than the
    /// tessellation. Order of preference is the researched "edges first, then faces,
    /// then nearest of the same type": an explicit snap candidate (vertex, circle
    /// centre, quadrant, edge midpoint) wins over a bare edge hit, which in turn wins
    /// over the plain surface under the finger.
    private func snap(screenPoint: CGPoint, in view: SCNView)
        -> (SCNVector3, SnapKind, PickEntity)? {

        let modelHits = view.hitTest(screenPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ]).filter { $0.node === modelNode }

        let cameraPosition = view.pointOfView?.worldPosition
        var frontWorld: SCNVector3?
        var frontDistance = Float.greatestFiniteMagnitude
        // `SCNHitTestResult.faceIndex` is an `Int`, not the `Int32` the mesh tables use.
        var frontFaceIndex: Int?
        if let cameraPosition {
            for hit in modelHits {
                let d = Self.distance(cameraPosition, hit.worldCoordinates)
                if d < frontDistance {
                    frontDistance = d
                    frontWorld = hit.worldCoordinates
                    frontFaceIndex = hit.faceIndex
                }
            }
        }

        let occlusionTolerance = max(modelDim, 1) * 0.004
        var bestKind: SnapKind?
        var bestPoint: SCNVector3?
        var bestEntity: PickEntity?
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
                bestEntity = candidate.entity
            }
        }

        if let bestPoint, let bestKind {
            return (bestPoint, bestKind, bestEntity ?? .freePoint)
        }

        // No discrete candidate: try the edges themselves, in screen space and at the
        // same tolerance, so tapping along an edge measures *that edge* — the only way
        // to get an edge-to-edge minimum distance, an edge angle or a circle radius.
        if isBrep, let edgeHit = nearestEdgeHit(to: screenPoint, in: view) {
            return (edgeHit.point, .edge, .edge(edgeHit.edgeIndex))
        }

        // Nothing close enough: fall back to the surface directly under the tap. Tapping
        // empty space is ignored rather than adding a stray point.
        if let frontWorld {
            return (frontWorld, .face, faceEntity(for: frontFaceIndex))
        }
        return nil
    }

    /// Maps a SceneKit hit's triangle ordinal onto the B-rep face it was tessellated
    /// from.
    ///
    /// `Mesh.sceneKitGeometry()` carries only positions, normals and indices — the
    /// face association is dropped — so the mapping has to be captured at load time
    /// from `trianglesWithFaces()`, whose order matches `Mesh.indices`, which is in
    /// turn the order `SCNHitTestResult.faceIndex` numbers triangles in.
    private func faceEntity(for triangleIndex: Int?) -> PickEntity {
        guard let triangleIndex, triangleIndex >= 0,
              triangleIndex < triangleToFace.count else { return .freePoint }
        return .face(Int(triangleToFace[triangleIndex]))
    }

    /// Closest edge polyline to a screen point, within the snap radius.
    private func nearestEdgeHit(to screenPoint: CGPoint, in view: SCNView)
        -> (point: SCNVector3, edgeIndex: Int)? {

        var best: (point: SCNVector3, edgeIndex: Int)?
        var bestDistance = snapScreenRadius

        for entry in edgeWorldPolylines {
            let pts = entry.points
            guard pts.count >= 2 else { continue }

            var previous = view.projectPoint(pts[0])
            for i in 1..<pts.count {
                let current = view.projectPoint(pts[i])
                defer { previous = current }

                // Both ends behind the camera or outside the depth range: skip.
                guard current.z >= 0, current.z <= 1,
                      previous.z >= 0, previous.z <= 1 else { continue }

                let distance = Self.segmentScreenDistance(
                    screenPoint,
                    CGPoint(x: CGFloat(previous.x), y: CGFloat(previous.y)),
                    CGPoint(x: CGFloat(current.x), y: CGFloat(current.y)))

                if distance < bestDistance {
                    bestDistance = distance
                    // Parameter along the segment at the closest approach, so the
                    // marker lands under the finger rather than on an endpoint.
                    let t = Self.segmentParameter(
                        screenPoint,
                        CGPoint(x: CGFloat(previous.x), y: CGFloat(previous.y)),
                        CGPoint(x: CGFloat(current.x), y: CGFloat(current.y)))
                    // Spelled out rather than left as one nested tuple literal: mixing
                    // the `CGFloat` parameter into `Float` arithmetic made the expression
                    // too complex for the type-checker to solve in reasonable time.
                    let a = pts[i - 1], b = pts[i]
                    let tf = Float(t)
                    let point = SCNVector3(a.x + (b.x - a.x) * tf,
                                           a.y + (b.y - a.y) * tf,
                                           a.z + (b.z - a.z) * tf)
                    best = (point: point, edgeIndex: entry.edgeIndex)
                }
            }
        }

        return best
    }

    private static func segmentScreenDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let t = segmentParameter(p, a, b)
        let cx = a.x + (b.x - a.x) * t
        let cy = a.y + (b.y - a.y) * t
        return ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    }

    /// Clamped projection parameter of `p` onto segment `a`–`b`.
    private static func segmentParameter(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return 0 }
        let raw = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        return max(0, min(1, raw))
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
        closestPointA = nil
        closestPointB = nil
        measureMessage = nil

        guard pickedPoints.count == requiredPickCount else { return }

        if isBrep, computeEntityResults() { return }

        switch measureType {
        case .distance, .linear:
            let a = pickedPoints[0], b = pickedPoints[1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            distanceResult = (dx*dx + dy*dy + dz*dz).squareRoot()

        case .angle:
            guard pickedPoints.count >= 3 else { return }
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
            guard pickedPoints.count >= 3 else { return }
            if let (center, radius) = Self.circumcircle(
                pickedPoints[0], pickedPoints[1], pickedPoints[2]
            ) {
                radiusCenter = center
                radiusResult = radius
            }
        }
    }

    // MARK: - Entity measurement

    /// Measures against the kernel's own geometry rather than the tapped points.
    ///
    /// This is what makes the numbers *mean* something: two faces are an arbitrarily
    /// shaped pair whose minimum distance the tessellation can only approximate, and a
    /// radius taken from three tapped points depends entirely on how accurately the
    /// finger landed. The kernel answers both exactly.
    ///
    /// Returns `false` when the picks don't resolve to usable entities, letting the
    /// caller fall back to the point-based maths; that fallback is also the only path
    /// on an STL import, which has no B-rep topology at all.
    private func computeEntityResults() -> Bool {
        let entities = Array(pickedEntities.prefix(pickedPoints.count))
        guard entities.count == requiredPickCount else { return false }

        switch measureType {
        case .distance, .linear:
            guard entities.count == 2,
                  let first = subShape(for: entities[0]),
                  let second = subShape(for: entities[1]),
                  let measure = OCCTSwift.ShapeDistance(shape1: first, shape2: second),
                  measure.isDone else { return false }

            distanceResult = Float(measure.value)

            // The kernel's own witness points, not the tapped ones: for two faces or
            // two edges the minimum segment generally sits nowhere near where the
            // finger landed, so the annotation has to join these to make sense.
            if measure.solutionCount > 0 {
                closestPointA = world(measure.pointOnShape1(at: 0))
                closestPointB = world(measure.pointOnShape2(at: 0))
            }
            return true

        case .angle:
            guard entities.count == 2 else { return false }

            switch (entities[0], entities[1]) {
            case let (.face(i), .face(j)):
                guard let first = shape?.face(at: i),
                      let second = shape?.face(at: j) else { return false }
                if first.isParallel(to: second) == true {
                    measureMessage = "两实体平行，无法测量夹角"
                    return true
                }
                guard let radians = first.angle(to: second) else { return false }
                angleResult = Float(radians) * 180 / Float.pi
                return true

            case let (.edge(i), .edge(j)):
                guard let first = shape?.edge(at: i),
                      let second = shape?.edge(at: j) else { return false }
                if first.isParallel(to: second) == true {
                    measureMessage = "两实体平行，无法测量夹角"
                    return true
                }
                guard let radians = first.angle(to: second) else { return false }
                angleResult = Float(radians) * 180 / Float.pi
                return true

            default:
                // A face/edge pair has no single agreed angle definition — the kernel
                // offers helpers only for like-to-like. Say so instead of falling
                // through to the three-point estimate, which would need a third pick
                // the entity path never asked for.
                measureMessage = "请点选两个面或两条边来量取夹角"
                return true
            }

        case .radius:
            guard let entity = entities.first else { return false }

            switch entity {
            case .edge(let i):
                // `circleProperties` is nil unless the kernel itself classifies the
                // edge as `GeomAbs_Circle`, so a round-looking spline is correctly
                // rejected rather than silently measured.
                guard let circle = shape?.edge(at: i)?.circleProperties else {
                    measureMessage = "请点选一条圆边或一个回转面来量取半径"
                    return true
                }
                radiusResult = Float(circle.radius)
                radiusCenter = world(circle.center)
                return true

            case .face(let i):
                guard let revolution = shape?.face(at: i)?.revolutionProperties else {
                    measureMessage = "请点选一条圆边或一个回转面来量取半径"
                    return true
                }
                radiusResult = Float(revolution.radius)
                // A cylindrical face's radius is swept about an axis, so there is no
                // single point the radius is drawn from; leaving `radiusCenter` nil
                // suppresses the centre marker rather than inventing a false one.
                radiusCenter = nil
                return true

            case .vertex, .freePoint:
                measureMessage = "请点选一条圆边或一个回转面来量取半径"
                return true
            }
        }
    }

    /// Resolves a picked entity to the kernel sub-shape it addresses.
    ///
    /// The index carried by `PickEntity` comes from the same
    /// `TopTools_IndexedMapOfShape` as `subShape(type:index:)`, so it addresses the
    /// exact face / edge / vertex the user tapped.
    private func subShape(for entity: PickEntity) -> OCCTSwift.Shape? {
        guard let shape else { return nil }
        switch entity {
        case .face(let i): return shape.subShape(type: .face, index: i)
        case .edge(let i): return shape.subShape(type: .edge, index: i)
        case .vertex(let i): return shape.subShape(type: .vertex, index: i)
        case .freePoint: return nil
        }
    }

    /// Kernel coordinates → world coordinates, through the model node's transform.
    private func world(_ point: SIMD3<Double>) -> SCNVector3 {
        let local = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        guard let modelNode else { return local }
        return modelNode.convertPosition(local, to: nil)
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
        if !pickedEntities.isEmpty { pickedEntities.removeLast() }
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
        pickedEntities = []
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil
        closestPointA = nil
        closestPointB = nil
        measureMessage = nil
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

    /// Highlights the entity the finger is over during a press-and-hold.
    ///
    /// Deliberately styled unlike a committed marker — yellow, translucent, and with the
    /// entity's name beside it — because it means "this is what you will measure if you
    /// lift now", not "this has been measured". It is rebuilt on every change of entity
    /// and removed the moment the finger lifts.
    private func updatePreviewVisuals(in view: SCNView?) {
        previewGroup?.removeFromParentNode()
        previewGroup = nil

        guard let scene, let point = previewPoint else { return }

        let unitsPerPoint = view.map { self.unitsPerPoint(at: point, in: $0) }
            ?? CGFloat(modelDim) * 0.003
        let radius = Float(unitsPerPoint) * 4.0

        let group = SCNNode()
        group.name = "preview_group"

        let sphere = SCNSphere(radius: CGFloat(radius))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.85)
        material.emission.contents = UIColor.systemYellow.withAlphaComponent(0.35)
        material.lightingModel = .constant
        // Drawn over the surface it highlights: the point generally sits *on* the model,
        // so depth testing alone would clip away most of the sphere.
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        sphere.materials = [material]

        let dot = SCNNode(geometry: sphere)
        dot.position = point
        dot.name = "preview_dot"
        group.addChildNode(dot)

        if let name = previewEntityName {
            let text = SCNText(string: name, extrusionDepth: 0.1)
            text.font = UIFont.boldSystemFont(ofSize: 10)
            text.firstMaterial?.diffuse.contents = UIColor.systemYellow
            text.firstMaterial?.lightingModel = .constant

            let labelNode = SCNNode(geometry: text)
            let (tMin, tMax) = text.boundingBox
            let textHeight = tMax.y - tMin.y
            if textHeight > 1e-6 {
                let desiredHeight = Float(unitsPerPoint) * 14
                let s = desiredHeight / textHeight
                labelNode.scale = SCNVector3(s, s, s)
            }
            labelNode.pivot = SCNMatrix4MakeTranslation(
                (tMin.x + tMax.x) / 2, (tMin.y + tMax.y) / 2, (tMin.z + tMax.z) / 2)
            // Offset above the finger: the label must not sit under the hand that is
            // holding the screen.
            labelNode.position = SCNVector3(point.x, point.y + radius * 3.0, point.z)
            labelNode.name = "preview_label"

            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            labelNode.constraints = [billboard]
            group.addChildNode(labelNode)
        }

        scene.rootNode.addChildNode(group)
        previewGroup = group
    }

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
            let entity = i < pickedEntities.count ? pickedEntities[i] : .freePoint
            addMarker(at: point, kind: kind, entity: entity, index: i,
                      radius: markerRadius, to: group)
        }

        // When the kernel supplied its own witness points, draw the measured segment
        // between *those* — for two faces or two edges the true minimum is generally
        // nowhere near the tapped positions, and joining the taps would depict a
        // distance longer than the one being reported.
        if let a = closestPointA, let b = closestPointB {
            addCylinderLine(from: a, to: b, lineRadius: lineRadius, to: group)
            addMarker(at: a, kind: .none, entity: .freePoint, index: -1,
                      radius: markerRadius * 0.7, to: group, showTag: false)
            addMarker(at: b, kind: .none, entity: .freePoint, index: -1,
                      radius: markerRadius * 0.7, to: group, showTag: false)
        } else if pickedPoints.count >= 2 {
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

    private func addMarker(at point: SCNVector3, kind: SnapKind, entity: PickEntity,
                           index: Int, radius markerRadius: Float, to group: SCNNode,
                           showTag: Bool = true) {
        let color: UIColor
        switch kind {
        case .endpoint: color = UIColor.systemRed
        case .center: color = UIColor.systemBlue
        case .midpoint: color = UIColor.systemOrange
        case .quadrant: color = UIColor.systemPurple
        case .edge: color = UIColor.systemGreen
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

        guard showTag else { return }

        // Tag with the entity the pick resolved to (`F3`, `E7`, `V12`), which is what
        // the result panel and the instructions talk about; fall back to the pick
        // ordinal when there is no topology behind it (an STL import).
        let tag = entity == .freePoint ? "\(index + 1)" : entity.shortLabel
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
