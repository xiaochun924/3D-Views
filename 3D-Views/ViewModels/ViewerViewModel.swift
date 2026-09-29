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
            debugInfo = "已加载"
            pickedPoints = []
            lastDistance = nil
            measureGroup = nil
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    static func buildScene(geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()

        // Material: steel blue with specular highlight
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.35, green: 0.55, blue: 0.75, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.6, alpha: 1.0)
        mat.shininess = 0.6
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        geometry.materials = [mat]

        let modelNode = SCNNode(geometry: geometry)
        modelNode.name = "model"

        // Edge overlay: same geometry as lines, dark color
        let edgeMat = SCNMaterial()
        edgeMat.diffuse.contents = UIColor(red: 0.1, green: 0.2, blue: 0.35, alpha: 0.8)
        edgeMat.fillMode = .lines
        edgeMat.lightingModel = .constant
        let edgeNode = SCNNode(geometry: geometry.copy() as? SCNGeometry ?? geometry)
        edgeNode.geometry?.materials = [edgeMat]
        edgeNode.name = "edges"
        modelNode.addChildNode(edgeNode)

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
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, camDist * 0.3, camDist)
        cameraNode.look(at: origin)
        scene.rootNode.addChildNode(cameraNode)

        // Key light - strong directional from top-right
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1500
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(camDist * 0.6, camDist, camDist * 0.6)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        // Fill light from left
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 500
        fillLight.color = UIColor(white: 0.85, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.7, camDist * 0.3, camDist * 0.5)
        fillNode.look(at: origin)
        scene.rootNode.addChildNode(fillNode)

        // Back light for rim
        let backLight = SCNLight()
        backLight.type = .directional
        backLight.intensity = 700
        backLight.color = UIColor(white: 0.9, alpha: 1.0)
        let backNode = SCNNode()
        backNode.light = backLight
        backNode.position = SCNVector3(0, camDist * 0.5, -camDist)
        backNode.look(at: origin)
        scene.rootNode.addChildNode(backNode)

        // Low ambient
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 200
        ambient.color = UIColor(white: 0.7, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    func handleTap(_ worldPos: SCNVector3) {
        guard mode == .measurePoint else { return }
        pickedPoints.append(worldPos)
        if pickedPoints.count > 2 { pickedPoints = [worldPos] }
        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            lastDistance = (dx*dx + dy*dy + dz*dz).squareRoot()
        } else {
            lastDistance = nil
        }
        updateMeasureMarkers()
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

        for point in pickedPoints {
            let sphere = SCNSphere(radius: 1.5)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.systemRed
            mat.emission.contents = UIColor.systemRed
            mat.lightingModel = .constant
            sphere.materials = [mat]
            let marker = SCNNode(geometry: sphere)
            marker.position = point
            group.addChildNode(marker)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }
}
