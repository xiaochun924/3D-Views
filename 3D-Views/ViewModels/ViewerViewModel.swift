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
                guard let mesh = shape.mesh(linearDeflection: 0.5, angularDeflection: 0.5) else {
                    loadError = "STEP 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
                let mat = SCNMaterial()
                mat.diffuse.contents = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
                mat.lightingModel = .blinn
                mat.isDoubleSided = true
                geometry.materials = [mat]
            } else {
                guard let shape = Shape.readSTL(from: url.path) else {
                    loadError = "STL 文件读取失败。"
                    return
                }
                guard let mesh = shape.mesh(linearDeflection: 0.5) else {
                    loadError = "STL 文件网格化失败。"
                    return
                }
                geometry = mesh.sceneKitGeometry()
                let mat = SCNMaterial()
                mat.diffuse.contents = UIColor(red: 0.7, green: 0.78, blue: 0.88, alpha: 1.0)
                mat.lightingModel = .blinn
                geometry.materials = [mat]
            }

            scene = Self.buildScene(geometry: geometry)
            fileName = url.lastPathComponent
            debugInfo = "已加载 \(url.lastPathComponent)"
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Scene builder

    static func buildScene(geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()

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

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, camDist * 0.3, camDist)
        cameraNode.look(at: origin)
        scene.rootNode.addChildNode(cameraNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 800
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(camDist, camDist, camDist)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.intensity = 400
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.8, camDist * 0.5, camDist * 0.5)
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 300
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    // MARK: - Measurement

    func handleTap(_ worldPos: SCNVector3) {
        guard mode == .measurePoint else { return }
        pickedPoints.append(worldPos)
        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            lastDistance = (dx*dx + dy*dy + dz*dz).squareRoot()
        } else if pickedPoints.count > 2 {
            pickedPoints = [worldPos]
            lastDistance = nil
        }
    }

    func resetMeasurement() {
        pickedPoints = []
        lastDistance = nil
    }
}
