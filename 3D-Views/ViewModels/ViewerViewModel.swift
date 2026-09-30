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

    /// Marker colour, mirroring the convention the old snap engine used: red holds
    /// points and vertices, green reads as an edge, teal as a face.
    var markerColor: UIColor {
        switch self {
        case .freePoint, .vertex: return .systemRed
        case .edge: return .systemGreen
        case .face: return .systemTeal
        }
    }
}

/// One committed pick.
///
/// The measurement used to be three parallel arrays — position, snap kind, entity —
/// which had to be appended to, truncated and cleared in lockstep. A single value
/// removes that class of bug outright and is what the selection list enumerates.
struct Pick: Identifiable {
    let id = UUID()
    let point: SCNVector3
    let entity: PickEntity
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

/// How the model is drawn.
///
/// The set mirrors what a desktop CAD viewer offers, because the right mode depends on
/// the question being asked: a shade shows the form, the edges show the feature
/// boundaries that a shade loses at a silhouette, a wireframe shows the construction
/// underneath the surfaces, and a translucent shade is the only way to see an internal
/// feature without cutting the part open.
enum DisplayMode: String, CaseIterable, Identifiable {
    case shaded
    case shadedWithEdges
    case wireframe
    case transparent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shaded: return "着色"
        case .shadedWithEdges: return "带边着色"
        case .wireframe: return "线框"
        case .transparent: return "透明"
        }
    }

    var icon: String {
        switch self {
        case .shaded: return "circle.fill"
        case .shadedWithEdges: return "cube.fill"
        case .wireframe: return "grid"
        case .transparent: return "circle.lefthalf.filled"
        }
    }
}

enum MeasureType: String, CaseIterable, Identifiable {
    case distance
    case angle
    case radius
    case linear
    case area
    case volume
    case boundingBox

    var id: String { rawValue }
    var label: String {
        switch self {
        case .distance: return "距离"
        case .angle: return "角度"
        case .radius: return "半径"
        case .linear: return "线性测量"
        case .area: return "面积"
        case .volume: return "体积"
        case .boundingBox: return "包围盒"
        }
    }
    var icon: String {
        switch self {
        case .distance: return "ruler"
        case .angle: return "angle"
        case .radius: return "clockwise"
        case .linear: return "move.3d"
        case .area: return "square.dashed"
        case .volume: return "cube.transparent"
        case .boundingBox: return "cube"
        }
    }
    var requiredPoints: Int {
        switch self {
        case .distance, .linear: return 2
        case .angle, .radius: return 3
        case .area: return 1
        case .volume, .boundingBox: return 0
        }
    }

