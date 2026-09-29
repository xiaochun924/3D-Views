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

        // Ambient light so the scene isn't pitch black.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 800
        scene.rootNode.addChildNode(ambient)

        // Simple grid floor for spatial reference.
        let grid = SCNGrid()
        let gridNode = SCNNode()
        gridNode.geometry = grid
        gridNode.position = SCNVector3(0, -25, 0)
        scene.rootNode.addChildNode(gridNode)

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
            let geo = SCNSphere(radius: 1.5)
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
            let (min, max) = node.boundingBox
            let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
            let extent = max.x - min.x
            // Ensure a minimum distance so tiny models aren't glued to camera.
            let dist = max(CGFloat(extent) * 1.5 + 30, 60)

            guard let camera = scnView.pointOfView else { return }
            let worldCenter = node.convertPosition(center, to: nil)
            camera.position = SCNVector3(Float(worldCenter.x + dist),
                                         Float(worldCenter.y + dist * 0.7),
                                         Float(worldCenter.z + dist))
            // localFront (0,0,-1) = the camera's viewing direction points AT the target.
            camera.look(at: worldCenter,
                        up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
        }
    }
}
