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
    @Published var isLoading: Bool = false
    @Published var loadError: String?
    @Published var entityCount: Int = 0
    @Published var triangleCount: Int = 0
    @Published var lengthUnit: String = "millimeter"

    /// The root node holding the loaded CAD geometry.
    @Published var sceneRoot: SCNNode?

    // MARK: - Interaction

    @Published var mode: InteractionMode = .orbit
    @Published var displayUnit: DisplayUnit = .millimeter

    /// Picked points in model coordinates.
    @Published var pickedPoints: [SCNVector3] = []
    @Published var lastDistance: Float?

    // MARK: - Loading

    func loadFile(url: URL) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let ext = url.pathExtension.lowercased()
        guard ext == "step" || ext == "stp" || ext == "stl" else {
            loadError = "Unsupported file type. Please open a .step, .stp or .stl file."
            return
        }

        // Incoming URLs (fileImporter, "Open in" from Files, share sheet) are
        // security-scoped and may point to file providers (iCloud, etc.) whose
        // contents are not yet on disk. Copy to a plain local temp file so the
        // C++ OCCT loader gets a readable, absolute path.
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
                // Use OpenCASCADE via OCCTSwift for full B-rep STEP parsing.
                let shape = try Shape.loadSTEP(from: localURL)
                self.lengthUnit = "millimeter"

                guard let mesh = shape.mesh(linearDeflection: 0.1, angularDeflection: 0.5) else {
                    loadError = "Failed to tessellate the STEP model."
                    return
                }

                let geometry = mesh.sceneKitGeometry()
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
                material.lightingModel = .physicallyBased
                material.metalness.contents = 0.2
                material.roughness.contents = 0.6
                material.isDoubleSided = true
                geometry.materials = [material]

                let partNode = SCNNode(geometry: geometry)
                partNode.name = "step-part"
                root.addChildNode(partNode)

                self.triangleCount = mesh.triangleCount
                self.entityCount = 1
            } else {
                // STL: use OCCT's STL reader as well.
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
                material.lightingModel = .physicallyBased
                material.metalness.contents = 0.1
                material.roughness.contents = 0.7
                geometry.materials = [material]

                let stlNode = SCNNode(geometry: geometry)
                stlNode.name = "stl-part"
                root.addChildNode(stlNode)

                self.triangleCount = mesh.triangleCount
                self.entityCount = 1
            }

            let (min, max) = root.boundingBox
            let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
            root.position = SCNVector3(-center.x, -center.y, -center.z)

            self.sceneRoot = root
            self.fileName = url.lastPathComponent
            self.pickedPoints = []
            self.lastDistance = nil
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

    // MARK: - Math helpers (replaces SCNVector3 operator extensions)

    private func distance(between a: SCNVector3, and b: SCNVector3) -> Float {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        return (dx*dx + dy*dy + dz*dz).squareRoot()
    }
}