    /// Picks required when the model has real B-rep topology.
    ///
    /// Fewer than `requiredPoints`, because the kernel supplies the reference
    /// geometry the user would otherwise have to describe by hand: an angle is two
    /// faces or two edges (not three points), a radius is a single circular edge
    /// or cylindrical face (not three points on a circle), and an area is one face.
    /// Volume and the bounding box are properties of the whole solid, so they take
    /// no pick at all.
    var requiredEntityPicks: Int {
        switch self {
        case .distance, .linear, .angle: return 2
        case .radius, .area: return 1
        case .volume, .boundingBox: return 0
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
        case .area:
            return "点选一个面，量取该面的表面积"
        case .volume:
            return "体积由内核直接计算，无需点选"
        case .boundingBox:
            return "包围盒由模型外形直接给出，无需点选"
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

    /// How the model is drawn. Applied to the live scene on every change rather than
    /// baked in at load, so switching modes costs nothing and never re-tessellates.
    @Published var displayMode: DisplayMode = .shadedWithEdges {
        didSet {
            guard oldValue != displayMode else { return }
            applyDisplayMode()
        }
    }

    /// Every pick of the current measurement, in the order they were taken.
    @Published var picks: [Pick] = []

    /// Non-fatal explanation shown under the result, e.g. why an angle can't be formed.
    @Published var measureMessage: String?

    @Published var distanceResult: Float?
    @Published var angleResult: Float?
    @Published var radiusResult: Float?
    @Published var radiusCenter: SCNVector3?

    /// Area of the picked face, in square display units.
    @Published var areaResult: Float?

    /// Volume enclosed by the whole shape. `nil` when the shape is not a closed solid
    /// — an open shell, a bare face, or an unsewn compound — because the kernel refuses
    /// to report a volume for those rather than reporting a meaningless number.
    @Published var volumeResult: Float?

    /// Extents of the axis-aligned bounding box, on x / y / z.
    @Published var boundingBoxExtents: SCNVector3?

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

    /// Translucent whole-face overlays for the committed picks and the preselect.
    /// Children of the model node, because the overlay geometry is re-emitted from the
    /// model's own vertex buffer and therefore lives in the model's local space.
    private var measureFaceGroup: SCNNode?
    private var previewFaceNode: SCNNode?

    /// Bright polylines over the picked edges. World space, so they are children of the
    /// scene root rather than the model node.
    private var measureEdgeNode: SCNNode?
    private var previewEdgeNode: SCNNode?

    /// Per-face overlay geometry keyed by style and face index. Built once per face and
    /// reused while the finger slides across it, so a drag over a densely tessellated
    /// face does not re-emit its triangles on every update.
    private var faceOverlayCache: [String: SCNGeometry] = [:]

    /// The model's own vertex and index buffers, kept so a picked face's triangles can
    /// be re-emitted as a patch over the shaded surface. `triangleToFace` says which
    /// triangles belong to the face a tap resolved to.
    private var modelVertices: [SCNVector3] = []
    private var modelTriangleIndices: [UInt32] = []

    private var modelNode: SCNNode?

    /// The loaded kernel shape. Kept alive for the lifetime of the model because every
    /// pick is resolved against the B-rep — by ray casting — and entity measurements
    /// (`ShapeDistance`, `Face.angle`, `Edge.circleProperties`) need it too.
    private var shape: OCCTSwift.Shape?

    /// Whether the loaded file carried real B-rep topology (STEP) rather than a mesh
    /// (STL). An STL read back by the kernel is a shell of triangles, so its "faces"
    /// are individual facets and entity measurement would be meaningless on it.
    private var isBrep = false

    /// Maps a SceneKit triangle ordinal to the B-rep face it was meshed from. Only
    /// needed by the SceneKit hit-test fallback; the kernel ray cast reports the face
    /// index directly.
    private var triangleToFace: [Int32] = []

    /// Edge index → its polyline in world space. World space because
    /// `allowsCameraControl` moves the camera, never the model, so these never change
    /// after load. Used both for screen-space edge picking and for drawing the picked
    /// edges back over the model.
    private var edgeWorldPolylines: [(edgeIndex: Int, points: [SCNVector3])] = []

    /// Vertex index → world position. Index is the one `Shape.vertices()` enumerates,
    /// which is the one `Shape.subShape(type: .vertex, index:)` addresses.
    private var vertexWorld: [(index: Int, position: SCNVector3)] = []

    /// Set by `SceneView` once the renderer exists. Only used for screen-space sizing
    /// of annotations and for hit-testing; deliberately not `@Published`, so attaching
    /// it never triggers a view update.
    weak var renderView: SCNView?

    func attach(view: SCNView) {
        renderView = view
    }

    /// Takes the rendering camera back from SceneKit's camera controller.
    ///
    /// Enabling `allowsCameraControl` makes SceneKit insert a camera of its own as an
    /// immediate child of the scene root and assign it to the view's `pointOfView`. That
    /// is the camera which actually renders — not the one `buildScene` configured — and
    /// it carries SceneKit's defaults, `zNear = 1` and `zFar = 100`. With the camera
    /// placed at `2.4 × modelDim`, any part larger than roughly 40 units therefore falls
    /// behind the far plane and is clipped away, which reads as a model whose outline
    /// cannot be made out at all.
    ///
    /// Assigning `pointOfView` is the whole fix; the camera controller then drives
    /// whichever node is the point of view, so gestures, `resetView` and this all end up
    /// acting on the same camera. It has to happen after the scene is handed to the
    /// view, because that assignment is what makes SceneKit install its camera — doing
    /// it any earlier is silently undone.
    func claimPointOfView(in view: SCNView, scene: SCNScene) {
        renderView = view
        guard let cam = scene.rootNode.childNode(withName: "camera", recursively: true) else {
            return
        }
        view.pointOfView = cam
    }

    /// Screen-space snap radius, in points. 14 pt is a comfortable touch target on
    /// iPhone and iPad alike, and it is the same tolerance for edges and vertices.
    private let snapScreenRadius: CGFloat = 14

    /// Throttle for the press-and-hold preselect: a `changed` event that has not moved
    /// the finger meaningfully cannot resolve to a different entity, and re-running the
    /// pick is the expensive part of that gesture.
    private var lastPreviewTouch: CGPoint?

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
        picks.count == requiredPickCount
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

            let brep = (ext == "step" || ext == "stp")
            if brep {
                loadedShape = try OCCTSwift.Shape.loadSTEP(from: url)
            } else {
                guard let loaded = OCCTSwift.Shape.readSTL(from: url.path) else {
                    loadError = "STL 文件读取失败。"
                    return
                }
                loadedShape = loaded
            }

            // Deflection is chosen from the part's own size rather than a fixed 0.1:
            // an absolute value that suits a 100 mm part over-tessellates a metre-long
            // one and, worse, leaves a 20 mm part visibly faceted — the "细节没显示出来"
            // report. Scaling with the diagonal keeps curvature detail proportional.
            let deflection = Self.tessellationDeflection(for: loadedShape)

            let mesh: OCCTSwift.Mesh?
            if brep {
                var params = OCCTSwift.MeshParameters.default
                params.deflection = deflection
                // The angular bound is what actually governs a small fillet or a bore on a
                // part that is otherwise large: the linear deflection is measured against the
                // whole part's scale, so without a tight angle those features collapse to a
                // handful of facets however fine the linear bound is set.
                params.angle = 0.15
                params.adjustMinSize = true
                mesh = loadedShape?.mesh(parameters: params)
            } else {
                mesh = loadedShape?.mesh(linearDeflection: deflection)
            }
            guard let mesh else {
                loadError = brep ? "STEP 文件网格化失败。" : "STL 文件网格化失败。"
                return
            }
            meshTrianglesWithFaces = mesh.trianglesWithFaces()
            geometry = mesh.sceneKitGeometry()

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

            // Real B-rep edge polylines. Drawing the *triangle* mesh with
            // `fillMode = .lines` instead would draw every tessellation triangle edge
            // (thousands of hairlines) rather than the model's actual edges.
            //
            // Only drawable for BREP formats: an STL has no genuine edge structure, so
            // its edge set is just every facet boundary — the same noise again.
            //
            // One discretisation feeds both the wireframe drawn on the model and the
            // screen-space edge picking: the same polylines go to the renderer in the
            // kernel's own frame and to the picker in world space, so an edge that is drawn
            // and an edge that can be tapped can never drift apart. The edges are taken at
            // a finer deflection than the shaded mesh, because a faceted silhouette is far
            // more visible on a hairline than on a shaded surface.
            let edgePolylines = brep
                ? (loadedShape?.allEdgePolylinesIndexed(
                    deflection: min(deflection, 0.05), maxPointsPerEdge: 64) ?? [])
                : []
            let edgeGeometry = Self.makeEdgeGeometry(from: edgePolylines)

            let built = Self.buildScene(
                geometry: geometry,
                edgeGeometry: brep ? edgeGeometry : nil,
                center: center,
                cameraDistance: cameraDistance
            )
            scene = built
            fileName = url.lastPathComponent

            // Publish the kernel state for entity measurement.
            shape = brep ? loadedShape : nil
            isBrep = brep
            triangleToFace = brep ? meshTrianglesWithFaces.map(\.faceIndex) : []

            // Retain the mesh buffers and drop any highlight built for the previous
            // model, including its cached overlay geometry.
            modelVertices = Self.extractVertices(from: geometry)
            modelTriangleIndices = Self.extractTriangleIndices(from: geometry)
            faceOverlayCache.removeAll()
            clearHighlightNodes()

            let mNode = built.rootNode.childNode(withName: "model", recursively: true)
            modelNode = mNode

            if let mNode {
                edgeWorldPolylines = brep
                    ? Self.buildEdgePolylines(edgePolylines, modelNode: mNode)
                    : []
                vertexWorld = brep ? Self.buildVertexWorld(loadedShape, modelNode: mNode) : []
            } else {
                edgeWorldPolylines = []
                vertexWorld = []
            }

            clearMeasure()

            // The scene is rebuilt from scratch on every load, so the user's chosen
            // display mode has to be re-applied to the new materials rather than only
            // set once at init.
            applyDisplayMode()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    /// Linear deflection scaled to the part: fine enough to show small fillets and
    /// holes, coarse enough not to explode on a large assembly.
    private static func tessellationDeflection(for shape: OCCTSwift.Shape?) -> Double {
        guard let box = shape?.bounds else { return 0.1 }
        let diagonal = simd_length(box.max - box.min)
        guard diagonal.isFinite, diagonal > 0 else { return 0.1 }
        return min(max(diagonal * 0.0004, 0.01), 0.5)
    }

    // MARK: - Edge geometry

    /// Builds a single line-primitive geometry from the kernel's edge polylines.
    ///
    /// Takes the same `(edgeIndex, points)` list the picker consumes, in the kernel's own
    /// frame, so the wireframe on the model and the set of tappable edges are one and the
    /// same set of curves.
    private static func makeEdgeGeometry(
        from polys: [(edgeIndex: Int, points: [SIMD3<Double>])]
    ) -> SCNGeometry? {
        var positions: [SCNVector3] = []
        var indices: [UInt32] = []

        for entry in polys {
            let pts = entry.points
            guard pts.count >= 2 else { continue }
            let base = UInt32(positions.count)
            for p in pts {
                positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
            }
            for i in 0..<(pts.count - 1) {
                indices.append(base + UInt32(i))
                indices.append(base + UInt32(i + 1))
            }
        }

        guard indices.count >= 2 else { return nil }

        let source = SCNGeometrySource(vertices: positions)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [source], elements: [element])
    }

    /// Edge index → world-space polyline, for screen-space edge picking and for the
    /// picked-edge highlight.
    ///
    /// `edgeIndex` is the very index `Shape.edge(at:)` and `Edge.index` use, so a hit here
    /// addresses the same edge everywhere else.
    private static func buildEdgePolylines(
        _ polys: [(edgeIndex: Int, points: [SIMD3<Double>])],
        modelNode: SCNNode
    ) -> [(edgeIndex: Int, points: [SCNVector3])] {
        var result: [(edgeIndex: Int, points: [SCNVector3])] = []
        result.reserveCapacity(polys.count)

        for entry in polys {
            guard entry.points.count >= 2 else { continue }
            let world = entry.points.map { p in
                modelNode.convertPosition(
                    SCNVector3(Float(p.x), Float(p.y), Float(p.z)), to: nil)
            }
            result.append((edgeIndex: entry.edgeIndex, points: world))
        }
        return result
    }

    /// Vertex index → world position, for vertex picking.
    ///
    /// `vertices()[i]` and `subShape(type: .vertex, index: i)` walk the same
    /// `TopTools_IndexedMapOfShape`, so the enumerated index is a usable entity
    /// reference.
    private static func buildVertexWorld(
        _ shape: OCCTSwift.Shape?,
        modelNode: SCNNode
    ) -> [(index: Int, position: SCNVector3)] {
        guard let shape else { return [] }
        return shape.vertices().enumerated().map { index, v in
            let local = SCNVector3(Float(v.x), Float(v.y), Float(v.z))
            return (index, modelNode.convertPosition(local, to: nil))
        }
    }

    /// Flattens the model's triangle index buffer.
    ///
    /// Concatenating every triangle element in order reproduces the same triangle
    /// ordinal `SCNHitTestResult.faceIndex` reports, which is what `triangleToFace` is
    /// keyed by. Widths of 1, 2 and 4 bytes are all accepted because `sceneKitGeometry()`
    /// narrows the indices to the smallest type that fits the vertex count.
    static func extractTriangleIndices(from geometry: SCNGeometry) -> [UInt32] {
        var indices: [UInt32] = []
        for element in geometry.elements where element.primitiveType == .triangles {
            let bytesPerIndex = element.bytesPerIndex
            guard bytesPerIndex > 0 else { continue }
            // Derived from the buffer rather than `indexCount`, which is documented but
            // which older SceneKit builds have been known to report inconsistently.
            let count = element.data.count / bytesPerIndex
            guard count > 0 else { continue }
            indices.reserveCapacity(indices.count + count)
            element.data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let offset = i * bytesPerIndex
                    switch bytesPerIndex {
                    case 1: indices.append(UInt32(raw.load(fromByteOffset: offset, as: UInt8.self)))
                    case 2: indices.append(UInt32(raw.load(fromByteOffset: offset, as: UInt16.self)))
                    case 4: indices.append(raw.load(fromByteOffset: offset, as: UInt32.self))
                    default: break
                    }
                }
            }
        }
        return indices
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
        // than a mid-green, which sat at almost the same luminance as the background
        // and flattened facet-to-facet shading differences. Kept a touch darker than the
        // backdrop with a real specular highlight, so curvature and small features read
        // as shaded surfaces rather than as one flat silhouette.
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.56, green: 0.60, blue: 0.66, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.55, alpha: 1.0)
        mat.shininess = 0.28
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
        // An explicit depth range sized to the part, not SceneKit's default
        // `zNear = 1` / `zFar = 100`. The camera is placed at `2.4 × modelDim`, so with
        // the defaults every part larger than roughly 40 units sits entirely behind the
        // far plane: nothing draws but the odd near sliver, which is what "看不清轮廓"
        // looks like from the outside — a rendering failure mistaken for a bad model.
        //
        // `automaticallyAdjustsZRange` is deliberately NOT relied on, even though it is
        // the obvious tool for this. It does not survive interaction: SceneKit documents
        // that writing either `zNear` or `zFar` resets `automaticallyAdjustsZRange` to
        // false, and `allowsCameraControl`'s own controller writes both as the user
        // pinches and dollies. The safety net therefore turns itself off the moment the
        // user starts working, dropping the range back to the defaults mid-inspection.
        // Values derived from the part stay correct for the whole session.
        camera.automaticallyAdjustsZRange = false
        // A ratio of 400 between the planes keeps enough depth precision that the edge
        // overlay — inflated by only 0.15% — is never swamped by quantisation and left
        // z-fighting with the surface it sits on. The near plane is 40× closer than the
        // nearest surface, so dollying in to inspect a feature cannot clip it away.
        camera.zNear = Double(max(cameraDistance * 0.02, 0.001))
        camera.zFar = Double(cameraDistance * 8)
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
        //
        // Intensities are deliberately well under the previous 1100/450/320. Those sums
        // drove a fully-lit face to roughly 0.97 — brighter than the 0.91 backdrop — so
        // the model's lit side dissolved into the background and the silhouette vanished
        // exactly where the light hit it. Kept near 0.6 the lit side stays clearly darker
        // than the backdrop while the unlit side still falls off to near-black, which is
        // the contrast that makes form and small features readable.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 700
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(cameraDistance * 0.6, cameraDistance, cameraDistance * 0.6)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 280
        fillLight.color = UIColor(white: 0.85, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-cameraDistance * 0.7, cameraDistance * 0.25, cameraDistance * 0.5)
        fillNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 190
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

    func handleTap(screenPoint: CGPoint, in view: SCNView) {
        guard mode == .measure else { return }
        // Volume and the bounding box are properties of the whole model, so a tap means
        // nothing for them. Without this the tap would append a pick the measurement
        // never asked for and drop the result panel back to the "in progress" state.
        guard requiredPickCount > 0 else { return }
        guard let pick = resolvePick(at: screenPoint, in: view) else { return }
        commitPick(pick, in: view)
    }

    // MARK: - Preselect

    /// Reports the entity under the finger while a press-and-hold is in progress.
    ///
    /// Nothing is committed here: this exists so the entity about to be measured can be
    /// highlighted first. Every mainstream CAD application keeps preselection and
    /// selection as two distinct states because a face picked by eye on a phone is easy
    /// to get wrong, and without a preview the mistake only surfaces after committing.
    func handlePreview(screenPoint: CGPoint, in view: SCNView) {
        guard mode == .measure else { return }
        // Nothing to preselect when the measurement takes no pick (volume, bounding box).
        guard requiredPickCount > 0 else { return }

        // A `changed` event that has not moved the finger meaningfully cannot resolve to
        // a different entity, and the pick — a kernel ray cast — is the expensive part.
        if let last = lastPreviewTouch {
            let dx = screenPoint.x - last.x
            let dy = screenPoint.y - last.y
            if dx * dx + dy * dy < 25 { return }
        }
        lastPreviewTouch = screenPoint

        guard let pick = resolvePick(at: screenPoint, in: view) else {
            clearPreview()
            return
        }

        // Skip the rebuild when the highlight would not change: a drag across one face
        // fires many updates, and each one re-highlights.
        if pick.entity == previewEntity, let current = previewPoint,
           Self.distance(current, pick.point) < max(modelDim, 1) * 0.001 {
            return
        }

        previewPoint = pick.point
        previewEntity = pick.entity
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
        commitPick(Pick(point: point, entity: entity), in: view)
    }

    /// Drops the preselect highlight without committing anything.
    func clearPreview() {
        previewPoint = nil
        previewEntity = nil
        lastPreviewTouch = nil
        previewGroup?.removeFromParentNode()
        previewGroup = nil
        previewFaceNode?.removeFromParentNode()
        previewFaceNode = nil
        previewEdgeNode?.removeFromParentNode()
        previewEdgeNode = nil
    }

    /// Shared commit for both interaction paths — a quick tap and the release of a
    /// press-and-hold — so the two can never diverge in how they fill the list.
    private func commitPick(_ pick: Pick, in view: SCNView) {
        if picks.count >= requiredPickCount {
            picks = [pick]
        } else {
            picks.append(pick)
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

    /// Name of the entity currently under the finger, if any.
    var previewEntityName: String? {
        previewEntity?.description
    }

    // MARK: - Picking

    /// Resolves a screen point to a topological entity.
    ///
    /// The kernel does the work: a ray is built from the live SceneKit camera and cast
    /// against the loaded `Shape` with `Shape.raycast`. That is what makes taps
    /// reliable — it intersects the *B-rep surfaces*, so a face is found no matter how
    /// its tessellation happens to be wound, whereas SceneKit's own hit test culls
    /// back-facing triangles and silently answers nothing for a face wound the other
    /// way. It also returns the face index directly, so the face association no longer
    /// depends on reproducing SceneKit's triangle ordering.
    ///
    /// A tap that lands near an edge or a vertex is snapped to it, exactly as a CAD
    /// cursor would, by measuring against the edge and vertex caches in world space and
    /// confirming the candidate on screen. Anything else resolves to the face under the
    /// tap.
    private func resolvePick(at screenPoint: CGPoint, in view: SCNView) -> Pick? {
        guard modelNode != nil else { return nil }

        var surfacePoint: SCNVector3?
        var surfaceEntity: PickEntity?

        if isBrep, let shape, let ray = rayThrough(screenPoint, in: view) {
            if let hit = raycastHit(shape: shape, ray: ray) {
                surfacePoint = hit.point
                surfaceEntity = .face(hit.faceIndex)
            }
        }

        // Fallback for an STL import (no kernel topology to cast against) and for the
        // rare graze the ray cast declines. `backFaceCulling` is switched off here for
        // the same reason the ray cast exists: a triangle wound away from the camera is
        // still a surface the user can see and tap.
        if surfacePoint == nil, let hit = sceneKitHit(at: screenPoint, in: view) {
            surfacePoint = hit.point
            surfaceEntity = hit.entity
        }

        guard let surfacePoint else { return nil }

        // Vertex first, then edge: the more specific entity wins when both are within
        // reach, which is the order every CAD cursor resolves a corner.
        if let vertex = nearestVertex(to: screenPoint, near: surfacePoint, in: view) {
            return Pick(point: vertex.position, entity: .vertex(vertex.index))
        }
        if let edge = nearestEdge(to: screenPoint, near: surfacePoint, in: view) {
            return Pick(point: edge.point, entity: .edge(edge.edgeIndex))
        }
        return Pick(point: surfacePoint, entity: surfaceEntity ?? .freePoint)
    }

    /// Casts the pick ray against the kernel shape, returning the nearest hit point in
    /// world space and the B-rep face index it belongs to.
    private func raycastHit(shape: OCCTSwift.Shape,
                            ray: (origin: SCNVector3, direction: SCNVector3))
        -> (point: SCNVector3, faceIndex: Int)? {
        guard let modelNode else { return nil }

        let localOrigin = modelNode.convertPosition(ray.origin, from: nil)
        let localDirection = modelNode.convertVector(ray.direction, from: nil)

        // Tolerance scales with the part. An absolute value would either sit below the
        // kernel's own resolution on a large model or swallow whole small features on a
        // tiny one, and either way the ray/surface solver starts failing to converge on
        // some faces — which surfaces as "this face does not respond to a tap" rather
        // than as a tolerance problem. 1e-5 of the model's extent keeps the intersection
        // solver comfortable (it is the library's own default at unit scale) while
        // staying far below any feature a user would try to tap.
        let tolerance = max(Double(modelDim) * 1e-5, 1e-6)
        guard let hit = shape.raycastNearest(
            origin: SIMD3(Double(localOrigin.x), Double(localOrigin.y), Double(localOrigin.z)),
            direction: SIMD3(Double(localDirection.x), Double(localDirection.y), Double(localDirection.z)),
            tolerance: tolerance
        ) else { return nil }

        let local = SCNVector3(Float(hit.point.x), Float(hit.point.y), Float(hit.point.z))
        return (modelNode.convertPosition(local, to: nil), hit.faceIndex)
    }

    /// The pick ray through a screen point, in world space.
    ///
    /// Built from the view's own `unprojectPoint` at the near and far planes, so it is
    /// exact by construction for perspective and orthographic cameras alike and cannot
    /// drift out of sync with the rendered view.
    private func rayThrough(_ screenPoint: CGPoint, in view: SCNView)
        -> (origin: SCNVector3, direction: SCNVector3)? {
        let near = view.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 0))
        let far = view.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 1))
        let dx = far.x - near.x, dy = far.y - near.y, dz = far.z - near.z
        let length = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard length > 1e-9 else { return nil }
        return (near, SCNVector3(dx / length, dy / length, dz / length))
    }

    /// SceneKit hit test, used only when the kernel cannot answer (an STL, or a ray the
    /// cast declines).
    private func sceneKitHit(at screenPoint: CGPoint, in view: SCNView)
        -> (point: SCNVector3, entity: PickEntity)? {
        let hits = view.hitTest(screenPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
            .backFaceCulling: false
        ]).filter { $0.node === modelNode }

        guard let cameraPosition = view.pointOfView?.worldPosition else {
            return hits.first.map { ($0.worldCoordinates, faceEntity(for: $0.faceIndex)) }
        }

        var best: (point: SCNVector3, entity: PickEntity)?
        var bestDistance = Float.greatestFiniteMagnitude
        for hit in hits {
            let d = Self.distance(cameraPosition, hit.worldCoordinates)
            if d < bestDistance {
                bestDistance = d
                best = (hit.worldCoordinates, faceEntity(for: hit.faceIndex))
            }
        }
        return best
    }

    /// Maps a SceneKit hit's triangle ordinal onto the B-rep face it was tessellated
    /// from. Only reachable on the fallback path; the ray cast names the face itself.
    private func faceEntity(for triangleIndex: Int?) -> PickEntity {
        guard let triangleIndex, triangleIndex >= 0,
              triangleIndex < triangleToFace.count else { return .freePoint }
        return .face(Int(triangleToFace[triangleIndex]))
    }

    /// Closest vertex to the tap, among those actually near the tapped surface point.
    ///
    /// The 3D pre-filter is what keeps this honest: without it a vertex on the far side
    /// of the part could project into the same screen neighbourhood and steal the pick.
    private func nearestVertex(to screenPoint: CGPoint, near surfacePoint: SCNVector3,
                               in view: SCNView) -> (index: Int, position: SCNVector3)? {
        guard !vertexWorld.isEmpty else { return nil }
        let tolerance = Float(unitsPerPoint(at: surfacePoint, in: view))
            * Float(snapScreenRadius) * 2

        var best: (index: Int, position: SCNVector3)?
        var bestScreen = snapScreenRadius

        for vertex in vertexWorld {
            guard Self.within(vertex.position, surfacePoint, tolerance) else { continue }
            let projected = view.projectPoint(vertex.position)
            guard projected.z >= 0, projected.z <= 1 else { continue }
            let dx = CGFloat(projected.x) - screenPoint.x
            let dy = CGFloat(projected.y) - screenPoint.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestScreen {
                bestScreen = d
                best = vertex
            }
        }
        return best
    }

    /// Closest edge polyline to the tap, within the snap radius.
    ///
    /// Candidates are pre-filtered in 3D against the tapped surface point, so an edge
    /// behind the part can never win on screen distance alone. Only the survivors are
    /// projected, which is what keeps the tap cheap on a part with thousands of edges.
    private func nearestEdge(to screenPoint: CGPoint, near surfacePoint: SCNVector3,
                             in view: SCNView) -> (point: SCNVector3, edgeIndex: Int)? {
        guard !edgeWorldPolylines.isEmpty else { return nil }
        let tolerance = Float(unitsPerPoint(at: surfacePoint, in: view))
            * Float(snapScreenRadius) * 3

        var best: (point: SCNVector3, edgeIndex: Int)?
        var bestDistance = snapScreenRadius

        for entry in edgeWorldPolylines {
            let pts = entry.points
            guard pts.count >= 2 else { continue }
            guard pts.contains(where: { Self.within($0, surfacePoint, tolerance) }) else {
                continue
            }

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

    /// Whether `p` lies within `radius` of `q`, in world units.
    private static func within(_ p: SCNVector3, _ q: SCNVector3, _ radius: Float) -> Bool {
        let dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z
        return dx * dx + dy * dy + dz * dz <= radius * radius
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

    // MARK: - Results

    private func computeResults() {
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil
        areaResult = nil
        volumeResult = nil
        boundingBoxExtents = nil
        closestPointA = nil
        closestPointB = nil
        measureMessage = nil

        guard picks.count == requiredPickCount else { return }

        if isBrep, computeEntityResults() { return }

        switch measureType {
        case .distance, .linear:
            let a = picks[0].point, b = picks[1].point
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            distanceResult = (dx*dx + dy*dy + dz*dz).squareRoot()

        case .angle:
            guard picks.count >= 3 else { return }
            let v1 = SCNVector3(picks[0].point.x - picks[1].point.x,
                                 picks[0].point.y - picks[1].point.y,
                                 picks[0].point.z - picks[1].point.z)
            let v2 = SCNVector3(picks[2].point.x - picks[1].point.x,
                                 picks[2].point.y - picks[1].point.y,
                                 picks[2].point.z - picks[1].point.z)
            let dot = v1.x*v2.x + v1.y*v2.y + v1.z*v2.z
            let m1 = (v1.x*v1.x + v1.y*v1.y + v1.z*v1.z).squareRoot()
            let m2 = (v2.x*v2.x + v2.y*v2.y + v2.z*v2.z).squareRoot()
            guard m1 > 1e-6, m2 > 1e-6 else { return }
            let cosAngle = max(-1, min(1, dot / (m1 * m2)))
            angleResult = acos(cosAngle) * 180 / Float.pi

        case .radius:
            guard picks.count >= 3 else { return }
            if let (center, radius) = Self.circumcircle(
                picks[0].point, picks[1].point, picks[2].point
            ) {
                radiusCenter = center
                radiusResult = radius
            }

        case .area:
            // Reached only without B-rep topology: an STL tap resolves to a bare point,
            // so there is no trimmed surface for the kernel to integrate.
            measureMessage = "面积测量需要点选一个面（仅 STEP 模型支持）"

        case .volume:
            // Answers for a watertight STL too, since the kernel judges closedness
            // topologically rather than from the file format.
            guard let volume = shape?.volume else {
                measureMessage = "该模型不是封闭实体，无法计算体积"
                return
            }
            volumeResult = Float(volume)

        case .boundingBox:
            guard let box = shape?.bounds else { return }
            boundingBoxExtents = SCNVector3(
                Float(abs(box.max.x - box.min.x)),
                Float(abs(box.max.y - box.min.y)),
                Float(abs(box.max.z - box.min.z))
            )
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
        let entities = picks.map(\.entity)
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

        case .area:
            guard let entity = entities.first, case let .face(i) = entity,
                  let face = shape?.face(at: i) else {
                measureMessage = "面积测量需要点选一个面（仅 STEP 模型支持）"
                return true
            }
            // The kernel integrates the trimmed surface, so holes and the outer wire are
            // both accounted for — a bounding-box area would be wrong on any face with a
            // cut-out, which is most of them on a machined part.
            areaResult = Float(face.area())
            return true

        case .volume:
            guard let volume = shape?.volume else {
                measureMessage = "该模型不是封闭实体，无法计算体积"
                return true
            }
            volumeResult = Float(volume)
            return true

        case .boundingBox:
            guard let box = shape?.bounds else { return false }
            boundingBoxExtents = SCNVector3(
                Float(abs(box.max.x - box.min.x)),
                Float(abs(box.max.y - box.min.y)),
                Float(abs(box.max.z - box.min.z))
            )
            return true
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

    // MARK: - Selection list

    /// Removes the most recently picked entity and recomputes.
    func undoLastPoint() {
        guard !picks.isEmpty else { return }
        picks.removeLast()
        computeResults()
        updateMeasureVisuals(in: renderView)
    }

    /// Removes one entity from the selection list and recomputes.
    ///
    /// This is what makes a mis-pick recoverable without restarting the measurement:
    /// the list names every pick, and each one can be dropped on its own.
    func removePick(at index: Int) {
        guard picks.indices.contains(index) else { return }
        picks.remove(at: index)
        computeResults()
        updateMeasureVisuals(in: renderView)
    }

    func selectMeasureType(_ type: MeasureType) {
        measureType = type
        clearMeasure()
        // Volume and the bounding box need no pick, so selecting the type is the whole
        // interaction — but `clearMeasure` has just wiped the results, so they have to
        // be recomputed here or the panel would show "--" until something else ran.
        computeResults()
    }

    func clearMeasure() {
        picks = []
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil
        areaResult = nil
        volumeResult = nil
        boundingBoxExtents = nil
        closestPointA = nil
        closestPointB = nil
        measureMessage = nil
        measureGroup?.removeFromParentNode()
        measureGroup = nil
        clearHighlightNodes()
    }

    /// Changes the display unit and remembers it, so `SettingsView` and the viewer
    /// toolbar stay in agreement across launches.
    func setUnit(_ unit: DisplayUnit) {
        displayUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: "defaultUnit")
    }

    func toggleMeasureMode() {
        mode = mode == .measure ? .orbit : .measure
        if mode == .orbit {
            clearMeasure()
        } else {
            // Entering measure mode with a whole-model type already selected (volume,
            // bounding box) has to produce its value straight away, since there is no
            // pick to wait for.
            computeResults()
        }
    }

    // MARK: - Visuals

    /// Applies the current display mode to the live scene.
    ///
    /// Only material and visibility are touched — never the geometry — so switching modes
    /// is instant and nothing is re-tessellated.
    private func applyDisplayMode() {
        guard let material = modelNode?.geometry?.firstMaterial else { return }
        let edges = scene?.rootNode.childNode(withName: "edges", recursively: true)

        // Filled is the norm; only the STL wireframe fallback below wants `.lines`, and
        // starting from `.fill` means switching away from it can never leave the surface
        // drawn as a mesh of hairlines.
        material.fillMode = .fill

        switch displayMode {
        case .shaded:
            material.transparency = 1
            material.writesToDepthBuffer = true
            edges?.isHidden = true

        case .shadedWithEdges:
            material.transparency = 1
            material.writesToDepthBuffer = true
            edges?.isHidden = false

        case .transparent:
            // Translucent rather than cut away, so an internal bore or rib is visible
            // through the wall without sectioning the part.
            //
            // The surface stops writing depth, which is what makes the mode do anything:
            // with depth writes left on, the front wall the user is looking through would
            // still reject every interior face and edge behind it, and the part would just
            // look like frosted glass with nothing visible inside.
            material.transparency = 0.3
            material.writesToDepthBuffer = false
            edges?.isHidden = false

        case .wireframe:
            if edges != nil {
                // A real CAD wireframe: the B-rep edges only, not the triangulation. The
                // surface is made fully transparent *and* stops writing depth rather than
                // being hidden, because the edge geometry is a child of this node — hiding
                // the node would take the wireframe with it.
                material.transparency = 0
                material.writesToDepthBuffer = false
                edges?.isHidden = false
            } else {
                // An STL carries no B-rep edges, so the triangulation is the only wireframe
                // there is to draw; leaving the surface opaque keeps it readable.
                material.transparency = 1
                material.writesToDepthBuffer = true
                material.fillMode = .lines
            }
        }
    }

    /// How a picked face is tinted. Preselect and committed picks are deliberately
    /// different colours: yellow still means "lift now to take this one", teal means
    /// "this one is already part of the measurement".
    @MainActor
    private enum FaceHighlightStyle: String {
        case preview
        case measure

        var color: UIColor {
            switch self {
            case .preview: return .systemYellow
            case .measure: return .systemTeal
            }
        }

        var transparency: CGFloat {
            switch self {
            case .preview: return 0.45
            case .measure: return 0.35
            }
        }
    }

    private func clearHighlightNodes() {
        measureFaceGroup?.removeFromParentNode()
        measureFaceGroup = nil
        measureEdgeNode?.removeFromParentNode()
        measureEdgeNode = nil
    }

    /// Rebuilds the highlights for the committed picks and the preselect.
    ///
    /// A dot marks *where* on a face the finger landed, which is enough for a vertex or
    /// an edge but tells the user almost nothing about which of a part's faces was
    /// actually taken — the failure mode the preselect exists to prevent. Tinting the
    /// whole face is what makes the pick unambiguous, and drawing the picked edge is
    /// what does the same for a wireframe pick.
    private func updateSelectionHighlights() {
        clearHighlightNodes()
        previewFaceNode?.removeFromParentNode()
        previewFaceNode = nil
        previewEdgeNode?.removeFromParentNode()
        previewEdgeNode = nil

        guard isBrep, let modelNode else { return }
        let inflate = max(modelDim, 1) * 0.0015

        var pickedFaces: [Int] = []
        var pickedEdges: [Int] = []
        for pick in picks {
            switch pick.entity {
            case .face(let i) where !pickedFaces.contains(i):
                pickedFaces.append(i)
            case .edge(let i) where !pickedEdges.contains(i):
                pickedEdges.append(i)
            default:
                break
            }
        }

        if !pickedFaces.isEmpty {
            let group = SCNNode()
            group.name = "measure_face_group"
            for i in pickedFaces {
                guard let geo = faceOverlayGeometry(faceIndex: i, style: .measure,
                                                    inflate: inflate) else { continue }
                let node = SCNNode(geometry: geo)
                // Drawn after the model and the wireframe so the tint reads as a
                // coverage of the face rather than being buried by the shaded surface.
                node.renderingOrder = 10
                group.addChildNode(node)
            }
            if !group.childNodes.isEmpty {
                modelNode.addChildNode(group)
                measureFaceGroup = group
            }
        }

        if !pickedEdges.isEmpty, let geo = edgeHighlightGeometry(edgeIndices: pickedEdges) {
            let node = SCNNode(geometry: geo)
            node.renderingOrder = 12
            scene?.rootNode.addChildNode(node)
            measureEdgeNode = node
        }

        // The preselect is skipped when it is already a committed pick, which would
        // otherwise stack two translucent layers on the same face and darken it.
        if case .face(let i) = previewEntity, !pickedFaces.contains(i),
           let geo = faceOverlayGeometry(faceIndex: i, style: .preview, inflate: inflate) {
            let node = SCNNode(geometry: geo)
            node.renderingOrder = 11
            modelNode.addChildNode(node)
            previewFaceNode = node
        } else if case .edge(let i) = previewEntity, !pickedEdges.contains(i),
                  let geo = edgeHighlightGeometry(edgeIndices: [i]) {
            let node = SCNNode(geometry: geo)
            node.renderingOrder = 12
            scene?.rootNode.addChildNode(node)
            previewEdgeNode = node
        }
    }

    /// Bright polyline over the given edges, lifted a hair off the surface.
    ///
    /// World space, so the lift is a scale about the model's own centre — the model is
    /// recentred on the origin at load, which makes that a uniform outward nudge.
    private func edgeHighlightGeometry(edgeIndices: [Int]) -> SCNGeometry? {
        let wanted = Set(edgeIndices)
        var positions: [SCNVector3] = []

        for entry in edgeWorldPolylines where wanted.contains(entry.edgeIndex) {
            let pts = entry.points
            guard pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) {
                positions.append(Self.lifted(pts[i]))
                positions.append(Self.lifted(pts[i + 1]))
            }
        }

        guard positions.count >= 2 else { return nil }

        let source = SCNGeometrySource(vertices: positions)
        let indices = positions.indices.map { UInt32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.65)
        material.lightingModel = .constant
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geo.materials = [material]
        return geo
    }

    private static func lifted(_ p: SCNVector3) -> SCNVector3 {
        let k: Float = 1.0025
        return SCNVector3(p.x * k, p.y * k, p.z * k)
    }

    private func faceOverlayGeometry(faceIndex: Int, style: FaceHighlightStyle,
                                     inflate: Float) -> SCNGeometry? {
        let key = "\(style.rawValue)-\(faceIndex)"
        if let cached = faceOverlayCache[key] { return cached }
        guard let geo = buildFaceOverlayGeometry(faceIndex: faceIndex, inflate: inflate,
                                                 style: style) else { return nil }
        faceOverlayCache[key] = geo
        return geo
    }

    /// Re-emits one B-rep face's triangles as a translucent patch, lifted a hair off the
    /// shaded surface so it does not fight the model for the same depth.
    ///
    /// Each triangle is offset along its own normal rather than scaled about the model
    /// centre: a pocket floor faces inwards, where a radial push would bury the tint
    /// inside the part instead of lifting it clear of the surface.
    private func buildFaceOverlayGeometry(faceIndex: Int, inflate: Float,
                                          style: FaceHighlightStyle) -> SCNGeometry? {
        let triangleCount = modelTriangleIndices.count / 3
        let vertexCount = modelVertices.count
        guard triangleCount > 0, vertexCount > 0 else { return nil }

        var positions: [SCNVector3] = []
        positions.reserveCapacity(96)

        for t in 0..<triangleCount {
            guard t < triangleToFace.count,
                  Int(triangleToFace[t]) == faceIndex else { continue }
            let i0 = Int(modelTriangleIndices[t * 3])
            let i1 = Int(modelTriangleIndices[t * 3 + 1])
            let i2 = Int(modelTriangleIndices[t * 3 + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }

            let a = modelVertices[i0], b = modelVertices[i1], c = modelVertices[i2]
            let n = Self.triangleNormal(a, b, c)
            let ox = n.x * inflate, oy = n.y * inflate, oz = n.z * inflate
            positions.append(SCNVector3(a.x + ox, a.y + oy, a.z + oz))
            positions.append(SCNVector3(b.x + ox, b.y + oy, b.z + oz))
            positions.append(SCNVector3(c.x + ox, c.y + oy, c.z + oz))
        }

        guard positions.count >= 3 else { return nil }

        let source = SCNGeometrySource(vertices: positions)
        let indices = positions.indices.map { UInt32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = style.color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = style.transparency
        // Over the surface beneath it, but never occluding anything else: the patch is
        // coplanar with the face it covers, so it must not write depth.
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geo.materials = [material]
        return geo
    }

    private static func triangleNormal(_ a: SCNVector3, _ b: SCNVector3,
                                       _ c: SCNVector3) -> SCNVector3 {
        let ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
        let vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
        guard len > 1e-9 else { return SCNVector3(0, 0, 0) }
        return SCNVector3(nx / len, ny / len, nz / len)
    }

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

        // The dot and label say *where* the finger is; this tints the whole face (or
        // traces the edge) it resolved to, which is the part that is easy to get wrong
        // by eye.
        updateSelectionHighlights()
    }

    /// Rebuilds the measurement annotations.
    ///
    /// Marker, line and label sizes are derived from the live camera through
    /// `unitsPerPoint(at:in:)`, so they hold a constant size on screen instead of an
    /// arbitrary fraction of the model's bounding box.
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

        for (i, pick) in picks.enumerated() {
            addMarker(at: pick.point, entity: pick.entity, index: i,
                      radius: markerRadius, to: group)
        }

        // When the kernel supplied its own witness points, draw the measured segment
        // between *those* — for two faces or two edges the true minimum is generally
        // nowhere near the tapped positions, and joining the taps would depict a
        // distance longer than the one being reported.
        if let a = closestPointA, let b = closestPointB {
            addCylinderLine(from: a, to: b, lineRadius: lineRadius, to: group)
            addMarker(at: a, entity: .freePoint, index: -1,
                      radius: markerRadius * 0.7, to: group, showTag: false)
            addMarker(at: b, entity: .freePoint, index: -1,
                      radius: markerRadius * 0.7, to: group, showTag: false)
        } else if picks.count >= 2 {
            for i in 0..<picks.count-1 {
                addCylinderLine(from: picks[i].point, to: picks[i+1].point,
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

            addCylinderLine(from: center, to: picks[0].point,
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

        // Last, and outside `group`: the whole-face tint lives in the model's local
        // space while the picked-edge trace lives in world space, whereas every
        // annotation above is in world space.
        updateSelectionHighlights()
    }

    private func addMarker(at point: SCNVector3, entity: PickEntity, index: Int,
                           radius markerRadius: Float, to group: SCNNode,
                           showTag: Bool = true) {
        let color = entity.markerColor

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
        case .area:
            guard let a = areaResult else { return nil }
            return displayUnit.formatArea(a)
        case .volume, .boundingBox:
            // Both describe the whole model rather than a place on it, and neither has an
            // anchor point to hang a label from — the reading belongs in the result panel.
            return nil
        }
    }

    private func labelAnchor() -> SCNVector3? {
        guard !picks.isEmpty else { return nil }
        if picks.count == 1 { return picks[0].point }
        let sum = picks.dropFirst().reduce(picks[0].point) {
            SCNVector3($0.x + $1.point.x, $0.y + $1.point.y, $0.z + $1.point.z)
        }
        let n = Float(picks.count)
        return SCNVector3(sum.x/n, sum.y/n, sum.z/n)
    }
}
