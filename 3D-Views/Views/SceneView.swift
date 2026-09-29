//
//  SceneView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct SceneView: UIViewRepresentable {
    @ObservedObject var viewModel: ViewerViewModel

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        let scene = SCNScene()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = UIColor.systemBackground
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.antialiasingMode = .multisampling4X

        // Camera positioned diagonally, looking at origin.
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 60
        cameraNode.position = SCNVector3(120, 90, 120)
        cameraNode.look(at: SCNVector3(0, 0, 0),
                        up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        // Ambient + directional lights.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 1000
        scene.rootNode.addChildNode(ambient)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light?.type = .directional
        dirLight.light?.intensity = 1500
        dirLight.position = SCNVector3(50, 100, 50)
        dirLight.look(at: SCNVector3(0, 0, 0),
                      up: SCNVector3(0, 1, 0),
                      localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(dirLight)

        // Simple floor plane for spatial reference.
        let floor = SCNPlane(width: 300, height: 300)
        floor.firstMaterial?.diffuse.contents = UIColor.systemGray5
        floor.firstMaterial?.isDoubleSided = true
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -40, 0)
        floorNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(floorNode)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)

        context.coordinator.scnView = scnView
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        if let newRoot = viewModel.sceneRoot, newRoot !== context.coordinator.loadedRoot {
            context.coordinator.loadedRoot?.removeFromParentNode()
            scnView.scene?.rootNode.addChildNode(newRoot)
            context.coordinator.loadedRoot = newRoot
            context.coordinator.frameCamera(to: newRoot, in: scnView)
        }
        context.coordinator.viewModel = viewModel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scnView: SCNView?
        var loadedRoot: SCNNode?
        var viewModel: ViewerViewModel

        init(viewModel: ViewerViewModel) {
            self.viewModel = viewModel
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scnView else { return }
            let point = gesture.location(in: scnView)

            let hits = scnView.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreChildNodes: false
            ])
            guard let hit = hits.first else { return }
            let worldPos = hit.worldCoordinates
            guard let root = loadedRoot else { return }
            let local = root.convertPosition(worldPos, from: nil)

            guard viewModel.mode == .measurePoint else { return }
            let countBefore = viewModel.pickedPoints.count
            viewModel.addPickedPoint(local)
            if countBefore == 2 || viewModel.pickedPoints.isEmpty {
                clearMarkers(in: root)
            }
            addMarker(at: local, in: root)
            if viewModel.pickedPoints.count == 2 {
                drawMeasurementLine(from: viewModel.pickedPoints[0],
                                     to: viewModel.pickedPoints[1],
                                     in: root)
            }
        }

        private func markerNodeName(_ index: Int) -> String { "measure-marker-\(index)" }
        private let lineNodeName = "measure-line"

        private func clearMarkers(in root: SCNNode) {
            root.childNodes.filter {
                $0.name?.hasPrefix("measure-marker-") == true || $0.name == lineNodeName
            }.forEach { $0.removeFromParentNode() }
        }

        private func addMarker(at local: SCNVector3, in root: SCNNode) {
            let geo = SCNSphere(radius: 2)
            geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
            let node = SCNNode(geometry: geo)
            node.position = local
            node.name = markerNodeName(root.childNodes.filter { $0.name?.hasPrefix("measure-marker-") == true }.count)
            root.addChildNode(node)
        }

        private func drawMeasurementLine(from a: SCNVector3, to b: SCNVector3, in root: SCNNode) {
            let source = SCNGeometrySource(vertices: [a, b])
            let element = SCNGeometryElement(indices: [0, 1], primitiveType: .line)
            let geo = SCNGeometry(sources: [source], elements: [element])
            geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
            let node = SCNNode(geometry: geo)
            node.name = lineNodeName
            root.addChildNode(node)
        }

        func frameCamera(to node: SCNNode, in scnView: SCNView) {
            let box = node.boundingBox
            let center = SCNVector3(
                (box.min.x + box.max.x) / 2,
                (box.min.y + box.max.y) / 2,
                (box.min.z + box.max.z) / 2
            )
            let extent = box.max.x - box.min.x
            let dist = max(extent * 1.5 + 30, 80)

            guard let camera = scnView.pointOfView else { return }
            let worldCenter = node.convertPosition(center, to: nil)
            camera.position = SCNVector3(worldCenter.x + dist,
                                         worldCenter.y + dist * 0.7,
                                         worldCenter.z + dist)
            camera.look(at: worldCenter,
                        up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
        }
    }
}
