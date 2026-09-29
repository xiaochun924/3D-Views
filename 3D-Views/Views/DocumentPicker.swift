//
//  DocumentPicker.swift
//  3D-Views
//
//  UIKit-backed document picker presented as a sheet. More reliable than
//  SwiftUI's .fileImporter for custom CAD UTIs on iOS 17.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Try our imported UTIs first, fall back to .data so every file is tappable.
        var types: [UTType] = []
        if let step = UTType("com.xiaochun.step") { types.append(step) }
        if let stl = UTType("com.xiaochun.stl") { types.append(stl) }
        types.append(.data)

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
