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

            scene = Self.buildScene(geometry: geometry)
            fileName = url.lastPathComponent
            clearMeasure()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
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

        // Center model
        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
        modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        scene.rootNode.addChildNode(modelNode)

        // Edge overlay: wireframe copy, slightly larger to avoid z-fighting
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

        // Camera
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, camDist * 0.3, camDist)
        cameraNode.look(at: origin)
        scene.rootNode.addChildNode(cameraNode)

        // Key light
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1200
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(camDist * 0.6, camDist, camDist * 0.6)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        // Fill light
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 500
        fillLight.color = UIColor(white: 0.85, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.7, camDist * 0.3, camDist * 0.5)
        fillNode.look(at: origin)
        scene.rootNode.addChildNode(fillNode)

        // Back light
        let backLight = SCNLight()
        backLight.type = .directional
        backLight.intensity = 600
        backLight.color = UIColor(white: 0.9, alpha: 1.0)
        let backNode = SCNNode()
        backNode.light = backLight
        backNode.position = SCNVector3(0, camDist * 0.5, -camDist)
        backNode.look(at: origin)
        scene.rootNode.addChildNode(backNode)

        // Ambient
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 250
        ambient.color = UIColor(white: 0.75, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Measure (SolidWorks style)

    func handleTap(_ worldPos: SCNVector3) {
        guard mode == .measure else { return }

        if pickedPoints.count >= 2 {
            // Start new measurement
            pickedPoints = [worldPos]
            measureResult = nil
        } else {
            pickedPoints.append(worldPos)
        }

        if pickedPoints.count == 2 {
            measureResult = MeasureResult(
                pointA: pickedPoints[0],
                pointB: pickedPoints[1]
            )
        }

        updateMeasureVisuals()
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

    private func updateMeasureVisuals() {
        guard let scene else { return }
        measureGroup?.removeFromParentNode()

        // Marker size based on model size
        let modelNode = scene.rootNode.childNode(withName: "model", recursively: true)
        let (bbMin, bbMax) = modelNode?.boundingBox ?? (SCNVector3(-10,-10,-10), SCNVector3(10,10,10))
        let maxDim = max(max(bbMax.x - bbMin.x, bbMax.y - bbMin.y), bbMax.z - bbMin.z)
        let markerR = max(maxDim, 10) * 0.015

        let group = SCNNode()
        group.name = "measure_group"

        for (i, point) in pickedPoints.enumerated() {
            // Sphere
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
            textNode.position = SCNVector3(point.x, point.y + markerR * 2, point.z)
            let s = markerR * 0.04
            textNode.scale = SCNVector3(s, s, s)
            textNode.name = "measure_num"
            group.addChildNode(textNode)
        }

        // Line between two points
        if let result = measureResult {
            let a = result.pointA
            let b = result.pointB
            let source = SCNGeometrySource(vertices: [a, b])
            let indices: [Int32] = [0, 1]
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let lineGeo = SCNGeometry(sources: [source], elements: [element])
            let lineMat = SCNMaterial()
            lineMat.diffuse.contents = UIColor.systemRed
            lineMat.lightingModel = .constant
            lineGeo.materials = [lineMat]
            let lineNode = SCNNode(geometry: lineGeo)
            lineNode.name = "measure_line"
            group.addChildNode(lineNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }
}
