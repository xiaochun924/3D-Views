//
//  SceneView.swift
//  Views
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
    /// Fired right after a new scene is handed to the renderer, so the view model can point
    /// the renderer at the scene's own camera and frame the part — the viewport it needs
    /// to solve that against only exists once the scene is live. See
    /// `ViewerViewModel.claimPointOfView`.
    var onSceneAssigned: ((SCNView, SCNScene) -> Void)?
    /// Preselect: a press-and-hold reports where the finger is *before* committing,
    /// so the entity about to be measured can be highlighted first.
    var onPreview: ((CGPoint, SCNView) -> Void)?
    /// The hold was lifted, so the highlighted entity should be committed.
    var onPreviewCommitted: ((SCNView) -> Void)?
    /// The hold was cancelled by the system (an incoming call, a competing gesture).
    /// Kept separate from the commit above so an interrupted press never measures
    /// whatever happened to be highlighted at the time.
    var onPreviewCancelled: ((SCNView) -> Void)?
    /// One-finger drag: orbit the camera about the model. Reported as the movement since
    /// the previous event, so the view model can integrate it however it likes.
    var onOrbit: ((CGFloat, CGFloat, SCNView) -> Void)?
    /// Two-finger drag: pan. Two fingers rather than one because on a touch screen one
    /// finger already means "turn the model", and overloading it would make the two
    /// impossible to tell apart.
    var onPan: ((CGFloat, CGFloat, SCNView) -> Void)?
    /// Pinch: dolly in and out.
    var onZoom: ((CGFloat, SCNView) -> Void)?
    var measureMode: Bool

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        // SceneKit's own camera control is deliberately off. Its controller installs a
        // camera of its own carrying `zNear = 1` / `zFar = 100`, which silently replaces
        // whatever `buildScene` configured and clips any part larger than a few dozen
        // units away entirely. It also reinstalls that camera whenever the flag is
        // toggled, so it cannot be corrected once at setup. Driving the camera ourselves
        // — see the recognizers below and `ViewerViewModel.applyCamera` — is the only way
        // the depth range, field of view and framing stay as configured.
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        // iOS defaults this to `.none` (macOS defaults to 4x), so without an explicit
        // setting every edge on every iPhone and iPad is badly aliased.
        scnView.antialiasingMode = .multisampling4X
        // Replaced per trait in `updateUIView`. The literal below is only the value the
        // very first frame renders with, before the environment is available.
        scnView.backgroundColor = Self.viewportBackground(for: .light)
        // Without this the view can render at 1× on a 3× retina screen and be scaled up,
        // which is the single biggest cause of a "blurry / unclear" model on iOS — every
        // edge becomes a soft smear regardless of AA or mesh quality. UIView's default
        // would eventually be right, but for an SCNView created off-window it is not,
        // and the first frame (and every screenshot) renders at the wrong scale.
        scnView.contentScaleFactor = UIScreen.main.scale
        scnView.scene = scene

        // With camera control off nothing else would pick a camera, and a scene handed over
        // outside `updateUIView` would never get one — so the first frame would be blank.
        if let scene, let camera = scene.rootNode.childNode(withName: "camera", recursively: true) {
            scnView.pointOfView = camera
        }

        // Simultaneous recognition is what lets the camera gestures run alongside the tap
        // and the hold, which are otherwise treated as competitors for the same touch.
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

        // Orbit: one finger drags the camera about the model. The recognizer also drives
        // two-finger panning, and pan and orbit cancel each other exactly the way the
        // default camera controller does — a rotation ends, a translation begins.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        scnView.addGestureRecognizer(pan)

        // Pinch: dolly. Separate from the pan recognizer so a pinch zoom doesn't also
        // read as a drag and slew the target.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        scnView.addGestureRecognizer(pinch)

        // Held so the hold can switch them off while a preselect is in progress: otherwise
        // sliding the finger to the wanted face would also orbit the model out from under
        // it. Saved rather than looked up in `gestureRecognizers`, which would have to
        // pick the pan and pinch out of a list that also holds the tap and the hold.
        context.coordinator.cameraGestures = [pan, pinch]

        context.coordinator.scnView = scnView
        onViewReady?(scnView)
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        // Resolved from the environment rather than from a dynamic `UIColor` because
        // SceneKit does not re-resolve a dynamic colour once it has been handed the
        // background: the viewport would keep the light value after the system switched
        // to dark until something else forced a redraw. Reading the environment here
        // makes SwiftUI call back on every appearance change, which is exactly the
        // signal needed.
        scnView.backgroundColor = Self.viewportBackground(for: context.environment.colorScheme)

        if scnView.scene !== scene {
            scnView.scene = scene
            if let scene { onSceneAssigned?(scnView, scene) }
        }
        context.coordinator.measureMode = measureMode
        context.coordinator.onMeasureTap = onMeasureTap
        context.coordinator.onPreview = onPreview
        context.coordinator.onPreviewCommitted = onPreviewCommitted
        context.coordinator.onPreviewCancelled = onPreviewCancelled
        context.coordinator.onOrbit = onOrbit
        context.coordinator.onPan = onPan
        context.coordinator.onZoom = onZoom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// The viewport's own backdrop, one value per appearance.
    ///
    /// Kept here rather than in the scene's background so the very first frame — before
    /// any geometry or environment exists — already matches the surrounding chrome. The
    /// light value is the original slate the viewer was designed against; the dark one
    /// is a near-black with a touch of blue, so a light-grey part still separates from
    /// it while the chrome above stays legible.
    static func viewportBackground(for scheme: ColorScheme) -> UIColor {
        switch scheme {
        case .dark:
            return UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        default:
            return UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var scnView: SCNView?
        var measureMode = false
        var onMeasureTap: ((CGPoint, SCNView) -> Void)?
        var onPreview: ((CGPoint, SCNView) -> Void)?
        var onPreviewCommitted: ((SCNView) -> Void)?
        var onPreviewCancelled: ((SCNView) -> Void)?
        var onOrbit: ((CGFloat, CGFloat, SCNView) -> Void)?
        var onPan: ((CGFloat, CGFloat, SCNView) -> Void)?
        var onZoom: ((CGFloat, SCNView) -> Void)?
        /// The camera recognizers, switched off for the duration of a press-and-hold so a
        /// slide onto the wanted face preselects instead of orbiting.
        var cameraGestures: [UIGestureRecognizer] = []
        /// Set while the two fingers are actually scaling, so the pan that rides along
        /// with every pinch is ignored. See `handlePinch`.
        private var isPinching = false

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
                setCameraGestures(enabled: false)
                onPreview?(gesture.location(in: scnView), scnView)

            case .changed:
                onPreview?(gesture.location(in: scnView), scnView)

            case .ended:
                // Lifting commits the highlighted entity. Because the tap waits for this
                // gesture to fail, a hold that began never also delivers a tap, so this
                // is the only commit path for it.
                onPreviewCommitted?(scnView)
                setCameraGestures(enabled: true)

            default:
                // Cancelled or failed: drop the highlight without measuring.
                onPreviewCancelled?(scnView)
                setCameraGestures(enabled: true)
            }
        }

        private func setCameraGestures(enabled: Bool) {
            for gesture in cameraGestures { gesture.isEnabled = enabled }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let scnView = gesture.view as? SCNView else { return }
            guard gesture.state == .began || gesture.state == .changed else { return }

            let movement = gesture.translation(in: scnView)
            // Consumed either way, so the movement banked while a pinch was in progress
            // does not land as a jump the moment it ends.
            gesture.setTranslation(.zero, in: scnView)

            // A real pinch owns both fingers; the slight travel that comes with it must not
            // also slew the target, or the part drifts while it is being zoomed.
            guard !isPinching else { return }

            if gesture.numberOfTouches >= 2 {
                onPan?(movement.x, movement.y, scnView)
            } else {
                onOrbit?(movement.x, movement.y, scnView)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scnView = gesture.view as? SCNView else { return }

            switch gesture.state {
            case .began, .changed:
                let scale = gesture.scale
                // Reset so the next event reports the change since now, not since the pinch
                // began; otherwise the zoom compounds with every event.
                gesture.scale = 1
                // Two fingers that merely travel together keep a scale of 1 and are a pan,
                // not a zoom — the pinch recognizer still fires for them.
                guard abs(scale - 1) > 0.001 else { return }
                isPinching = true
                onZoom?(scale, scnView)
            default:
                isPinching = false
            }
        }
    }
}
