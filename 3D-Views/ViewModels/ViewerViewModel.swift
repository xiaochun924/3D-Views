//
//  ViewerViewModel.swift
//  3D-Views
//

import Foundation
import SceneKit
import SwiftUI
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
    @Published var lengthUnit: String = "millimeter"

    /// The root node holding the loaded CAD geometry.
    @Published var sceneRoot: SCNNode?

    // MARK: - Interaction

    @Published var mode: InteractionMode = .orbit
    @Published var displayUnit: DisplayUnit = .millimeter

    /// Picked points in model coordinates.
    @Published var pickedPoints: [SCNVector3] = []
    @Published var lastDistance: Float?

    @Published var showWireframe: Bool = true
    @Published var showShaded: Bool = true

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

        let needsAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let root = SCNNode()
            root.name = "CADRoot"

            if ext == "step" || ext == "stp" {
                guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
                    loadError = "Could not read STEP file as text."
                    return
                }
                let model = try STEPParser.parse(text: text)
                self.lengthUnit = model.lengthUnit
                self.entityCount = model.entities.count

                let geom = Tessellator.build(model)

                if showShaded {
                    for g in geom.surfaceMeshes {
                        root.addChildNode(SCNNode(geometry: g))
                    }
                }
                if showWireframe {
                    for poly in geom.edgePolylines {
                        root.addChildNode(makeEdgePolyline(poly))
                    }
                }
            } else {
                if let g = STLParser.parse(data: data) {
                    root.addChildNode(SCNNode(geometry: g))
                }
                self.entityCount = 0
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

    private func makeEdgePolyline(_ points: [SCNVector3]) -> SCNNode {
        guard points.count >= 2 else { return SCNNode() }
        let source = SCNGeometrySource(vertices: points)
        var indices: [Int32] = []
        for i in 0..<(points.count - 1) {
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.darkGray
        mat.isLitPerPixel = false
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // MARK: - Measurement

    func addPickedPoint(_ point: SCNVector3) {
        pickedPoints.append(point)
        if pickedPoints.count == 2 {
            let a = pickedPoints[0], b = pickedPoints[1]
            lastDistance = (b - a).length()
        } else if pickedPoints.count > 2 {
            pickedPoints = [point]
            lastDistance = nil
        }
    }

    func resetMeasurement() {
        pickedPoints = []
        lastDistance = nil
    }
}
