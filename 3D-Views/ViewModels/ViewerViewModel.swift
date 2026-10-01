//
//  ViewerViewModel.swift
//  3D-Views
//

import Foundation
import SceneKit
import SwiftUI
import simd
import OCCTSwift
import os

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

    /// Marker colour: red holds a plain surface point, orange a snapped vertex (the
    /// cube's colour as well, so silhouette and hue both say "exact snap"), green an
    /// edge, teal a face.
    var markerColor: UIColor {
        switch self {
        case .freePoint: return .systemRed
        case .vertex: return .systemOrange
        case .edge: return .systemGreen
        case .face: return .systemTeal
        }
    }

    /// True when the pick snapped to an actual vertex rather than landing on a
    /// surface — such picks are drawn square (see `markerGeometry`).
    var isVertex: Bool {
        if case .vertex = self { return true }
        return false
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

/// Which of the three distances an entity-to-entity measurement reports.
///
/// The kernel only ever answers the *minimum* question. `ShapeDistance` wraps
/// `BRepExtrema_DistShapeShape`, whose `Value` the OCCT docs define as the minimum
/// distance, and every other way into OCCT's extrema family that OCCTSwift exposes
/// (`faceFaceExtrema`, `edgeEdgeExtrema`, `allDistanceSolutions`) enumerates minima as
/// well — there is no farthest-point query anywhere in the library. So only ``min`` is
/// exact; the other two are assembled in the view model, and both are approximations.
enum DistanceMode: String, CaseIterable, Identifiable {
    /// Distance between the two entities' own axes — a circle's centre line, or a
    /// cylinder's surface axis. Measured axis to axis, so two concentric features read 0
    /// even when they sit at different heights on the shared axis.
    case center
    /// The kernel's closest approach. Exact.
    case min
    /// The farthest pair of points on the two entities, searched over sampled point
    /// sets. An approximation, and the only one of the three the kernel cannot confirm.
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: return "中心距"
        case .min: return "最小距离"
        case .max: return "最大距离"
        }
    }
}

/// One finished measurement, kept on screen after the next one begins.
///
/// The single-measurement model forced a costly either/or: start a new distance and
/// the old one — the only record of what was already measured — vanished. A list of
/// persistent annotations is what every desktop CAD package does instead, and it is
/// what makes the feature worth anything on a real part, where the answer is never
/// one number but a handful of them ("bore ⌀, depth, boss-to-boss") read off one view.
///
/// The annotation node is owned by the item: it stays in the scene for as long as the
/// item does, and `clearAllMeasurements` is what takes the whole set down.
struct MeasurementItem: Identifiable {
    let id = UUID()
    let type: MeasureType
    let picks: [Pick]
    /// The formatted primary reading, ready to show as-is (unit included).
    let valueText: String
    /// The world-space annotation group this item owns, if it drew one.
    let node: SCNNode?
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

