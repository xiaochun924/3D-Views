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
        scnView.antialiasingMode = .multisampling8X
        scnView.backgroundColor = UIColor.systemBackground
        scnView.scene = scene

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
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
    final class Coordinator: NSObject {
        weak var scnView: SCNView?
        var measureMode = false
        var onMeasureTap: ((SCNVector3) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard measureMode, let scnView else { return }
            let point = gesture.location(in: scnView)
            let hits = scnView.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true
            ])
            guard let hit = hits.first(where: { $0.node.name?.hasPrefix("measure_") != true }) else { return }
            onMeasureTap?(hit.worldCoordinates)
        }
    }
}
