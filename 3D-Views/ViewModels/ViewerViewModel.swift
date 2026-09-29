//
//  ViewerViewModel.swift
//  3D-Views
//

import Foundation
import SceneKit
import SwiftUI
import OCCTSwift

enum InteractionMode: Equatable {
    case orbit
    case measure
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

    @Published var distanceResult: Float?
    @Published var angleResult: Float?
    @Published var radiusResult: Float?
    @Published var radiusCenter: SCNVector3?

    private var measureGroup: SCNNode?
    private var modelNode: SCNNode?
    private var worldVertices: [SCNVector3] = []
    private var snapThreshold: Float = 1

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
            if ext == "step" || ext == "stp" {
                let shape = try Shape.loadSTEP(from: url)
                guard let mesh = shape.mesh(linearDeflection: 0.1, angularDeflection: 0.2) else {
                    loadError = "STEP 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
            } else {
                guard let shape = Shape.readSTL(from: url.path) else {
                    loadError = "STL 文件读取失败。"
                    return
                }
                guard let mesh = shape.mesh(linearDeflection: 0.1) else {
                    loadError = "STL 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
            }

            let built = Self.buildScene(geometry: geometry)
            scene = built
            fileName = url.lastPathComponent

            let mNode = built.rootNode.childNode(withName: "model", recursively: true)
            modelNode = mNode
            if let mNode, let geo = mNode.geometry {
                let localVerts = Self.extractVertices(from: geo)
                worldVertices = localVerts.map { mNode.convertPosition($0, to: nil) }
                let (bbMin, bbMax) = geo.boundingBox
                let maxDim = max(max(bbMax.x - bbMin.x, bbMax.y - bbMin.y), bbMax.z - bbMin.z)
                snapThreshold = max(maxDim, 10) * 0.03
            }

            clearMeasure()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
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

    static func buildScene(geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()

        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.30, green: 0.62, blue: 0.38, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.5, alpha: 1.0)
        mat.shininess = 0.3
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        geometry.materials = [mat]

        let modelNode = SCNNode(geometry: geometry)
        modelNode.name = "model"

        let (bbMin, bbMax) = geometry.boundingBox
        let sizeX = bbMax.x - bbMin.x
        let sizeY = bbMax.y - bbMin.y
        let sizeZ = bbMax.z - bbMin.z
        let maxDim = max(max(sizeX, sizeY), sizeZ)
        let safeDim = max(maxDim, 1)

        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
        modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        scene.rootNode.addChildNode(modelNode)

        let edgeGeo = geometry.copy() as! SCNGeometry
        let edgeMat = SCNMaterial()
        edgeMat.diffuse.contents = UIColor(red: 0.12, green: 0.28, blue: 0.16, alpha: 0.9)
        edgeMat.fillMode = .lines
        edgeMat.lightingModel = .constant
        edgeGeo.materials = [edgeMat]
        let edgeNode = SCNNode(geometry: edgeGeo)
        edgeNode.name = "edges"
        edgeNode.scale = SCNVector3(1.002, 1.002, 1.002)
        modelNode.addChildNode(edgeNode)

        let camDist = safeDim * 2.0
        let origin = SCNVector3(0, 0, 0)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, camDist * 0.3, camDist)
        cameraNode.look(at: origin)
        scene.rootNode.addChildNode(cameraNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1200
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(camDist * 0.6, camDist, camDist * 0.6)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 500
        fillLight.color = UIColor(white: 0.85, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.7, camDist * 0.3, camDist * 0.5)
        fillNode.look(at: origin)
        scene.rootNode.addChildNode(fillNode)

        let backLight = SCNLight()
        backLight.type = .directional
        backLight.intensity = 600
        backLight.color = UIColor(white: 0.9, alpha: 1.0)
        let backNode = SCNNode()
        backNode.light = backLight
        backNode.position = SCNVector3(0, camDist * 0.5, -camDist)
        backNode.look(at: origin)
        scene.rootNode.addChildNode(backNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 250
        ambient.color = UIColor(white: 0.75, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Measure

    func handleTap(_ rawWorldPos: SCNVector3) {
        guard mode == .measure else { return }
        let snapped = snapToVertex(rawWorldPos)

        if pickedPoints.count >= measureType.requiredPoints {
            pickedPoints = [snapped]
        } else {
            pickedPoints.append(snapped)
        }

        computeResults()
        updateMeasureVisuals()
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

    func selectMeasureType(_ type: MeasureType) {
        measureType = type
        clearMeasure()
    }

    func clearMeasure() {
        pickedPoints = []
        distanceResult = nil
        angleResult = nil
        radiusResult = nil
        radiusCenter = nil
        measureGroup?.removeFromParentNode()
        measureGroup = nil
    }

    func toggleMeasureMode() {
        mode = mode == .measure ? .orbit : .measure
        if mode == .orbit { clearMeasure() }
    }

    private func snapToVertex(_ raw: SCNVector3) -> SCNVector3 {
        guard !worldVertices.isEmpty else { return raw }
        var best: SCNVector3?
        var bestDist: Float = snapThreshold
        for v in worldVertices {
            let dx = v.x - raw.x, dy = v.y - raw.y, dz = v.z - raw.z
            let d = (dx*dx + dy*dy + dz*dz).squareRoot()
            if d < bestDist { bestDist = d; best = v }
        }
        return best ?? raw
    }

    // MARK: - Visuals

    private func updateMeasureVisuals() {
        guard let scene else { return }
        measureGroup?.removeFromParentNode()

        let mNode = scene.rootNode.childNode(withName: "model", recursively: true)
        let (bbMin, bbMax) = mNode?.boundingBox ?? (SCNVector3(-10,-10,-10), SCNVector3(10,10,10))
        let maxDim = max(max(bbMax.x - bbMin.x, bbMax.y - bbMin.y), bbMax.z - bbMin.z)
        let markerR = max(maxDim, 10) * 0.012

        let group = SCNNode()
        group.name = "measure_group"

        for (i, point) in pickedPoints.enumerated() {
            let sphere = SCNSphere(radius: CGFloat(markerR))
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.systemRed
            mat.emission.contents = UIColor.systemRed
            mat.lightingModel = .constant
            sphere.materials = [mat]
            let marker = SCNNode(geometry: sphere)
            marker.position = point
            marker.name = "measure_dot"
            group.addChildNode(marker)

            let text = SCNText(string: "\(i + 1)", extrusionDepth: 0.2)
            text.font = UIFont.boldSystemFont(ofSize: 10)
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.lightingModel = .constant
            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(point.x, point.y + markerR * 2.2, point.z)
            let s = markerR * 0.04
            textNode.scale = SCNVector3(s, s, s)
            textNode.name = "measure_num"
            group.addChildNode(textNode)
        }

        if pickedPoints.count >= 2 {
            for i in 0..<pickedPoints.count-1 {
                addCylinderLine(from: pickedPoints[i], to: pickedPoints[i+1],
                                maxDim: maxDim, to: group)
            }
        }

        if measureType == .radius, let center = radiusCenter, let radius = radiusResult {
            let centerSphere = SCNSphere(radius: CGFloat(markerR * 0.8))
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
                            maxDim: maxDim, to: group, color: .systemBlue)
        }

        if let labelString = currentLabelString(), let anchor = labelAnchor() {
            let labelText = SCNText(string: labelString, extrusionDepth: 0.1)
            labelText.font = UIFont.boldSystemFont(ofSize: 8)
            labelText.firstMaterial?.diffuse.contents = UIColor.label
            labelText.firstMaterial?.lightingModel = .constant
            let labelNode = SCNNode(geometry: labelText)
            let labelScale = max(maxDim, 10) * 0.003
            labelNode.scale = SCNVector3(labelScale, labelScale, labelScale)
            labelNode.position = SCNVector3(anchor.x, anchor.y + markerR * 2, anchor.z)
            labelNode.name = "measure_label"
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            labelNode.constraints = [billboard]
            group.addChildNode(labelNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }

    private func addCylinderLine(from a: SCNVector3, to b: SCNVector3,
                                 maxDim: Float, to group: SCNNode,
                                 color: UIColor = .systemRed) {
        let dx = b.x-a.x, dy = b.y-a.y, dz = b.z-a.z
        let dist = (dx*dx + dy*dy + dz*dz).squareRoot()
        guard dist > 1e-6 else { return }
        let lineRadius = max(maxDim, 10) * 0.004
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
