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
    /// Preselect: a press-and-hold reports where the finger is *before* committing,
    /// so the entity about to be measured can be highlighted first.
    var onPreview: ((CGPoint, SCNView) -> Void)?
    /// The hold was lifted, so the highlighted entity should be committed.
    var onPreviewCommitted: ((SCNView) -> Void)?
    /// The hold was cancelled by the system (an incoming call, a competing gesture).
    /// Kept separate from the commit above so an interrupted press never measures
    /// whatever happened to be highlighted at the time.
    var onPreviewCancelled: ((SCNView) -> Void)?
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

        // Press and hold to preselect. On a touch screen there is no cursor to hover
        // with, so the second state every desktop CAD app gets from `mouseMoved` has to
        // come from a deliberate press: hold, slide until the highlight is on the face
        // or edge you meant, then lift. The hold is long enough not to fire during an
        // ordinary tap and short enough not to feel like a wait.
        //
        // While the hold is active the camera control is switched off, otherwise the
        // same drag would orbit the model out from under the highlight.
        let hold = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.25
        // `allowableMovement` only gates recognition; once the hold has begun the finger
        // may slide as far as it likes. Keeping it small is what separates the two
        // gestures: a deliberate drag moves further than this before the timer elapses,
        // so the hold fails and the orbit proceeds, while pressing and holding nearly
        // still enters preview and can then be slid onto the wanted entity.
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = false
        hold.delegate = context.coordinator
        scnView.addGestureRecognizer(hold)

        // A press that becomes a hold must not *also* commit a tap on release, and a
        // genuine tap must still commit. Making the tap wait for the hold to fail gets
        // both: the hold fails only when the touch lifts before the timer, which is
        // exactly when the tap should fire. This adds no felt delay, because a tap
        // recognizer only reports on touch-up anyway.
        tap.require(toFail: hold)

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
        context.coordinator.onPreview = onPreview
        context.coordinator.onPreviewCommitted = onPreviewCommitted
        context.coordinator.onPreviewCancelled = onPreviewCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var scnView: SCNView?
        var measureMode = false
        var onMeasureTap: ((CGPoint, SCNView) -> Void)?
        var onPreview: ((CGPoint, SCNView) -> Void)?
        var onPreviewCommitted: ((SCNView) -> Void)?
        var onPreviewCancelled: ((SCNView) -> Void)?
        /// Whether the camera control was on before the hold switched it off, so it is
        /// only restored when this gesture was the one that disabled it.
        private var cameraControlSuspended = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard measureMode, let scnView = gesture.view as? SCNView else { return }
            onMeasureTap?(gesture.location(in: scnView), scnView)
        }

        @objc func handleHold(_ gesture: UILongPressGestureRecognizer) {
            guard measureMode, let scnView = gesture.view as? SCNView else { return }

            switch gesture.state {
            case .began:
                if scnView.allowsCameraControl {
                    scnView.allowsCameraControl = false
                    cameraControlSuspended = true
                }
                onPreview?(gesture.location(in: scnView), scnView)

            case .changed:
                onPreview?(gesture.location(in: scnView), scnView)

            case .ended:
                // Lifting commits the highlighted entity. Because the tap waits for this
                // gesture to fail, a hold that began never also delivers a tap, so this
                // is the only commit path for it.
                onPreviewCommitted?(scnView)
                resumeCameraControl(scnView)

            default:
                // Cancelled or failed: drop the highlight without measuring.
                onPreviewCancelled?(scnView)
                resumeCameraControl(scnView)
            }
        }

        private func resumeCameraControl(_ scnView: SCNView) {
            guard cameraControlSuspended else { return }
            cameraControlSuspended = false
            scnView.allowsCameraControl = true
        }
    }
}
