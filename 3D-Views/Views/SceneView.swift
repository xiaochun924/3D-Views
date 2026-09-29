//
//  SceneView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct SceneView: UIViewRepresentable {
    let scene: SCNScene?
    var onMeasureTap: ((SCNVector3) -> Void)?
    var measureMode: Bool

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1.0)
        scnView.scene = scene

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        scnView.addGestureRecognizer(tap)
        context.coordinator.scnView = scnView
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        if scnView.scene !== scene {
            scnView.scene = scene
        }
        context.coordinator.measureMode = measureMode
        context.coordinator.onMeasureTap = onMeasureTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var scnView: SCNView?
        var measureMode = false
        var onMeasureTap: ((SCNVector3) -> Void)?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard measureMode, let scnView else { return }
            let point = gesture.location(in: scnView)

            let modelNode = scnView.scene?.rootNode.childNode(withName: "model", recursively: true)

            var hits: [SCNHitTestResult] = []
            if let modelNode {
                hits = scnView.hitTest(point, options: [
                    .rootNode: modelNode,
                    .searchMode: SCNHitTestSearchMode.all.rawValue,
                    .ignoreHiddenNodes: true
                ])
            }

            if hits.isEmpty {
                hits = scnView.hitTest(point, options: [
                    .searchMode: SCNHitTestSearchMode.all.rawValue
                ])
            }

            let worldPos: SCNVector3?
            if let modelNode {
                if let direct = hits.first(where: { $0.node === modelNode }) {
                    worldPos = direct.worldCoordinates
                } else if let any = hits.first {
                    worldPos = modelNode.convertPosition(any.localCoordinates, from: any.node)
                } else {
                    worldPos = nil
                }
            } else {
                worldPos = hits.first?.worldCoordinates
            }

            if let worldPos {
                onMeasureTap?(worldPos)
            }
        }
    }
}
