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

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(150, 150, 150)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

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
                .ignoreChildNodesHitTest: false
            ])
            guard let hit = hits.first else { return }
            let worldPos = hit.worldCoordinates
            guard let root = loadedRoot else { return }
            let local = root.convertPosition(worldPos, from: nil)

            Task { @MainActor in
                guard self.viewModel.mode == .measurePoint else { return }
                let countBefore = self.viewModel.pickedPoints.count
                self.viewModel.addPickedPoint(local)
                if countBefore == 2 || self.viewModel.pickedPoints.isEmpty {
                    self.clearMarkers(in: root)
                }
                self.addMarker(at: local, in: root)
                if self.viewModel.pickedPoints.count == 2 {
                    self.drawMeasurementLine(from: self.viewModel.pickedPoints[0],
                                              to: self.viewModel.pickedPoints[1],
                                              in: root)
                }
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
            geo.firstMaterial?.lineWidth = 3
            let node = SCNNode(geometry: geo)
            node.name = lineNodeName
            root.addChildNode(node)
        }

        func frameCamera(to node: SCNNode, in scnView: SCNView) {
            let (min, max) = node.boundingBox
            let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
            let extent = max.x - min.x
            let dist = CGFloat(extent) * 2.5 + 50

            guard let camera = scnView.pointOfView else { return }
            camera.position = SCNVector3(Float(dist), Float(dist * 0.8), Float(dist))
            camera.look(at: node.convertPosition(center, to: nil))
        }
    }
}
