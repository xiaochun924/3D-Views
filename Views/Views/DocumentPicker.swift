//
//  DocumentPicker.swift
//  Views
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 原生文件选择器（顶层模态直接弹出）
/// 嵌套模态在部分 iOS 上会导致文件行不可点、选不中文件；
/// 这里改成从当前最顶层控制器直接 present。
/// asCopy: true —— 所选文件会被复制进 App 沙盒，读取无需安全作用域访问。
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()

    private var onPicked: ((URL) -> Void)?
    private var onCancel: (() -> Void)?

    func present(allowedContentTypes: [UTType] = [.data],
                 onPicked: @escaping (URL) -> Void,
                 onCancel: @escaping () -> Void) {
        guard let top = Self.topViewController() else {
            onCancel()
            return
        }
        self.onPicked = onPicked
        self.onCancel = onCancel
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let cb = onPicked
        onPicked = nil
        onCancel = nil
        cb?(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let cb = onCancel
        onPicked = nil
        onCancel = nil
        cb?()
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
