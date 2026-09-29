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

struct MeasureResult {
    let pointA: SCNVector3
    let pointB: SCNVector3
    var distance: Float {
        let dx = pointB.x - pointA.x
        let dy = pointB.y - pointA.y
        let dz = pointB.z - pointA.z
        return (dx*dx + dy*dy + dz*dz).squareRoot()
    }
    var deltaX: Float { pointB.x - pointA.x }
    var deltaY: Float { pointB.y - pointA.y }
    var deltaZ: Float { pointB.z - pointA.z }
}

@MainActor
final class ViewerViewModel: ObservableObject {

    @Published var fileName: String = ""
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var scene: SCNScene?
    @Published var mode: InteractionMode = .orbit
    @Published var displayUnit: DisplayUnit = .millimeter
    @Published var pickedPoints: [SCNVector3] = []
    @Published var measureResult: MeasureResult?

    private var measureGroup: SCNNode?
    private var modelNode: SCNNode?
    private var worldVertices: [SCNVector3] = []
    private var snapThreshold: Float = 1

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

            // Cache model node and vertices for snapping
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

    // MARK: - Vertex extraction

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

        // Green material like reference CAD app
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

        // Edge overlay
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

    // MARK: - Measure (SolidWorks style with vertex snapping)

    func handleTap(_ rawWorldPos: SCNVector3) {
        guard mode == .measure else { return }

        // Snap to nearest vertex within threshold
        let snapped = snapToVertex(rawWorldPos)

        if pickedPoints.count >= 2 {
            pickedPoints = [snapped]
            measureResult = nil
        } else {
            pickedPoints.append(snapped)
        }

        if pickedPoints.count == 2 {
            measureResult = MeasureResult(
                pointA: pickedPoints[0],
                pointB: pickedPoints[1]
            )
        }

        updateMeasureVisuals()
    }

    private func snapToVertex(_ raw: SCNVector3) -> SCNVector3 {
        guard !worldVertices.isEmpty else { return raw }

        var best: SCNVector3?
        var bestDist: Float = snapThreshold

        for v in worldVertices {
            let dx = v.x - raw.x
            let dy = v.y - raw.y
            let dz = v.z - raw.z
            let d = (dx*dx + dy*dy + dz*dz).squareRoot()
            if d < bestDist {
                bestDist = d
                best = v
            }
        }
        return best ?? raw
    }

    func clearMeasure() {
        pickedPoints = []
        measureResult = nil
        measureGroup?.removeFromParentNode()
        measureGroup = nil
    }

    func toggleMeasureMode() {
        mode = mode == .measure ? .orbit : .measure
        if mode == .orbit {
            clearMeasure()
        }
    }

    // MARK: - Measure visuals

    private func updateMeasureVisuals() {
        guard let scene else { return }
        measureGroup?.removeFromParentNode()

        let modelNode = scene.rootNode.childNode(withName: "model", recursively: true)
        let (bbMin, bbMax) = modelNode?.boundingBox ?? (SCNVector3(-10,-10,-10), SCNVector3(10,10,10))
        let maxDim = max(max(bbMax.x - bbMin.x, bbMax.y - bbMin.y), bbMax.z - bbMin.z)
        let markerR = max(maxDim, 10) * 0.012

        let group = SCNNode()
        group.name = "measure_group"

        for (i, point) in pickedPoints.enumerated() {
            // Sphere marker
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

            // Number label
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

        // Cylinder line between two points
        if let result = measureResult {
            let a = result.pointA
            let b = result.pointB
            let dist = result.distance
            let lineRadius = max(maxDim, 10) * 0.004

            let cylinder = SCNCylinder(radius: CGFloat(lineRadius), height: CGFloat(dist))
            let cylMat = SCNMaterial()
            cylMat.diffuse.contents = UIColor.systemRed
            cylMat.lightingModel = .constant
            cylinder.materials = [cylMat]
            let cylNode = SCNNode(geometry: cylinder)
            cylNode.name = "measure_line"
            cylNode.position = SCNVector3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2)
            // Orient cylinder (along Y) toward point b
            cylNode.look(at: b)
            cylNode.eulerAngles.x += Float.pi / 2
            group.addChildNode(cylNode)

            // 3D distance label at midpoint, billboarded
            let labelText = SCNText(string: displayUnit.format(dist), extrusionDepth: 0.1)
            labelText.font = UIFont.boldSystemFont(ofSize: 8)
            labelText.firstMaterial?.diffuse.contents = UIColor.label
            labelText.firstMaterial?.lightingModel = .constant
            let labelNode = SCNNode(geometry: labelText)
            let labelScale = max(maxDim, 10) * 0.003
            labelNode.scale = SCNVector3(labelScale, labelScale, labelScale)
            labelNode.name = "measure_label"
            // Offset slightly above the line
            let mid = SCNVector3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2)
            labelNode.position = SCNVector3(mid.x, mid.y + markerR * 1.5, mid.z)
            // Billboard constraint to always face camera
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            labelNode.constraints = [billboard]
            group.addChildNode(labelNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }
}
