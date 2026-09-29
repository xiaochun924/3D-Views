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

    // MARK: - Loaded document

    @Published var fileName: String = ""
    @Published var loadedFileName: String = ""
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var entityCount: Int = 0
    @Published var triangleCount: Int = 0
    @Published var lengthUnit: String = "millimeter"
    @Published var debugInfo: String = ""

    /// The root node holding the loaded CAD geometry.
    @Published var sceneRoot: SCNNode?

    // MARK: - Interaction

    @Published var mode: InteractionMode = .orbit
    @Published var displayUnit: DisplayUnit = .millimeter

    /// Picked points in model coordinates.
    @Published var pickedPoints: [SCNVector3] = []
    @Published var lastDistance: Float?

    // MARK: - Test cube (no OCCT needed)

    func loadTestCube() async {
        isLoading = true
        loadError = nil
        loadedFileName = "test-cube"
        defer { isLoading = false }

        let root = SCNNode()
        root.name = "CADRoot"

        // Big bright cube with simple diffuse material (not PBR).
        let box = SCNBox(width: 80, height: 80, length: 80, chamferRadius: 4)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemRed
        material.lightingModel = .blinn
        material.specular.contents = UIColor.white
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.name = "test-cube"
        root.addChildNode(node)

        let boxBounds = root.boundingBox
        let center = SCNVector3(
            (boxBounds.min.x + boxBounds.max.x) / 2,
            (boxBounds.min.y + boxBounds.max.y) / 2,
            (boxBounds.min.z + boxBounds.max.z) / 2
        )
        root.position = SCNVector3(-center.x, -center.y, -center.z)

        self.sceneRoot = root
        self.fileName = "Test Cube"
        self.triangleCount = 12
        self.entityCount = 1
        self.pickedPoints = []
        self.lastDistance = nil
        self.debugInfo = "cube added, root children: \(root.childNodes.count)"
    }

    // MARK: - Loading

    func loadFile(url: URL) async {
        isLoading = true
        loadError = nil
        loadedFileName = url.lastPathComponent
        defer { isLoading = false }

        let ext = url.pathExtension.lowercased()
        guard ext == "step" || ext == "stp" || ext == "stl" else {
            loadError = "Unsupported file type. Please open a .step, .stp or .stl file."
            return
        }

        let needsAccess = url.startAccessingSecurityScopedResource()
        let localURL: URL
        do {
            let fm = FileManager.default
            let destDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Incoming", isDirectory: true)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
            localURL = dest
        } catch {
            if needsAccess { url.stopAccessingSecurityScopedResource() }
            loadError = "Cannot read file: \(error.localizedDescription)"
            return
        }
        if needsAccess { url.stopAccessingSecurityScopedResource() }

        do {
            let root = SCNNode()
            root.name = "CADRoot"

            if ext == "step" || ext == "stp" {
                let shape = try Shape.loadSTEP(from: localURL)
                self.lengthUnit = "millimeter"

                guard let mesh = shape.mesh(linearDeflection: 0.1, angularDeflection: 0.5) else {
                    loadError = "Failed to tessellate the STEP model."
                    return
                }

                let geometry = mesh.sceneKitGeometry()
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
                material.lightingModel = .blinn
                geometry.materials = [material]

                let partNode = SCNNode(geometry: geometry)
                partNode.name = "step-part"
                root.addChildNode(partNode)

                self.triangleCount = mesh.triangleCount
                self.entityCount = 1
            } else {
                guard let shape = Shape.readSTL(from: localURL.path) else {
                    loadError = "Failed to read STL file."
                    return
                }
                guard let mesh = shape.mesh(linearDeflection: 0.1) else {
                    loadError = "Failed to tessellate STL mesh."
                    return
                }

                let geometry = mesh.sceneKitGeometry()
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(red: 0.70, green: 0.78, blue: 0.88, alpha: 1.0)
                material.lightingModel = .blinn
                geometry.materials = [material]

                let stlNode = SCNNode(geometry: geometry)
                stlNode.name = "stl-part"
                root.addChildNode(stlNode)

                self.triangleCount = mesh.triangleCount
                self.entityCount = 1
            }

            let boxBounds = root.boundingBox
            let center = SCNVector3(
                (boxBounds.min.x + boxBounds.max.x) / 2,
                (boxBounds.min.y + boxBounds.max.y) / 2,
                (boxBounds.min.z + boxBounds.max.z) / 2
            )
            root.position = SCNVector3(-center.x, -center.y, -center.z)

            self.sceneRoot = root
            self.fileName = url.lastPathComponent
            self.pickedPoints = []
            self.lastDistance = nil
            self.debugInfo = "loaded \(root.childNodes.count) nodes"
        } catch {
            loadError = "Failed to load file: \(error.localizedDescription)"
        }
    }

    // MARK: - Measurement

    func addPickedPoint(_ point: SCNVector3) {
        pickedPoints.append(point)
        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            lastDistance = distance(between: a, and: b)
        } else if pickedPoints.count > 2 {
            pickedPoints = [point]
            lastDistance = nil
        }
    }

    func resetMeasurement() {
        pickedPoints = []
        lastDistance = nil
    }

    // MARK: - Math helpers

    private func distance(between a: SCNVector3, and b: SCNVector3) -> Float {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        return (dx*dx + dy*dy + dz*dz).squareRoot()
    }
}