    /// The camera frame this preset should end on, as an orientation in the model's frame.
    ///
    /// The camera starts on +Z looking back at the origin, so these are the rotations that
    /// carry that frame to the named view. Worth spelling out in full rather than going
    /// through an azimuth/elevation pair: a frame names 俯视图 and 仰视图 *exactly*,
    /// whereas the angle pair could only ever approach them — the clamp that kept its
    /// cross product off zero held those two views a fraction of a degree short, and
    /// that was the same clamp that made a horizontal drag stop responding up there.
    var cameraOrientation: simd_quatf {
        switch self {
        case .front:
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        case .back:
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        case .left:
            return simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        case .right:
            return simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0))
        case .top:
            return simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        case .bottom:
            return simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        case .iso:
            return simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: 0.615, axis: SIMD3<Float>(1, 0, 0))
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
    /// Standard of measurement, and therefore the number the reading card names.
    ///
    /// The diameter is the default the panel shows, so the label reads 直径; the card
    /// still carries a 半径/直径 switch for the times a radius is what is wanted.
    var label: String {
        switch self {
        case .distance: return "距离"
        case .angle: return "角度"
        case .radius: return "直径"
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
        // A double-headed arrow, not the "diameter" glyph the type was first given:
        // that symbol is newer than this app's floor and renders as nothing at all on
        // the devices it was tried on, which reads as a broken button rather than a
        // missing one. This is the same arrow the 半径/直径 switch uses, so the two
        // controls that mean "diameter" also look alike.
        case .radius: return "arrow.left.and.right"
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

    /// Measurements that have all their picks and now live on the model.
    ///
    /// Each entry keeps its own annotation node, so the list is also the authority on
    /// what is drawn: dropping an entry takes its node with it, and the nodes survive
    /// leaving measure mode — which is the point, since the readings are usually
    /// checked while orbiting the part afterwards.
    @Published var measurements: [MeasurementItem] = []

    /// Whether the finished measurements' annotations are drawn. Toggled from the
    /// orbit-mode toolbar, where hiding them all is the quick way back to a clean view.
    @Published var annotationsVisible = true

    /// Non-fatal explanation shown under the result, e.g. why an angle can't be formed.
    @Published var measureMessage: String?

    /// Which of the three distances an entity-to-entity measurement reports.
    ///
    /// Unlike the radius/diameter switch in the result panel, this is not two ways of
    /// writing down one reading: centre distance and maximum distance are different
    /// computations from the kernel's closest approach, so this belongs to the model
    /// rather than the view, and changing it re-derives the result.
    ///
    /// Defaults to ``DistanceMode/center``: on a part the question is nearly always
    /// "how far apart are these two centres" — a bore to a bore, a boss to a boss —
    /// and the minimum distance between two picked faces is more often a wall
    /// thickness the user did not ask about.
    @Published var distanceMode: DistanceMode = .center {
        didSet {
            guard oldValue != distanceMode else { return }
            computeResults()
            updateMeasureVisuals(in: renderView)
        }
    }

    @Published var distanceResult: Float?
    @Published var angleResult: Float?
    @Published var radiusResult: Float?
    @Published var radiusCenter: SCNVector3?

    /// Whether a radius reading is stated as its diameter.
    ///
    /// This looks like the pure presentation the ``distanceMode`` comment above says
    /// does not belong here, and it was first written as a `@State` in the view for
    /// exactly that reason. That was wrong: the same reading is written down in three
    /// places — the result card, the label pinned to the geometry in the scene, and
    /// the history entry — and a view-side flag could only ever reach the first, so
    /// the card said 直径 while the model still floated the raw radius. Keeping it on
    /// the model is what makes the three agree.
    ///
    /// Diameter is the default: a bore is ordered, drilled and inspected by its
    /// diameter, so the radius is the rarer thing to want and the one that has to be
    /// asked for. Unlike ``distanceMode`` this only restates one number, so it
    /// re-draws the annotations without re-deriving anything from the kernel.
    @Published var radiusShowsDiameter: Bool = true {
        didSet {
            guard oldValue != radiusShowsDiameter else { return }
            updateMeasureVisuals(in: renderView)
        }
    }

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

    /// Hands the renderer the scene's own camera.
    ///
    /// SceneKit is deliberately *not* asked to manage the camera (`allowsCameraControl`
    /// stays off — see `SceneView`): its camera controller installs a camera of its own
    /// with `zNear = 1` / `zFar = 100` and discards everything `buildScene` configured.
    /// At `2.4 × modelDim` any part larger than a few dozen units then sits behind the
    /// far plane, so nothing but a near sliver draws — a model whose outline cannot be
    /// made out at all. It also re-installs that camera every time the flag is toggled,
    /// so even reclaiming the point of view only holds until the next gesture.
    ///
    /// Keeping the point of view on the scene camera means the depth range, the field of
    /// view and the orbital state below are the only things that ever decide what is
    /// drawn. This runs after the scene is handed to the view, which is when the renderer
    /// has a point of view to hand over.
    func claimPointOfView(in view: SCNView, scene: SCNScene) {
        renderView = view
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        // Framing needs the viewport, which only exists once the scene has been handed
        // over, so the fit is solved here rather than at load.
        applyInitialFraming(in: view)
    }

    /// Screen-space snap radius, in points. 14 pt is a comfortable touch target on
    /// iPhone and iPad alike, and it is the same tolerance for edges and vertices.
    /// How far (in points) a tap may land from a snappable entity and still take it.
    /// 20 pt sits under an average fingertip: wide enough that a vertex can actually
    /// be hit on a phone, narrow enough not to steal taps meant for the face.
    private let snapScreenRadius: CGFloat = 20

    /// Throttle for the press-and-hold preselect: a `changed` event that has not moved
    /// the finger meaningfully cannot resolve to a different entity, and re-running the
    /// pick is the expensive part of that gesture.
    private var lastPreviewTouch: CGPoint?

    /// Largest model dimension, cached for fallbacks and for camera framing.
    private var modelDim: Float = 10

    /// Radius of a sphere around the part's box, used to frame it. Orientation-independent,
    /// so "zoom to fit" never crops a corner the current view direction brings into shot.
    private var modelRadius: Float = 8

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
                // handful of facets however fine the linear bound is set. 0.06 rad (~3.4°)
                // is the tightness a desktop CAD viewer settles on — enough that a 90° arc
                // on a small hole gets ~26 facets instead of the ~11 the previous 0.15 rad
                // produced, which is what removes the visible faceting on curves.
                params.angle = 0.06
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
            // Half the box diagonal, i.e. a sphere that holds the whole part whichever way
            // it is turned. Framing against this rather than a single side is what keeps a
            // long, flat part from being cropped when the camera happens to look down its
            // length.
            modelRadius = max(0.5 * sqrt(sizeX * sizeX + sizeY * sizeY + sizeZ * sizeZ), 1)
            cameraDistance = modelDim * 2.4
            // A new model invalidates the fit solved for the previous one.
            framedOnce = false

            // Reset the orbital camera to the part's own frame: the same view every time,
            // at a distance that fits it. Without this, a second, differently sized model
            // would inherit the previous one's zoom and end up cropped or a speck.
            cameraOrientation = Self.openingOrientation
            cameraOrbitDistance = cameraDistance
            cameraTarget = SCNVector3(0, 0, 0)

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
            let edgePolylines = brep
                ? (loadedShape?.allEdgePolylinesIndexed(
                    deflection: min(deflection, 0.05), maxPointsPerEdge: 64) ?? [])
                : []

            // Retained before the scene is built, because the outline hull below is cut
            // from this very vertex buffer and the triangle list above it.
            modelVertices = Self.extractVertices(from: geometry)
            modelTriangleIndices = Self.extractTriangleIndices(from: geometry)

            // Sharp edges extracted from the mesh itself. This is the fallback that
            // guarantees feature lines show up even when the B-rep edge query returns
            // nothing for a particular STEP file — the previous builds had no visible
            // edges because `allEdgePolylinesIndexed` came back empty for this model.
            // A triangle edge whose two adjacent faces differ by more than the threshold
            // is a sharp (feature) edge; edges shared smoothly are skipped.
            let meshEdges = Self.makeSharpEdgeGeometry(
                vertices: modelVertices,
                triangles: meshTrianglesWithFaces,
                edgeWidth: Float(max(maxDim * 0.005, 0.005))
            )

            let outlineGeometry = Self.makeOutlineGeometry(
                vertexSource: geometry.sources(for: .vertex).first,
                vertices: modelVertices,
                triangles: meshTrianglesWithFaces
            )

            let built = Self.buildScene(
                geometry: geometry,
                edgeGeometry: meshEdges,
                outlineGeometry: outlineGeometry,
                center: center,
                cameraDistance: cameraDistance
            )
            scene = built
            fileName = url.lastPathComponent

            // Publish the kernel state for entity measurement.
            shape = brep ? loadedShape : nil
            isBrep = brep
            triangleToFace = brep ? meshTrianglesWithFaces.map(\.faceIndex) : []

            // Drop any highlight built for the previous model, including its cached
            // overlay geometry.
            faceOverlayCache.removeAll()
            clearHighlightNodes()

            let mNode = built.rootNode.childNode(withName: "model", recursively: true)
            modelNode = mNode

            if let mNode {
                // B-rep edges are the ideal snap source, but `allEdgePolylinesIndexed`
                // returns empty for some STEP files (this one included). When that
                // happens, fall back to the same mesh sharp-edge extraction used for
                // rendering so vertex/edge snapping still works for point-based
                // measurement.
                let brepEdges = brep ? Self.buildEdgePolylines(edgePolylines, modelNode: mNode) : []
                edgeWorldPolylines = brepEdges.isEmpty
                    ? Self.buildMeshEdgePolylines(
                        vertices: modelVertices,
                        triangles: meshTrianglesWithFaces,
                        modelNode: mNode,
                        sharpAngleDeg: 35)
                    : brepEdges
                // Same fallback for vertices: B-rep vertices first, then the mesh
                // vertices that sit on sharp edges. A tap that cannot snap to a vertex
                // still snaps to a face, so this only needs the corners.
                let brepVerts = brep ? Self.buildVertexWorld(loadedShape, modelNode: mNode) : []
                vertexWorld = brepVerts.isEmpty
                    ? Self.buildMeshVertexWorld(
                        vertices: modelVertices,
                        triangles: meshTrianglesWithFaces,
                        modelNode: mNode,
                        sharpAngleDeg: 35)
                    : brepVerts
            } else {
                edgeWorldPolylines = []
                vertexWorld = []
            }

            clearMeasure()
            // The old scene is gone, so annotations from the previous model have
            // nothing to belong to anymore — drop the history with it.
            clearAllMeasurements()
            annotationsVisible = true

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
        // 0.02 % of the diagonal rather than 0.04 %, because the previous bound left a
        // 20 mm part tessellated at a 0.01 mm chord error that reads as faceting on the
        // screen. The angular bound (0.06 rad) is the real limit on curves, so this only
        // needs to be fine enough not to be the binding constraint, and the upper clamp
        // keeps a multi-metre assembly from spending a minute meshing.
        return min(max(diagonal * 0.0002, 0.005), 0.5)
    }

    // MARK: - Edge geometry

    /// Extracts sharp (feature) edges from the triangle mesh and renders them as
    /// thin rectangular tubes (4-sided prisms), not flat ribbons.
    ///
    /// A flat ribbon disappears when viewed edge-on, which is why edges vanished at
    /// certain angles in the previous build. A tube has thickness in two perpendicular
    /// directions, so it reads from every viewpoint.
    private static func makeSharpEdgeGeometry(
        vertices: [SCNVector3],
        triangles: [OCCTSwift.Triangle],
        edgeWidth: Float,
        sharpAngleDeg: Double = 35
    ) -> SCNGeometry? {
        guard vertices.count >= 3, triangles.count >= 1 else { return nil }

        // Build edge -> [triangle indices] adjacency. An edge key is the sorted pair of
        // vertex indices so (a,b) and (b,a) collapse to the same edge.
        var edgeToFaces: [UInt64: [Int]] = [:]
        for (ti, tri) in triangles.enumerated() {
            let indices = [tri.v1, tri.v2, tri.v3]
            for i in 0..<3 {
                let a = indices[i]
                let b = indices[(i + 1) % 3]
                let key = edgeKey(min(a, b), max(a, b))
                edgeToFaces[key, default: []].append(ti)
            }
        }

        // Precompute triangle normals.
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(triangles.count)
        for tri in triangles {
            let i0 = Int(tri.v1), i1 = Int(tri.v2), i2 = Int(tri.v3)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else {
                normals.append(.zero)
                continue
            }
            let a = SIMD3<Float>(vertices[i0].x, vertices[i0].y, vertices[i0].z)
            let b = SIMD3<Float>(vertices[i1].x, vertices[i1].y, vertices[i1].z)
            let c = SIMD3<Float>(vertices[i2].x, vertices[i2].y, vertices[i2].z)
            let n = simd_cross(b - a, c - a)
            normals.append(simd_length_squared(n) > 0 ? simd_normalize(n) : .zero)
        }

        let cosThreshold = Float(cos(sharpAngleDeg * .pi / 180))
        var positions: [SCNVector3] = []
        var indices: [UInt32] = []
        let up = SIMD3<Float>(0, 1, 0)

        for (key, faceList) in edgeToFaces {
            guard faceList.count == 1 || faceList.count == 2 else { continue }
            if faceList.count == 2 {
                let n0 = normals[faceList[0]]
                let n1 = normals[faceList[1]]
                if simd_length_squared(n0) == 0 || simd_length_squared(n1) == 0 { continue }
                if simd_dot(n0, n1) > cosThreshold { continue }
            }

            let (ai, bi) = unedgeKey(key)
            let aIdx = Int(ai), bIdx = Int(bi)
            guard aIdx < vertices.count, bIdx < vertices.count else { continue }
            let a = SIMD3<Float>(vertices[aIdx].x, vertices[aIdx].y, vertices[aIdx].z)
            let b = SIMD3<Float>(vertices[bIdx].x, vertices[bIdx].y, vertices[bIdx].z)

            var dir = b - a
            let len = simd_length(dir)
            guard len > 1e-9 else { continue }
            dir /= len

            // Two perpendicular directions so the tube has width in both axes of the
            // plane normal to the edge — visible from any angle.
            var perp1 = simd_cross(dir, up)
            if simd_length_squared(perp1) < 1e-6 {
                perp1 = simd_cross(dir, SIMD3<Float>(0, 0, 1))
            }
            perp1 = simd_normalize(perp1)
            let perp2 = simd_normalize(simd_cross(dir, perp1))
            let half = edgeWidth * 0.5

            // 8 corners of the box: a ± perp1*half ± perp2*half, same at b.
            // Corner layout at each end:
            //   0: -perp1 -perp2   1: +perp1 -perp2
            //   2: +perp1 +perp2   3: -perp1 +perp2
            let base = UInt32(positions.count)
            for s1 in [Float(-1), Float(1)] {
                for s2 in [Float(-1), Float(1)] {
                    positions.append(SCNVector3(a + perp1 * (s1 * half) + perp2 * (s2 * half)))
                }
            }
            for s1 in [Float(-1), Float(1)] {
                for s2 in [Float(-1), Float(1)] {
                    positions.append(SCNVector3(b + perp1 * (s1 * half) + perp2 * (s2 * half)))
                }
            }

            // Four side faces of the tube (no end caps). Vertex order per corner above:
            // a-end: 0(-,-), 1(+,-), 2(+,+), 3(-,+) ; b-end: 4(-,-), 5(+,-), 6(+,+), 7(-,+)
            let faces: [(UInt32, UInt32, UInt32, UInt32)] = [
                (0, 1, 5, 4),  // -perp2 side
                (1, 2, 6, 5),  // +perp1 side
                (2, 3, 7, 6),  // +perp2 side
                (3, 0, 4, 7),  // -perp1 side
            ]
            for (v0, v1, v2, v3) in faces {
                indices.append(contentsOf: [base + v0, base + v1, base + v2,
                                             base + v0, base + v2, base + v3])
            }
        }

        guard indices.count >= 3 else { return nil }

        let source = SCNGeometrySource(vertices: positions)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [source], elements: [element])
    }

    /// Packs two vertex indices into one UInt64 edge key.
    private static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        (UInt64(a) << 32) | UInt64(b)
    }

    /// Unpacks an edge key back into (minIndex, maxIndex).
    private static func unedgeKey(_ key: UInt64) -> (UInt32, UInt32) {
        (UInt32(key >> 32), UInt32(key & 0xFFFFFFFF))
    }

    /// A copy of the shaded mesh, black, used to draw the part's outline.
    ///
    /// This is the reverse-hull outline the sharper viewers all end up with: draw the
    /// same solid again, very slightly larger, with front faces culled and no lighting, so
    /// only the far shell survives the depth test and it peeks out as a dark rim exactly
    /// along the silhouette. A thin dark line is the one thing a shaded surface cannot
    /// supply on its own — where a lit face happens to match the backdrop there is no
    /// gradient to mark the boundary — and it is what "看不清轮廓" is really asking for.
    ///
    /// The vertices are shared with the shaded geometry rather than duplicated; only a
    /// new index buffer is built, for the reason in the winding note below.
    ///
    /// `cullMode = .front` keeps the far side *only if* the triangles are wound
    /// outward-CCW. The kernel's per-triangle normal is the reference for that, so each
    /// triangle whose geometric normal disagrees with it is emitted with its last two
    /// vertices swapped. Without this the culling would keep the near shell instead, and
    /// the whole part would render as a solid black silhouette rather than an outline.
    static func makeOutlineGeometry(
        vertexSource: SCNGeometrySource?,
        vertices: [SCNVector3],
        triangles: [OCCTSwift.Triangle]
    ) -> SCNGeometry? {
        guard let vertexSource, !vertices.isEmpty, !triangles.isEmpty else { return nil }

        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)

        for triangle in triangles {
            let i0 = Int(triangle.v1)
            let i1 = Int(triangle.v2)
            let i2 = Int(triangle.v3)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let a = vertices[i0]
            let b = vertices[i1]
            let c = vertices[i2]
            let ab = SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)
            let ac = SIMD3<Float>(c.x - a.x, c.y - a.y, c.z - a.z)
            let geometric = simd_cross(ab, ac)

            // A degenerate triangle or a missing normal leaves the winding as it came;
            // there is no reliable reference to correct it against.
            if simd_length_squared(geometric) > 0,
               simd_length_squared(triangle.normal) > 0,
               simd_dot(geometric, triangle.normal) < 0 {
                indices.append(triangle.v1)
                indices.append(triangle.v3)
                indices.append(triangle.v2)
            } else {
                indices.append(triangle.v1)
                indices.append(triangle.v2)
                indices.append(triangle.v3)
            }
        }

        guard indices.count >= 3 else { return nil }

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertexSource], elements: [element])
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

    /// Builds snap polylines from the mesh's sharp edges when B-rep edges are absent.
    ///
    /// Uses the same dihedral-angle test as `makeSharpEdgeGeometry` so the snap targets
    /// line up with the drawn edges. Each sharp segment becomes a two-point polyline;
    /// the index is a synthetic sequential number (not a B-rep edge index), so it only
    /// supports point-based measurement, not entity edge measurement.
    private static func buildMeshEdgePolylines(
        vertices: [SCNVector3],
        triangles: [OCCTSwift.Triangle],
        modelNode: SCNNode,
        sharpAngleDeg: Double = 35
    ) -> [(edgeIndex: Int, points: [SCNVector3])] {
        guard vertices.count >= 3, triangles.count >= 1 else { return [] }

        var edgeToFaces: [UInt64: [Int]] = [:]
        for (ti, tri) in triangles.enumerated() {
            let idx = [tri.v1, tri.v2, tri.v3]
            for i in 0..<3 {
                let key = edgeKey(min(idx[i], idx[(i + 1) % 3]),
                                  max(idx[i], idx[(i + 1) % 3]))
                edgeToFaces[key, default: []].append(ti)
            }
        }

        var normals: [SIMD3<Float>] = []
        for tri in triangles {
            let i0 = Int(tri.v1), i1 = Int(tri.v2), i2 = Int(tri.v3)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else {
                normals.append(.zero); continue
            }
            let a = SIMD3<Float>(vertices[i0].x, vertices[i0].y, vertices[i0].z)
            let b = SIMD3<Float>(vertices[i1].x, vertices[i1].y, vertices[i1].z)
            let c = SIMD3<Float>(vertices[i2].x, vertices[i2].y, vertices[i2].z)
            let n = simd_cross(b - a, c - a)
            normals.append(simd_length_squared(n) > 0 ? simd_normalize(n) : .zero)
        }

        let cosThreshold = Float(cos(sharpAngleDeg * .pi / 180))
        var result: [(edgeIndex: Int, points: [SCNVector3])] = []
        var edgeIndex = 0

        for (key, faceList) in edgeToFaces {
            guard faceList.count == 1 || faceList.count == 2 else { continue }
            if faceList.count == 2 {
                let n0 = normals[faceList[0]], n1 = normals[faceList[1]]
                if simd_length_squared(n0) == 0 || simd_length_squared(n1) == 0 { continue }
                if simd_dot(n0, n1) > cosThreshold { continue }
            }
            let (ai, bi) = unedgeKey(key)
            let aIdx = Int(ai), bIdx = Int(bi)
            guard aIdx < vertices.count, bIdx < vertices.count else { continue }
            let a = vertices[aIdx], b = vertices[bIdx]
            let wa = modelNode.convertPosition(a, to: nil)
            let wb = modelNode.convertPosition(b, to: nil)
            result.append((edgeIndex: edgeIndex, points: [wa, wb]))
            edgeIndex += 1
        }
        return result
    }

    /// Collects mesh vertices that lie on sharp edges, for vertex snapping when B-rep
    /// vertices are unavailable.
    private static func buildMeshVertexWorld(
        vertices: [SCNVector3],
        triangles: [OCCTSwift.Triangle],
        modelNode: SCNNode,
        sharpAngleDeg: Double = 35
    ) -> [(index: Int, position: SCNVector3)] {
        guard vertices.count >= 3, triangles.count >= 1 else { return [] }

        var edgeToFaces: [UInt64: [Int]] = [:]
        for (ti, tri) in triangles.enumerated() {
            let idx = [tri.v1, tri.v2, tri.v3]
            for i in 0..<3 {
                let key = edgeKey(min(idx[i], idx[(i + 1) % 3]),
                                  max(idx[i], idx[(i + 1) % 3]))
                edgeToFaces[key, default: []].append(ti)
            }
        }

        var normals: [SIMD3<Float>] = []
        for tri in triangles {
            let i0 = Int(tri.v1), i1 = Int(tri.v2), i2 = Int(tri.v3)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else {
                normals.append(.zero); continue
            }
            let a = SIMD3<Float>(vertices[i0].x, vertices[i0].y, vertices[i0].z)
            let b = SIMD3<Float>(vertices[i1].x, vertices[i1].y, vertices[i1].z)
            let c = SIMD3<Float>(vertices[i2].x, vertices[i2].y, vertices[i2].z)
            let n = simd_cross(b - a, c - a)
            normals.append(simd_length_squared(n) > 0 ? simd_normalize(n) : .zero)
        }

        let cosThreshold = Float(cos(sharpAngleDeg * .pi / 180))
        var usedIndices = Set<UInt32>()
        for (key, faceList) in edgeToFaces {
            guard faceList.count == 1 || faceList.count == 2 else { continue }
            if faceList.count == 2 {
                let n0 = normals[faceList[0]], n1 = normals[faceList[1]]
                if simd_length_squared(n0) == 0 || simd_length_squared(n1) == 0 { continue }
                if simd_dot(n0, n1) > cosThreshold { continue }
            }
            let (ai, bi) = unedgeKey(key)
            usedIndices.insert(ai)
            usedIndices.insert(bi)
        }

        var result: [(index: Int, position: SCNVector3)] = []
        for (i, v) in vertices.enumerated() where usedIndices.contains(UInt32(i)) {
            result.append((index: i, position: modelNode.convertPosition(v, to: nil)))
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
                           outlineGeometry: SCNGeometry?,
                           center: SCNVector3,
                           cameraDistance: Float) -> SCNScene {
        let scene = SCNScene()

        // A sky-over-ground environment image, used as the scene's light source.
        //
        // This is the piece the web viewers that look sharper all have and this scene did
        // not. Lighting a machined part with point lights alone leaves every surface facing
        // away from them uniformly flat — which is exactly what "看不清轮廓" describes:
        // the silhouette is there, the form inside it is not. An environment gives every
        // direction its own amount of light, so a face reads its own orientation, and
        // curved or angled features separate from one another without needing an edge.
        //
        // Built here rather than loaded so the app carries no asset: a bright zenith, a
        // mid horizon and a dark nadir, which is the same job a three.js hemisphere light
        // does in the reference viewer.
        scene.lightingEnvironment.contents = Self.environmentCube()
        // Minimal environment: just enough fill to keep the shadow side from going
        // pure black. Anything higher washes out the directional key and the part goes
        // flat — which is exactly what the screenshots show. The form must come from
        // the key light and its specular highlight, not from all-round fill.
        scene.lightingEnvironment.intensity = 0.15

        // Blinn, not PBR. PBR's diffuse response is nearly uniform across a matte
        // surface, so a curved face reads as one flat grey — the blob in the screenshots.
        // Blinn adds a tight specular highlight that tracks the surface normal, which is
        // what makes a rounded or angled face read as 3D without any texture.
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.86, green: 0.87, blue: 0.90, alpha: 1.0)
        mat.specular.contents = UIColor(white: 1.0, alpha: 1.0)
        mat.shininess = 25
        mat.lightingModel = .blinn
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
            edgeMat.diffuse.contents = UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)
            edgeMat.lightingModel = .constant
            // Ribbons can face either direction, so double-sided.
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
            // v -> center + 1.002 * (v - center).
            let edgeAnchor = SCNNode()
            edgeAnchor.name = "edgeAnchor"
            edgeAnchor.position = center
            edgeAnchor.scale = SCNVector3(1.002, 1.002, 1.002)

            let edgeNode = SCNNode(geometry: edgeGeometry)
            edgeNode.name = "edges"
            edgeNode.position = SCNVector3(-center.x, -center.y, -center.z)
            edgeAnchor.addChildNode(edgeNode)
            modelNode.addChildNode(edgeAnchor)
        }

        if let outlineGeometry {
            let outlineMat = SCNMaterial()
            outlineMat.diffuse.contents = UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
            outlineMat.lightingModel = .constant
            // Not double-sided: the whole point of the hull is to keep one side and drop
            // the other. Leaving both on would paint the near shell over the part.
            outlineMat.isDoubleSided = false
            outlineMat.cullMode = .front
            outlineMat.readsFromDepthBuffer = true
            // Must NOT write depth: the outline is the inflated back-shell, and if it
            // writes depth it z-fights with the surface it sits just outside. Reading
            // depth is what keeps the outline from leaking over the front faces — only
            // the rim that peeks beyond the silhouette survives the depth test.
            outlineMat.writesToDepthBuffer = false
            outlineGeometry.materials = [outlineMat]

            // 1 % inflation. Applied through the same explicit anchor pair as the edge
            // overlay — v -> center + 1.01 * (v - center).
            //
            // Down from 3 %: the shell is scaled about the centre while the rim it
            // shows is measured at the model's outer edge, so a 3 % scale reads as a
            // ~1.5 %-of-size band, six times the feature-edge tube width. That is the
            // heavy black line around the silhouette, and it swamped the edges.
            let outlineAnchor = SCNNode()
            outlineAnchor.name = "outlineAnchor"
            outlineAnchor.position = center
            outlineAnchor.scale = SCNVector3(1.01, 1.01, 1.01)

            let outlineNode = SCNNode(geometry: outlineGeometry)
            outlineNode.name = "outline"
            outlineNode.position = SCNVector3(-center.x, -center.y, -center.z)
            outlineAnchor.addChildNode(outlineNode)
            modelNode.addChildNode(outlineAnchor)
        }

        let camera = SCNCamera()
        camera.fieldOfView = 45
        // Placeholder depth range; `applyCamera` re-derives it from the current orbit
        // distance on every camera move, which is what keeps it right as the user zooms.
        // It is set explicitly even here because SceneKit's defaults — `zNear = 1`,
        // `zFar = 100` — would clip a part of any real size down to a near sliver, and
        // that is the state the very first frame would otherwise render in.
        camera.automaticallyAdjustsZRange = false
        camera.zNear = Double(max(cameraDistance * 0.01, 0.0001))
        camera.zFar = Double(max(cameraDistance * 10, 1))
        // HDR off: SceneKit's HDR tone mapper darkens the whole scene to make room for
        // highlights, which made the previous build too dark to read. For an untextured
        // CAD part with no bright highlights the extra range is wasted and the darkening
        // is the opposite of what is wanted.
        camera.wantsHDR = false
        camera.bloomIntensity = 0

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, cameraDistance * 0.32, cameraDistance)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        // A key, a fill and a little ambient on top of the environment above.
        //
        // The positions set here are only the opening frame's; `applyCamera` re-aims both
        // directional lights relative to the camera on every move, which is the same thing
        // the reference viewer's `_followCamera` lights do. A world-fixed rig is the other
        // half of why an orbit used to lose the model: swing round to the unlit side and
        // the only light left was ambient, so the part went flat exactly when the user was
        // looking hardest. Camera-relative lights mean every view arrives lit from the
        // upper left of the screen, whatever direction that is in the model's frame.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 950
        let keyNode = SCNNode()
        keyNode.name = "keyLight"
        keyNode.light = keyLight
        keyNode.position = SCNVector3(-cameraDistance * 0.45, cameraDistance * 0.62, cameraDistance * 0.64)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 380
        fillLight.color = UIColor(white: 0.86, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.name = "fillLight"
        fillNode.light = fillLight
        fillNode.position = SCNVector3(cameraDistance * 0.60, cameraDistance * 0.10, cameraDistance * 0.55)
        fillNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 220
        ambient.color = UIColor(white: 0.80, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.name = "ambientLight"
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    /// Six cube faces forming a sky-over-ground light environment.
    ///
    /// A cube map rather than a single equirectangular image because the face order and
    /// orientation are unambiguous, whereas how SceneKit projects a lone image depends on
    /// settings that are easy to get subtly wrong and hard to notice: the model would
    /// simply come out dimmer, which is exactly the symptom being fixed.
    ///
    /// SceneKit's face order is +X, -X, +Y, -Y, +Z, -Z, and for the four side faces the
    /// top of the image is +Y — so a plain top-to-bottom gradient is a gradient from sky
    /// to ground, which is what makes upward-facing surfaces brighter than downward ones.
    static func environmentCube() -> [UIImage] {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let sky = UIColor(white: 0.98, alpha: 1.0)
        let ground = UIColor(white: 0.34, alpha: 1.0)

        func uniform(_ color: UIColor) -> UIImage {
            renderer.image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }

        func gradient(from top: UIColor, to bottom: UIColor) -> UIImage {
            renderer.image { context in
                let colors = [top.cgColor, bottom.cgColor] as CFArray
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ramp = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
                else { return }
                context.cgContext.drawLinearGradient(
                    ramp,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }
        }

        let side = gradient(from: sky, to: ground)
        return [side, side,
                uniform(sky), uniform(ground),
                side, side]
    }

    // MARK: - Camera control

    /// The camera actually being rendered through.
    ///
    /// Deliberately read from the live `pointOfView` rather than looked up by name: it is
    /// the node the renderer is actually drawing through, so commanding it is correct
    /// whether or not SceneKit has swapped in a camera of its own.
    private var cameraNode: SCNNode? {
        renderView?.pointOfView
            ?? scene?.rootNode.childNode(withName: "camera", recursively: true)
    }

    /// Log for the camera state changes worth tracing from a device report.
    private static let cameraLog = Logger(subsystem: "com.xiaochun.3DViews", category: "camera")

    /// Points the renderer back at the scene's own camera if anything has moved
    /// `pointOfView` off it. Every orbital write assumes the node it commands is
    /// the node being rendered through; this makes that assumption self-healing
    /// rather than trusted, so a preset view can never end up applied to a camera
    /// the renderer is no longer looking through.
    private func reassertPointOfView() {
        guard let view = renderView,
              let scene,
              let camera = scene.rootNode.childNode(withName: "camera", recursively: true),
              view.pointOfView !== camera else { return }
        view.pointOfView = camera
    }

    /// Orbital camera state, in the model's own frame.
    ///
    /// Every model is recentred on the origin at load, so the orbit target starts there
    /// and only ever moves when the user pans. The camera is kept as an orientation and a
    /// distance — rather than an azimuth/elevation pair — which is what makes orbiting feel
    /// stable (the model stays put and turns) and what lets the depth range be recomputed
    /// from the distance on every move.
    ///
    /// `orientation` rotates the canonical camera frame onto the current one: it maps
    /// `(0, 0, 1)` to the direction from the target out to the camera, so acting on any
    /// vector with it expresses that vector in the camera's own frame. Storing the frame
    /// outright rather than two angles is what allows a full tumble — see `orbit`.
    /// The identity means "camera on +Z, looking back at the origin, no roll", which is
    /// the same opening view the old `azimuth 0, elevation 0` pair gave.
    private var cameraOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var cameraOrbitDistance: Float = 24
    private var cameraTarget = SCNVector3(0, 0, 0)

    /// Set once the initial framing has been solved for the current model.
    private var framedOnce = false

    /// Radians of rotation per point dragged. Roughly a third of a turn across a phone
    /// screen's width, which is the pace every 3D viewer settles on.
    private let orbitRadiansPerPoint: Float = 0.007

    /// The view a freshly loaded part opens on: slightly above dead level, looking down
    /// a touch, and otherwise square-on.
    ///
    /// A dead-level view puts the horizon of a typical part exactly on its silhouette,
    /// which is the one angle where a box reads as a flat rectangle; the small lift costs
    /// nothing and shows the top face straight away. Composed about the camera's own
    /// right axis, the same way a drag is, so the two keep agreeing.
    private static let openingOrientation = simd_quatf(angle: 0.18,
                                                       axis: SIMD3<Float>(1, 0, 0))

    /// Positions the camera from the orbital state and re-sizes its depth range.
    ///
    /// The depth range is recomputed here rather than fixed once when the scene is built
    /// because the user zooms: a range sized for the opening distance would clip the whole
    /// part the moment they dolly back, and its near plane would swallow a feature they
    /// dolly up to. Deriving both from the current distance keeps them correct at any
    /// zoom, which is what `automaticallyAdjustsZRange` was meant to do and cannot,
    /// because the controller that would honour it is switched off.
    private func applyCamera() {
        guard let camNode = cameraNode else { return }

        let d = cameraOrbitDistance
        // The basis comes straight out of the stored orientation, so it is exactly the
        // frame the user dragged to — no world-up reference and no cross product to
        // degenerate. The old build derived `right` from a fixed world up, which forced
        // the horizon to stay level at every angle (so the part could never be rolled)
        // and collapsed to a length of zero as the view approached straight down, where
        // horizontal dragging stopped working. Both are gone with the angle pair.
        let right = cameraOrientation.act(SIMD3<Float>(1, 0, 0))
        let up = cameraOrientation.act(SIMD3<Float>(0, 1, 0))
        let backward = cameraOrientation.act(SIMD3<Float>(0, 0, 1))
        let forward = -backward

        let position = SIMD3<Float>(cameraTarget.x, cameraTarget.y, cameraTarget.z) + backward * d
        camNode.simdPosition = position

        // SceneKit cameras look down their local -Z, so the basis columns are
        // screen-right, screen-up, and backward.
        camNode.simdTransform = simd_float4x4(
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(-forward, 0),
            SIMD4<Float>(position, 1)
        )

        if let camera = camNode.camera {
            camera.automaticallyAdjustsZRange = false
            camera.zNear = Double(max(d * 0.01, 0.0001))
            camera.zFar = Double(d + max(modelDim, 1) * 8)
        }

        updateLights(relativeTo: camNode)
    }

    /// Re-aims the lights as the camera moves.
    ///
    /// The key is a headlight, parked on the axis the camera looks down and aimed the same
    /// way the camera aims, so the face looking back at the viewer is the lit one at every
    /// angle.
    ///
    /// Being *on* the axis is what makes it hold still. A directional light cares only
    /// about direction, and rolling the camera about the view axis does not change the view
    /// axis — so a headlight is blind to roll. Any tilt at all breaks that: the tilt is
    /// carried round the screen as the part rolls, and the highlight visibly orbits the
    /// model. That is what the earlier builds did, first from the upper left and then from
    /// nearly straight on; both lights moved, and the lighting read as a part of the model
    /// rather than as part of the room.
    ///
    /// Placed as a whole transform rather than with `look(at:)` because a headlight sits
    /// on the line through the target: aiming it at the target asks a node to look at a
    /// point it is already exactly in line with, which is what the straight-down and
    /// straight-up views are now that the presets name them exactly — precisely the case
    /// `look(at:)`'s up-vector heuristic has no answer for.
    ///
    /// The fill does need a tilt, or a facet square to the viewer reads as flat, and that
    /// tilt needs a frame that does not roll. The camera's own frame cannot supply one, so
    /// the offset is squared to the world instead: `side` is always horizontal, and `above`
    /// rises out of it. The one place that construction fails is looking straight up or
    /// straight down, where the camera's axes land exactly on the world's and `side`
    /// collapses to nothing — hence the stand-in reference.
    private func updateLights(relativeTo camNode: SCNNode) {
        guard let scene else { return }

        let distance = cameraOrbitDistance
        let orientation = camNode.simdWorldTransform
        let origin = camNode.simdWorldPosition
        let backward = SIMD3<Float>(orientation.columns.2.x,
                                    orientation.columns.2.y,
                                    orientation.columns.2.z)

        if let key = scene.rootNode.childNode(withName: "keyLight", recursively: true) {
            let parked = origin + backward * distance
            key.simdTransform = simd_float4x4(orientation.columns.0,
                                              orientation.columns.1,
                                              orientation.columns.2,
                                              SIMD4<Float>(parked, 1))
        }

        guard let fill = scene.rootNode.childNode(withName: "fillLight", recursively: true)
        else { return }
        let reference = abs(backward.y) > 0.999
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let side = simd_normalize(simd_cross(reference, backward))
        let above = simd_cross(backward, side)
        let offset = side * 0.38 + above * 0.08 + backward * 0.85
        fill.simdPosition = origin + offset * distance
        fill.look(at: cameraTarget)
    }

    /// Distance at which the whole part fits the viewport, with a margin.
    ///
    /// Solved against both the vertical and the horizontal field of view, because on a
    /// phone in portrait the horizontal one is much narrower: a distance that fits the
    /// part vertically still crops it side to side. Framing only vertically is the reason
    /// a wide part can arrive half off-screen, which reads as a broken model rather than
    /// as a camera that started too close.
    private func fitDistance(for view: SCNView) -> Float {
        let height = Float(max(view.bounds.height, 1))
        let aspect = Float(max(view.bounds.width, 1)) / height
        let verticalFOV = Float(45.0 * Double.pi / 180)
        let horizontalFOV = 2 * atan(tan(verticalFOV / 2) * aspect)
        let vertical = modelRadius / tan(verticalFOV / 2)
        let horizontal = modelRadius / tan(max(horizontalFOV / 2, 0.01))
        return max(vertical, horizontal) * 1.15
    }

    /// Frames the freshly loaded part and re-applies the camera state.
    ///
    /// A viewport that has not been laid out yet would report a zero size and solve for a
    /// nonsense distance, so in that case the part-sized default from load is kept instead.
    ///
    /// The fit is solved once per model, not once per scene hand-over: SwiftUI can hand
    /// the same scene to a fresh renderer while the push transition is still laying out
    /// the viewport, and re-solving against those in-flight bounds would size the same
    /// part differently depending on when the hand-over happened.
    private func applyInitialFraming(in view: SCNView) {
        if !framedOnce, view.bounds.width > 1, view.bounds.height > 1 {
            cameraDistance = fitDistance(for: view)
            framedOnce = true
        }
        cameraOrbitDistance = cameraDistance
        applyCamera()
    }

    /// One-finger drag: tumble the part about the target.
    ///
    /// Each drag axis is mapped onto the camera's *own* current right/up vectors rather
    /// than onto a world axis, and the two rotations are composed onto the accumulated
    /// orientation. That is what makes the motion a free tumble in every direction: there
    /// is no world up to stay level against, so a diagonal drag rolls the part as well as
    /// turning it, and no angle is out of reach — including the straight-down view the
    /// old elevation clamp kept just short of, which is exactly where its horizontal
    /// drag used to stop responding.
    ///
    /// Rotating the camera about the target is the same motion on screen as rotating the
    /// model, because every model is recentred on the origin at load.
    func orbit(dx: CGFloat, dy: CGFloat) {
        let yaw = simd_quatf(angle: -Float(dx) * orbitRadiansPerPoint,
                             axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: -Float(dy) * orbitRadiansPerPoint,
                               axis: SIMD3<Float>(1, 0, 0))
        // Post-multiplied, so both axes are read in the camera's *current* frame. Doing
        // it the other way round would turn the second axis into a world axis and the
        // view would start behaving differently depending on how the part was already
        // oriented.
        cameraOrientation = cameraOrientation * yaw * pitch
        cameraOrientation = simd_normalize(cameraOrientation)
        applyCamera()
    }

    /// Pinch: dolly. Clamped so the part can neither be lost to infinity nor flown into.
    func zoom(by scale: CGFloat) {
        guard scale > 0 else { return }
        cameraOrbitDistance = min(max(cameraOrbitDistance / Float(scale),
                                      modelDim * 0.2), modelDim * 12)
        applyCamera()
    }

    /// Two-finger drag: slide the target, and the camera with it, in the view plane.
    ///
    /// World units per point are taken at the target's depth, so the model tracks the
    /// fingers rather than sliding at some other parallax. The target is what moves; the
    /// camera follows rigidly, which is why the orientation is unchanged.
    func pan(dx: CGFloat, dy: CGFloat, viewportHeight: CGFloat) {
        guard let camNode = cameraNode, viewportHeight > 1 else { return }

        let distance = cameraOrbitDistance
        let halfFieldOfView = Float(45.0 / 2 * Double.pi / 180)
        let unitsPerPoint = (2 * distance * tan(halfFieldOfView)) / Float(viewportHeight)

        let forward = simd_normalize(SIMD3<Float>(cameraTarget.x - camNode.position.x,
                                                  cameraTarget.y - camNode.position.y,
                                                  cameraTarget.z - camNode.position.z))
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, up)) > 0.99 { up = SIMD3<Float>(0, 0, 1) }
        let right = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_normalize(simd_cross(right, forward))

        // Content follows the fingers: dragging right carries the model right, which means
        // the camera — and so the target — moves left.
        let move = right * (-Float(dx) * unitsPerPoint) + trueUp * (Float(dy) * unitsPerPoint)
        cameraTarget = SCNVector3(cameraTarget.x + move.x,
                                  cameraTarget.y + move.y,
                                  cameraTarget.z + move.z)
        applyCamera()
    }

    // MARK: - Auto rotation

    /// One tick per frame. The rotation is integrated from the clock rather than
    /// assuming each tick is exactly this far apart, so a dropped frame skips a step
    /// of the turn instead of slowing the whole thing down.
    private static let autoRotationInterval: TimeInterval = 1.0 / 60.0

    /// Radians per second. A full turn in about fifteen seconds: quick enough that the
    /// far side of a part comes round without the user waiting, slow enough to read a
    /// feature as it passes. Faster than this and the part reads as a spinning blur
    /// rather than as a turning object.
    private static let autoRotationRadiansPerSecond: Double = 2 * .pi / 15

    /// Explicitly `Foundation.Timer`: the OCCT kernel exports a public type of its own
    /// called `Timer`, and this file imports both modules, so the bare name is ambiguous.
    private var autoRotationTimer: Foundation.Timer?
    private var lastAutoRotationTick: TimeInterval = 0

    /// Turns the part continuously about the origin, for hands-free viewing.
    ///
    /// This advances the camera's azimuth rather than rotating the model node. The two
    /// are the same motion on screen — `buildScene` recentres every model on the origin
    /// through `modelRoot`, so orbiting the camera about the target *is* spinning the
    /// part about its own centre. Orbiting is the one that stays correct: the picking
    /// data (`edgeWorldPolylines`, `vertexWorld`, the face overlay cache, and the world
    /// positions baked into the measurement annotations) is all computed once against
    /// the model node's world transform at load. Actually rotating `modelRoot` would
    /// leave every one of those frozen at the old angle, so taps, snaps and labels
    /// would silently drift out of register with the geometry they describe by however
    /// far the part had turned.
    ///
    /// Idempotent, so callers can hand it the current setting on every appearance
    /// change without tracking whether it is already running.
    func setAutoRotation(_ enabled: Bool) {
        guard enabled else {
            autoRotationTimer?.invalidate()
            autoRotationTimer = nil
            return
        }
        guard autoRotationTimer == nil else { return }

        lastAutoRotationTick = ProcessInfo.processInfo.systemUptime
        let timer = Foundation.Timer(timeInterval: Self.autoRotationInterval, repeats: true) { [weak self] _ in
            // The run loop delivers this on the main thread; `assumeIsolated` is what
            // tells the compiler that, since the block itself is not isolated.
            MainActor.assumeIsolated {
                self?.advanceAutoRotation()
            }
        }
        // Added in `.common` rather than through `scheduledTimer`, which installs in
        // `.default`: the run loop suspends that mode while a gesture is being tracked,
        // so the rotation would stall under the user's finger and then jump.
        RunLoop.main.add(timer, forMode: .common)
        autoRotationTimer = timer
    }

    /// One tick of the auto-rotation.
    private func advanceAutoRotation() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastAutoRotationTick
        lastAutoRotationTick = now
        // A delta this large means the app was suspended and has just come back, or the
        // timer was blocked behind something expensive. Integrating it would snap the
        // part through a big part of a turn in a single frame, so the frame is dropped
        // and the clock reset instead.
        guard elapsed > 0, elapsed < 0.25 else { return }
        // Turned about the camera's *own* up axis, so the rotation follows whichever way
        // the user has tumbled the part to: a part viewed from underneath keeps turning
        // about the screen's vertical once it is running. Driving a world axis instead
        // would look correct only from the opening view.
        let step = simd_quatf(angle: -Float(elapsed * Self.autoRotationRadiansPerSecond),
                              axis: SIMD3<Float>(0, 1, 0))
        cameraOrientation = simd_normalize(cameraOrientation * step)
        applyCamera()
    }

    func resetView() {
        cameraOrientation = Self.openingOrientation
        cameraOrbitDistance = cameraDistance
        cameraTarget = SCNVector3(0, 0, 0)
        reassertPointOfView()
        applyCamera()
        Self.cameraLog.info("reset view: opening orientation")
    }

    func setViewDirection(_ direction: ViewDirection) {
        // Each preset is written as the camera frame it should end on, in one piece. The
        // old build set an azimuth and an elevation and let the world-up cross product
        // finish the job, which is also why `.top` and `.bottom` had to sit a fraction of
        // a degree off true vertical; a frame can name those views exactly.
        cameraOrientation = direction.cameraOrientation
        cameraOrbitDistance = cameraDistance
        cameraTarget = SCNVector3(0, 0, 0)
        reassertPointOfView()
        applyCamera()
        Self.cameraLog.info("view \(direction.rawValue, privacy: .public)")
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
        // A tap arriving while a finished measurement is still on the panel supersedes
        // it: the finished one is frozen into the history first (it stays drawn on the
        // model), then this tap becomes the first pick of the next measurement.
        if picks.count >= requiredPickCount, requiredPickCount > 0 {
            finalizeMeasurement()
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
            guard entities.count == 2 else { return false }

            switch distanceMode {
            case .min:
                guard let first = subShape(for: entities[0]),
                      let second = subShape(for: entities[1]),
                      let measure = OCCTSwift.ShapeDistance(shape1: first, shape2: second),
                      measure.isDone else { return false }

                distanceResult = Float(measure.value)

                // The kernel's own witness points, not the tapped ones: for two faces
                // or two edges the minimum segment generally sits nowhere near where
                // the finger landed, so the annotation has to join these to make sense.
                if measure.solutionCount > 0 {
                    closestPointA = world(measure.pointOnShape1(at: 0))
                    closestPointB = world(measure.pointOnShape2(at: 0))
                }
                return true

            case .center:
                // Deliberately *not* via `subShape(for:)`. That returns a shape holding
                // exactly one face, and the centre lookup then indexes it with the
                // original face number — `shape.face(at: 7)` on a one-face shape is nil
                // for every face but the first, which is what made two tapped circular
                // faces silently measure nothing. The whole model is indexed here
                // instead, exactly as the radius and area branches below already do it.
                guard let shape,
                      let a = CenterFeature.of(picks[0], shape: shape,
                                               at: kernelPoint(picks[0].point)),
                      let b = CenterFeature.of(picks[1], shape: shape,
                                               at: kernelPoint(picks[1].point)) else {
                    measureMessage = "请点选圆边或回转面来量取中心距"
                    distanceResult = nil
                    closestPointA = nil
                    closestPointB = nil
                    return true
                }

                // Two axes are measured axis-to-axis, not point-to-point. Reducing each
                // to a point first would make two coaxial faces report the gap between
                // them instead of the 0 they should: the points differ, the lines do
                // not. This is FreeCAD's `discAxisDistance` / `cylinderAxisDistance`
                // reading, and the one that matches "中心".
                guard let solved = CenterFeature.separation(of: a, and: b) else {
                    measureMessage = "两个中心无法比较"
                    distanceResult = nil
                    closestPointA = nil
                    closestPointB = nil
                    return true
                }
                closestPointA = world(solved.0)
                closestPointB = world(solved.1)
                distanceResult = Float(solved.2)
                return true

            case .max:
                let pointsA = extremePoints(of: picks[0])
                let pointsB = extremePoints(of: picks[1])
                guard !pointsA.isEmpty, !pointsB.isEmpty else { return false }

                // Searched here because the kernel will not: see `DistanceMode`. The
                // witness points come out of the same search, so the annotation joins
                // the two points the number was actually taken between.
                var best: (SIMD3<Double>, SIMD3<Double>, Double)?
                for p in pointsA {
                    for q in pointsB {
                        let dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z
                        let d = (dx * dx + dy * dy + dz * dz).squareRoot()
                        if best == nil || d > best!.2 { best = (p, q, d) }
                    }
                }
                guard let best else { return false }

                closestPointA = world(best.0)
                closestPointB = world(best.1)
                distanceResult = Float(best.2)
                return true
            }

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

    /// World coordinates → kernel coordinates, the inverse of ``world(_:)``.
    ///
    /// The entity paths measure in the kernel's own frame, but a pick records where the
    /// finger landed in world space, so a tapped position has to come back the other way
    /// before it can be differenced against kernel geometry.
    private func kernelPoint(_ point: SCNVector3) -> SIMD3<Double> {
        guard let modelNode else {
            return SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z))
        }
        let p = modelNode.convertPosition(point, from: nil)
        return SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
    }

    /// What a picked entity contributes to a centre-distance measurement.
    ///
    /// A circular feature has to stay a *line* until both picks are known. Collapsing it
    /// to one point first is what made two concentric circular faces read as their
    /// separation: each face legitimately yields a different point on the *same* axis,
    /// so the point-to-point distance is the gap between them while the honest answer is
    /// 0. FreeCAD keeps the same distinction — `Measurement::discAxisDistance` and
    /// `MeasureType::TwoCylinders` both feed `gp_Circ::Axis()` / `gp_Cylinder::Axis()`
    /// straight into `gp_Lin::Distance` rather than differencing locations.
    ///
    /// The geometry helpers live here rather than beside ``discCircle(of:)`` on the view
    /// model because `ViewerViewModel` is main-actor isolated: a nonisolated context
    /// cannot call into it, and this type is deliberately nonisolated so the arithmetic
    /// stays testable and off the main actor.
    private enum CenterFeature {
        /// A circular face, a circular edge, a vertex or anything else that really does
        /// have one centre.
        case point(SIMD3<Double>)
        /// A disc's circle axis or a cylinder's surface axis, in kernel coordinates.
        case axis(origin: SIMD3<Double>, direction: SIMD3<Double>)

        /// The centre of a picked entity, or nil when even the fallbacks are exhausted.
        ///
        /// `pickedPoint` is the tapped position already converted into kernel coordinates
        /// — it is passed in rather than computed here because the conversion belongs to
        /// the view model's transform, and this type is nonisolated.
        static func of(_ pick: Pick, shape: OCCTSwift.Shape,
                       at pickedPoint: SIMD3<Double>) -> CenterFeature? {
            switch pick.entity {
            case .face(let i):
                guard let face = shape.face(at: i) else { return nil }

                // A disc first: a planar face whose boundary is one circle. Reading the
                // axis rather than the centre is what lets a stack of concentric discs
                // measure 0 against each other.
                if face.isPlanar, let circle = Self.discCircle(of: face) {
                    return .axis(origin: circle.center, direction: circle.axis)
                }

                // A cylinder, cone or torus — its axis is the feature. Tested only for
                // the kinds where the axis is intrinsic: a sphere's `direction` is just
                // an arbitrary construction-frame pole, and an extrusion's is its sweep
                // direction, so both would be invented geometry rather than measured.
                if let axis = face.primaryAxis, Self.isGenuineAxis(axis.kind) {
                    return .axis(origin: axis.origin, direction: axis.direction)
                }

                // A sphere reports its centre through the same accessor even though its
                // direction is meaningless, so it is still a point, not an axis.
                if let axis = face.primaryAxis, axis.kind == .sphere {
                    return .point(axis.origin)
                }

                // The area centroid. Right for a flat face whose boundary is not a
                // circle, and the value the original code was reaching for.
                if let centroid = face.surfaceInertia.centerOfMass { return .point(centroid) }

                // The bounding box of the surface. Coarse, but never absent.
                if let box = face.bounds { return .point((box.min + box.max) / 2) }
                return nil

            case .edge(let i):
                guard let edge = shape.edge(at: i) else { return nil }
                if let circle = edge.circleProperties { return .point(circle.center) }
                if let centroid = edge.curveInertia.centerOfMass { return .point(centroid) }
                return nil

            case .vertex, .freePoint:
                // A vertex is its own centre, and the tapped position is already the most
                // accurate statement of where it is.
                return .point(pickedPoint)
            }
        }

        /// Whether `kind` describes the surface itself rather than the construction frame
        /// the surface happens to be expressed in.
        ///
        /// `.sphere` is excluded on purpose: a sphere is symmetric about *every* axis
        /// through its centre, so its `direction` is an arbitrary pole and comparing two
        /// of them would invent a difference that is not in the geometry. `.extrusion`'s
        /// direction is the sweep direction, equally not an axis of revolution. Only these
        /// four carry a genuine rotation axis.
        private static func isGenuineAxis(_ kind: OCCTSwift.ShapeAxis.Kind) -> Bool {
            switch kind {
            case .cylinder, .cone, .torus, .revolution: return true
            case .sphere, .extrusion, .symmetry: return false
            }
        }

        /// A face's boundary circle as the *axis* of that circle, or nil when the boundary
        /// is not a single circle.
        ///
        /// The origin returned is the circle's centre and the direction its plane normal —
        /// together `gp_Circ::Axis()`, the line FreeCAD's `getDiscAxis` builds and feeds to
        /// `gp_Lin::Distance`. Reading the axis rather than just the centre is what makes
        /// two stacked concentric discs measure 0 instead of their separation.
        ///
        /// Every boundary edge must be the *same* circle, which is what a disc looks like
        /// after a boolean has cut it into arcs. Note that this alone does **not** exclude
        /// a cylinder — a bore's two end rims are concentric, so their centres and normals
        /// agree — and the caller's `face.isPlanar` test is what actually keeps a
        /// cylindrical side wall out of this path. The end caps of a cylinder are planar,
        /// so they are discs and belong here; the side wall is not, and takes the
        /// surface-axis branch.
        private static func discCircle(of face: OCCTSwift.Face)
            -> (center: SIMD3<Double>, axis: SIMD3<Double>)? {
            guard let edges = face.outerWire?.edges(), !edges.isEmpty else { return nil }

            var centre: SIMD3<Double>?
            var axis: SIMD3<Double>?
            for edge in edges {
                guard let circle = edge.circleProperties else { return nil }
                if let centre, let axis {
                    let drift = max(Self.length(circle.center - centre),
                                    Self.length(circle.axis - axis))
                    // Tolerance scaled to the model, so a large part is not held to a small
                    // part's precision. 1e-6 mm on a 1 mm feature, 1e-3 mm on a 1 m one.
                    let scale = max(Self.length(centre), 1)
                    guard drift <= scale * 1e-6 else { return nil }
                } else {
                    centre = circle.center
                    axis = circle.axis
                }
            }
            guard let centre, let axis else { return nil }
            return (centre, axis)
        }

        /// The distance between two centres, plus the witness point on each, in kernel
        /// coordinates.
        static func separation(of a: CenterFeature, and b: CenterFeature)
            -> (SIMD3<Double>, SIMD3<Double>, Double)? {
            switch (a, b) {
            case let (.point(p), .point(q)):
                return (p, q, Self.length(q - p))

            case let (.axis(o1, d1), .axis(o2, d2)):
                return closestPoints(between: o1, direction: d1, and: o2, direction: d2)

            case let (.point(p), .axis(o, d)):
                guard let foot = Self.foot(of: p, on: o, direction: d) else { return nil }
                return (p, foot, Self.length(foot - p))

            case let (.axis(o, d), .point(q)):
                guard let foot = Self.foot(of: q, on: o, direction: d) else { return nil }
                return (foot, q, Self.length(q - foot))
            }
        }

        /// The point of an axis nearest `p`; nil when the axis is degenerate.
        private static func foot(of p: SIMD3<Double>, on origin: SIMD3<Double>,
                                 direction: SIMD3<Double>) -> SIMD3<Double>? {
            let unit = Self.unit(direction)
            guard let unit else { return nil }
            return origin + unit * simd_dot(p - origin, unit)
        }

        /// The closest pair of points on two infinite lines — the standard skew-line
        /// construction, and the reason two coaxial features measure exactly 0.
        ///
        /// Parallel lines take the perpendicular through the first origin: the
        /// cross-product form divides by `sin²θ` and is singular there, while the answer
        /// is the same perpendicular offset the closed form would have produced as a limit.
        private static func closestPoints(between o1: SIMD3<Double>, direction d1: SIMD3<Double>,
                                          and o2: SIMD3<Double>, direction d2: SIMD3<Double>)
            -> (SIMD3<Double>, SIMD3<Double>, Double)? {
            guard let u = Self.unit(d1), let v = Self.unit(d2) else { return nil }

            let w = o1 - o2
            let cross = simd_cross(u, v)
            let sine = Self.length(cross)

            if sine > 1e-9 {
                // Skew or intersecting: the common perpendicular joins the two feet.
                let t1 = simd_dot(simd_cross(w, v), cross) / (sine * sine)
                let t2 = simd_dot(simd_cross(w, u), cross) / (sine * sine)
                let q1 = o1 + u * t1
                let q2 = o2 + v * t2
                return (q1, q2, Self.length(q2 - q1))
            }

            // Parallel: drop the component of the offset that lies along the shared
            // direction. Whatever remains is perpendicular to both lines, so its length is
            // the separation — and it is exactly zero when the two origins coincide on one
            // common axis, which is the concentric case this whole path exists for.
            let perpendicular = w - u * simd_dot(w, u)
            return (o1, o1 - perpendicular, Self.length(perpendicular))
        }

        private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double>? {
            let length = Self.length(v)
            guard length > 1e-12 else { return nil }
            return v / length
        }

        private static func length(_ v: SIMD3<Double>) -> Double {
            (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        }
    }

    /// A point set dense enough to bracket the farthest pair on one entity.
    ///
    /// A face is gridded in its own UV space and an edge walked in parameter space. UV
    /// space covers the *untrimmed* surface, so grid points can land inside a hole or
    /// past an outer wire; the kernel's own classifier is what throws those out. If it
    /// declines to classify any of them the unfiltered grid is used instead — a slightly
    /// generous answer beats an empty one — but a face that classifies cleanly is
    /// measured only over the part that actually exists.
    private func extremePoints(of pick: Pick) -> [SIMD3<Double>] {
        switch pick.entity {
        case .face(let i):
            guard let face = shape?.face(at: i), let bounds = face.uvBounds else { return [] }

            let steps = 12
            var onFace: [SIMD3<Double>] = []
            var all: [SIMD3<Double>] = []
            for u in 0...steps {
                for v in 0...steps {
                    let uu = bounds.uMin + (bounds.uMax - bounds.uMin) * Double(u) / Double(steps)
                    let vv = bounds.vMin + (bounds.vMax - bounds.vMin) * Double(v) / Double(steps)
                    guard let point = face.point(atU: uu, v: vv) else { continue }
                    all.append(point)
                    let classification = face.classify(u: uu, v: vv)
                    if classification == .inside || classification == .onBoundary {
                        onFace.append(point)
                    }
                }
            }
            return onFace.count >= 3 ? onFace : all

        case .edge(let i):
            guard let edge = shape?.edge(at: i), let bounds = edge.parameterBounds else { return [] }

            var points: [SIMD3<Double>] = []
            let steps = 24
            for k in 0...steps {
                let t = bounds.first + (bounds.last - bounds.first) * Double(k) / Double(steps)
                if let point = edge.point(at: t) { points.append(point) }
            }
            // The "面与圆心" half of this mode: a circular edge contributes its own
            // centre as well as its rim, so a bore can be measured to a face from the
            // middle of the hole and not only from its edge.
            if let circle = edge.circleProperties { points.append(circle.center) }
            return points

        case .vertex, .freePoint:
            return [kernelPoint(pick.point)]
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

    // MARK: - Pick list

    /// Removes the most recently picked entity and recomputes. A mis-pick is always
    /// one undo away, which is what let the dedicated selection panel go.
    func undoLastPoint() {
        guard !picks.isEmpty else { return }
        picks.removeLast()
        computeResults()
        updateMeasureVisuals(in: renderView)
    }

    func selectMeasureType(_ type: MeasureType) {
        // A finished measurement still on the panel is kept when the user moves on to
        // a different kind of question — it was measured, it stays measured.
        if isComplete, requiredPickCount > 0 {
            finalizeMeasurement()
        }
        measureType = type
        clearMeasure()
        // Volume and the bounding box need no pick, so selecting the type is the whole
        // interaction — but `clearMeasure` has just wiped the results, so they have to
        // be recomputed here or the panel would show "--" until something else ran.
        computeResults()
    }

    func clearMeasure() {
        resetMeasureState()
        measureGroup?.removeFromParentNode()
        measureGroup = nil
    }

    /// Clears everything the *in-progress* measurement owns, leaving the finished ones
    /// (`measurements`) untouched.
    private func resetMeasureState() {
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
        clearHighlightNodes()
    }

    /// Freezes the finished measurement into the history and clears the slate.
    ///
    /// The annotation group is handed over, not copied: it stays in the scene attached
    /// to its `MeasurementItem`, so `updateMeasureVisuals` rebuilding the *current*
    /// group can never disturb a reading the user has already taken. Only a measurement
    /// that actually produced a number is kept — a rejected combination (say, the angle
    /// of a face to an edge) leaves nothing behind to delete.
    private func finalizeMeasurement() {
        guard let valueText = currentValueText(), measureMessage == nil,
              let node = measureGroup else { return }

        measurements.append(MeasurementItem(type: measureType,
                                            picks: picks,
                                            valueText: valueText,
                                            node: node))
        // Ownership has moved to the item; dropping the reference is what stops the
        // next rebuild from wiping the finished annotation.
        measureGroup = nil

        resetMeasureState()
    }

    /// Removes every finished measurement at once.
    func clearAllMeasurements() {
        for item in measurements {
            item.node?.removeFromParentNode()
        }
        measurements.removeAll()
    }

    /// Shows or hides every finished measurement's annotation.
    func toggleAnnotations() {
        annotationsVisible.toggle()
        for item in measurements {
            item.node?.isHidden = !annotationsVisible
        }
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
            // A finished measurement still showing is kept — the readings are usually
            // checked while orbiting the part afterwards. Only the in-progress slate
            // (and its half-built annotation) is dropped here.
            if isComplete, requiredPickCount > 0 {
                finalizeMeasurement()
            }
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
        let outline = scene?.rootNode.childNode(withName: "outline", recursively: true)

        // Filled is the norm; only the STL wireframe fallback below wants `.lines`, and
        // starting from `.fill` means switching away from it can never leave the surface
        // drawn as a mesh of hairlines.
        material.fillMode = .fill

        // The outline is a solid black shell sitting just outside the surface, so it only
        // reads as an outline while that surface is actually writing depth. In the two
        // modes where it does not — translucent and wireframe — the shell would be drawn
        // through as a black body around the part instead, so it is switched off.
        outline?.isHidden = false

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
            outline?.isHidden = true

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
            outline?.isHidden = true
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

        // A snap in progress reads differently from a plain surface point: cube and
        // orange instead of the yellow dot, so the user can see the vertex snap take
        // hold before committing it.
        let snappedVertex = previewEntity?.isVertex ?? false
        let geometry: SCNGeometry
        if snappedVertex {
            let side = CGFloat(radius * 1.7)
            geometry = SCNBox(width: side, height: side, length: side, chamferRadius: 0)
        } else {
            geometry = SCNSphere(radius: CGFloat(radius))
        }
        let glow = snappedVertex ? UIColor.systemOrange : UIColor.systemYellow
        let material = SCNMaterial()
        material.diffuse.contents = glow.withAlphaComponent(0.85)
        material.emission.contents = glow.withAlphaComponent(0.35)
        material.lightingModel = .constant
        // Drawn over the surface it highlights: the point generally sits *on* the model,
        // so depth testing alone would clip away most of the sphere.
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let dot = SCNNode(geometry: geometry)
        dot.position = point
        dot.name = "preview_dot"
        group.addChildNode(dot)

        if let name = previewEntityName {
            let text = SCNText(string: name, extrusionDepth: 0.1)
            text.font = UIFont.boldSystemFont(ofSize: 10)
            text.firstMaterial?.diffuse.contents = glow
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

        // Axial components for the two-point distances: the orthogonal staircase
        // A → (B.x,A.y,A.z) → (B.x,B.y,A.z) → B, colour-coded to match the ΔX/ΔY/ΔZ
        // rows in the result panel so the drawing and the numbers read as one thing.
        if (measureType == .distance || measureType == .linear), distanceResult != nil {
            if let a = closestPointA, let b = closestPointB {
                addAxialComponents(from: a, to: b, lineRadius: lineRadius,
                                   unitsPerPoint: unitsPerPoint, to: group)
            } else if picks.count == 2 {
                addAxialComponents(from: picks[0].point, to: picks[1].point,
                                   lineRadius: lineRadius,
                                   unitsPerPoint: unitsPerPoint, to: group)
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

    /// Marker geometry by snap kind: a sphere for surface points/faces/edges, a cube
    /// for a snapped vertex — the silhouette alone tells an exact snap from a tap on
    /// a face, which matters on an STL where the vertex is the only precise target.
    private func markerGeometry(for entity: PickEntity, radius: Float) -> SCNGeometry {
        if entity.isVertex {
            let side = CGFloat(radius * 1.7)
            return SCNBox(width: side, height: side, length: side, chamferRadius: 0)
        }
        return SCNSphere(radius: CGFloat(radius))
    }

    private func addMarker(at point: SCNVector3, entity: PickEntity, index: Int,
                           radius markerRadius: Float, to group: SCNNode,
                           showTag: Bool = true) {
        let color = entity.markerColor

        let geometry = markerGeometry(for: entity, radius: markerRadius)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color
        mat.lightingModel = .constant
        geometry.materials = [mat]
        let marker = SCNNode(geometry: geometry)
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

    /// Draws the axial components of a two-point distance as an orthogonal staircase
    /// A → (B.x,A.y,A.z) → (B.x,B.y,A.z) → B, one colour per axis, each leg carrying
    /// a small signed label — the same ΔX/ΔY/ΔZ information the result panel lists,
    /// drawn where it is measured (xeokit's axis wires). A leg shorter than ~2 pt on
    /// screen cannot be seen and is dropped; below ~26 pt it is drawn but unlabelled,
    /// since a label on a stub only adds clutter.
    private func addAxialComponents(from a: SCNVector3, to b: SCNVector3,
                                    lineRadius: Float, unitsPerPoint: CGFloat,
                                    to group: SCNNode) {
        let up = Float(unitsPerPoint)
        // Exactly one of dx/dy/dz is non-zero per leg, so the sum is that leg's
        // signed delta in scene units.
        let legs: [(dx: Float, dy: Float, dz: Float, color: UIColor, symbol: String)] = [
            (b.x - a.x, 0, 0, .systemRed, "X"),
            (0, b.y - a.y, 0, .systemGreen, "Y"),
            (0, 0, b.z - a.z, .systemBlue, "Z"),
        ]

        var cursor = a
        for leg in legs {
            let end = SCNVector3(cursor.x + leg.dx, cursor.y + leg.dy, cursor.z + leg.dz)
            let length = (leg.dx * leg.dx + leg.dy * leg.dy + leg.dz * leg.dz).squareRoot()
            if length > up * 2, length > modelDim * 1e-4 {
                addCylinderLine(from: cursor, to: end,
                                lineRadius: lineRadius * 0.55,
                                to: group, color: leg.color)

                if length > up * 26 {
                    addSmallLabel("Δ\(leg.symbol) \(displayUnit.format(leg.dx + leg.dy + leg.dz))",
                                  at: SCNVector3((cursor.x + end.x) / 2,
                                                 (cursor.y + end.y) / 2,
                                                 (cursor.z + end.z) / 2),
                                  height: CGFloat(up * 9),
                                  color: leg.color, to: group)
                }
            }
            cursor = end
        }
    }

    /// A compact billboard text in a given colour — the axial legs' labels.
    private func addSmallLabel(_ string: String, at point: SCNVector3,
                               height: CGFloat, color: UIColor, to group: SCNNode) {
        let text = SCNText(string: string, extrusionDepth: 0.1)
        text.font = UIFont.boldSystemFont(ofSize: 10)
        text.firstMaterial?.diffuse.contents = color
        text.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: text)
        let (tMin, tMax) = text.boundingBox
        let textHeight = tMax.y - tMin.y
        if textHeight > 1e-6 {
            let s = Float(height) / textHeight
            node.scale = SCNVector3(s, s, s)
        }
        // Centre on the anchor so the billboard spins about the label's middle.
        node.pivot = SCNMatrix4MakeTranslation(
            (tMin.x + tMax.x) / 2, (tMin.y + tMax.y) / 2, (tMin.z + tMax.z) / 2)
        node.position = SCNVector3(point.x, point.y + Float(height) * 0.6, point.z)
        node.name = "measure_label"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        group.addChildNode(node)
    }

    /// The measurement's primary reading as display text, for every type.
    ///
    /// `currentLabelString` only covers the types that have an anchor to hang a 3D
    /// label from; this is the superset the history list needs, because a volume or a
    /// bounding box still reads as a number even though nothing is drawn for it.
    private func currentValueText() -> String? {
        switch measureType {
        case .distance, .linear:
            return distanceResult.map { displayUnit.format($0) }
        case .angle:
            return angleResult.map { String(format: "%.1f°", $0) }
        case .radius:
            return radiusResult.map {
                displayUnit.format(radiusShowsDiameter ? $0 * 2 : $0)
            }
        case .area:
            return areaResult.map { displayUnit.formatArea($0) }
        case .volume:
            return volumeResult.map { displayUnit.formatVolume($0) }
        case .boundingBox:
            return boundingBoxExtents.map { displayUnit.format(max($0.x, max($0.y, $0.z))) }
        }
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
            return displayUnit.format(radiusShowsDiameter ? r * 2 : r)
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
