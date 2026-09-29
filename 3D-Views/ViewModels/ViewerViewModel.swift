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
        keyNode.position = SCNVector3(camDist, camDist, camDist)
        keyNode.look(at: origin)
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.intensity = 600
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-camDist * 0.8, camDist * 0.5, camDist * 0.5)
        scene.rootNode.addChildNode(fillNode)

        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 800
        rimLight.color = UIColor(white: 0.9, alpha: 1.0)
        let rimNode = SCNNode()
        rimNode.light = rimLight
        rimNode.position = SCNVector3(-camDist * 0.3, camDist * 0.6, -camDist)
        rimNode.look(at: origin)
        scene.rootNode.addChildNode(rimNode)

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

        for (i, point) in pickedPoints.enumerated() {
            let sphere = SCNSphere(radius: 1.5)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.systemBlue
            mat.emission.contents = UIColor.systemBlue
            mat.lightingModel = .constant
            sphere.materials = [mat]
            let marker = SCNNode(geometry: sphere)
            marker.position = point
            marker.name = "measure_dot"
            group.addChildNode(marker)

            let label = SCNText(string: "\(i + 1)", extrusionDepth: 0.3)
            label.font = UIFont.boldSystemFont(ofSize: 8)
            label.firstMaterial?.diffuse.contents = UIColor.white
            label.firstMaterial?.lightingModel = .constant
            let labelNode = SCNNode(geometry: label)
            labelNode.position = SCNVector3(point.x, point.y + 3, point.z)
            labelNode.scale = SCNVector3(0.05, 0.05, 0.05)
            group.addChildNode(labelNode)
        }

        if pickedPoints.count == 2, let dist = lastDistance {
            let a = pickedPoints[0], b = pickedPoints[1]
            let mid = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)

            // Cylinder between points
            let cylinder = SCNCylinder(radius: 0.4, height: CGFloat(dist))
            let cylMat = SCNMaterial()
            cylMat.diffuse.contents = UIColor.systemBlue
            cylMat.lightingModel = .constant
            cylinder.materials = [cylMat]
            let cylNode = SCNNode(geometry: cylinder)
            cylNode.position = mid
            cylNode.look(at: b)
            cylNode.eulerAngles.x += Float.pi / 2
            group.addChildNode(cylNode)

            // Distance label
            let distStr = String(format: "%.2f", dist) + " " + displayUnit.rawValue
            let text = SCNText(string: distStr, extrusionDepth: 0.2)
            text.font = UIFont.boldSystemFont(ofSize: 8)
            text.firstMaterial?.diffuse.contents = UIColor.systemBlue
            text.firstMaterial?.lightingModel = .constant
            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(mid.x, mid.y + 3, mid.z)
            textNode.scale = SCNVector3(0.05, 0.05, 0.05)
            group.addChildNode(textNode)
        }

        scene.rootNode.addChildNode(group)
        measureGroup = group
    }
}
