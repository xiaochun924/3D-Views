//
//  SceneView.swift
//  3D-Views
//

import SwiftUI
import SceneKit

struct SceneView: UIViewRepresentable {
    let scene: SCNScene?
    /// Screen point plus the live renderer. Picking is done in the view model, in
    /// screen space, so the tap must not be resolved to a world point here.
    var onMeasureTap: ((CGPoint, SCNView) -> Void)?
    /// Hands the renderer to the view model so it can size annotations in screen
    /// space and command the camera the view is actually rendering through.
    var onViewReady: ((SCNView) -> Void)?
    var measureMode: Bool

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        // iOS defaults this to `.none` (macOS defaults to 4x), so without an explicit
        // setting every edge on every iPhone and iPad is badly aliased.
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)
        scnView.scene = scene

        // Simultaneous recognition is what lets SceneKit's own camera-control pans and
        // pinches keep working alongside this tap.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        scnView.addGestureRecognizer(tap)

        context.coordinator.scnView = scnView
        onViewReady?(scnView)
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
        var onMeasureTap: ((CGPoint, SCNView) -> Void)?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard measureMode, let scnView = gesture.view as? SCNView else { return }
            onMeasureTap?(gesture.location(in: scnView), scnView)
        }
    }
}
