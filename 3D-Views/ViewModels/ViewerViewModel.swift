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
    case measurePoint
}

@MainActor
final class ViewerViewModel: ObservableObject {

    @Published var fileName: String = ""
    @Published var loadedFileName: String = ""
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var debugInfo: String = ""
    @Published var scene: SCNScene?
    @Published var mode: InteractionMode = .orbit
    @Published var displayUnit: DisplayUnit = .millimeter
    @Published var pickedPoints: [SCNVector3] = []
    @Published var lastDistance: Float?

    private var measureGroup: SCNNode?

    // MARK: - File loading

    func loadFile(url: URL) async {
        isLoading = true
        loadError = nil
        loadedFileName = url.lastPathComponent
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
            debugInfo = "已加载 \(url.lastPathComponent)"
            pickedPoints = []
            lastDistance = nil
            measureGroup = nil
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Scene builder

    static func buildScene(geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()

        // Material: clean light gray with blinn lighting
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.82, green: 0.86, blue: 0.92, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.3, alpha: 1.0)
        mat.shininess = 0.4
        mat.lightingModel = .blinn
        mat.isDoubleSided = true
        geometry.materials = [mat]

        let modelNode = SCNNode(geometry: geometry)
        modelNode.name = "model"

        let (bbMin, bbMax) = geometry.boundingBox
        let center = SCNVector3(
            (bbMin.x + bbMax.x) / 2,
            (bbMin.y + bbMax.y) / 2,
            (bbMin.z + bbMax.z) / 2
        )
        modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        scene.rootNode.addChildNode(modelNode)

        let sizeX = bbMax.x - bbMin.x
        let sizeY = bbMax.y - bbMin.y
        let sizeZ = bbMax.z - bbMin.z
        let maxDim = max(max(sizeX, sizeY), sizeZ)
        let safeDim = max(maxDim, 1)
        let camDist = safeDim * 2.0
        let origin = SCNVector3(0, 0, 0)

        // Camera
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.wantsHDR = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, camDist * 0.3, camDist)
        cameraNode.look(at: origin)
        scene.rootNode.addChildNode(cameraNode)

        // Key light
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1200
        keyLight.castsShadow = true
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(camDist, camDist, camDist)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        // Fill light
        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.intensity = 600
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.8, camDist * 0.5, camDist * 0.5)
        scene.rootNode.addChildNode(fillNode)

        // Rim light for edge definition
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 800
        rimLight.color = UIColor(white: 0.9, alpha: 1.0)
        let rimNode = SCNNode()
        rimNode.light = rimLight
        rimNode.position = SCNVector3(-camDist * 0.3, camDist * 0.6, -camDist)
        rimNode.look(at: origin)
        scene.rootNode.addChildNode(rimNode)

        // Ambient
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Measurement

    func handleTap(_ worldPos: SCNVector3) {
        guard mode == .measurePoint else { return }
        pickedPoints.append(worldPos)
        if pickedPoints.count > 2 {
            pickedPoints = [worldPos]
        }
        updateMeasureMarkers()

        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            lastDistance = (dx*dx + dy*dy + dz*dz).squareRoot()
        } else {
            lastDistance = nil
        }
    }

    func resetMeasurement() {
        pickedPoints = []
        lastDistance = nil
        measureGroup?.removeFromParentNode()
        measureGroup = nil
    }

    private func updateMeasureMarkers() {
        guard let scene else { return }
        measureGroup?.removeFromParentNode()
        let group = SCNNode()
        group.name = "measure_group"

        let markerSize: Float = 1.5

        for (i, point) in pickedPoints.enumerated() {
            // Sphere marker
            let sphere = SCNSphere(radius: CGFloat(markerSize))
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.systemBlue
            mat.emission.contents = UIColor.systemBlue
            mat.lightingModel = .constant
            sphere.materials = [mat]
            let marker = SCNNode(geometry: sphere)
            marker.position = point
            marker.name = "measure_dot"
            group.addChildNode(marker)

            // Label
            let label = SCNText(string: "\(i + 1)", extrusionDepth: 0.3)
            label.font = UIFont.boldSystemFont(ofSize: 8)
            label.firstMaterial?.diffuse.contents = UIColor.white
            label.firstMaterial?.lightingModel = .constant
            let labelNode = SCNNode(geometry: label)
            labelNode.position = SCNVector3(point.x, point.y + markerSize * 2, point.z)
            labelNode.scale = SCNVector3(0.05, 0.05, 0.05)
            labelNode.name = "measure_label"
            group.addChildNode(labelNode)
        }

        // Line between two points
        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            let source = SCNGeometrySource(vertices: [a, b])
            let element = SCNGeometryElement(indices: [0, 1], primitiveType: .line)
            let lineGeo = SCNGeometry(sources: [source], elements: [element])
            let lineMat = SCNMaterial()
            lineMat.diffuse.contents = UIColor.systemBlue
            lineMat.lightingModel = .constant
            lineGeo.materials = [lineMat]
            let lineNode = SCNNode(geometry: lineGeo)
            lineNode.name = "measure_line"
            group.addChildNode(lineNode)

            // Distance label at midpoint
            let mid = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
            let dist = lastDistance ?? 0
            let text = SCNText(string: String(format: "%.2f %@", dist, displayUnit.rawValue), extrusionDepth: 0.2)
            text.font = UIFont.boldSystemFont(ofSize: 8)
            text.firstMaterial?.diffuse.contents = UIColor.systemBlue
            text.firstMaterial?.lightingModel = .constant
            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(mid.x, mid.y + 2, mid.z)
            textNode.scale = SCNVector3(0.05, 0.05, 0.05)
            textNode.name = "measure_dist_label"
            group.addChildNode(textNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }
}
