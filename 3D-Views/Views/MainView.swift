//
//  MainView.swift
//  3D-Views
//

import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import UIKit

struct MainView: View {
    @StateObject private var viewModel = ViewerViewModel()
    @State private var showHelp = false
    @State private var debugMsg: String = ""

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.loadError != nil },
            set: { if !$0 { viewModel.loadError = nil } }
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            SceneView(viewModel: viewModel)
                .ignoresSafeArea()

            floatingGlassBar

            VStack {
                debugBanner
                Spacer()
                bottomDock
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .onOpenURL { url in
            debugMsg = "onOpenURL: \(url.lastPathComponent)"
            Task { await viewModel.loadFile(url: url) }
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("Cannot open file"),
                message: Text(viewModel.loadError ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var debugBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(debugMsg.isEmpty ? Color.gray : Color.orange)
                    .frame(width: 8, height: 8)
                Text(debugMsg.isEmpty ? "ready" : debugMsg)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                if viewModel.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(viewModel.debugInfo)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 52)
    }

    private var floatingGlassBar: some View {
        HStack(spacing: 12) {
            Button {
                debugMsg = "tapped cube"
            } label: {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            HStack(spacing: 6) {
                Image(systemName: "rotate.3d")
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.fileName.isEmpty ? "3D Views" : viewModel.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomDock: some View {
        VStack(spacing: 12) {
            if let dist = viewModel.lastDistance {
                HStack(spacing: 8) {
                    Image(systemName: "ruler")
                        .foregroundStyle(.blue)
                    Text("Distance: \(viewModel.displayUnit.format(dist))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Button {
                        viewModel.resetMeasurement()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                dockButton(icon: "folder", label: "Open") {
                    debugMsg = "opening picker..."
                    presentPicker()
                }

                dockButton(icon: "cube.box", label: "Test") {
                    debugMsg = "Test cube tapped"
                    Task { await viewModel.loadTestCube() }
                }

                dockButton(
                    icon: viewModel.mode == .measurePoint ? "ruler.fill" : "ruler",
                    label: "Measure",
                    highlighted: viewModel.mode == .measurePoint
                ) {
                    viewModel.mode = viewModel.mode == .measurePoint ? .orbit : .measurePoint
                }

                Menu {
                    ForEach(DisplayUnit.allCases, id: \.self) { unit in
                        Button(unit.rawValue) { viewModel.displayUnit = unit }
                    }
                } label: {
                    dockButtonContent(icon: "units", label: viewModel.displayUnit.rawValue)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.lastDistance != nil)
    }

    private func presentPicker() {
        debugMsg = "presenting picker"
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                self.debugMsg = "no root VC"
                return
            }

            var types: [UTType] = [.data]
            if let step = UTType("public.item") { types.append(step) }

            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet

            let delegate = PickerDelegate { url in
                self.debugMsg = "picked: \(url.lastPathComponent)"
                Task { await self.viewModel.loadFile(url: url) }
            }
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &AssociatedKeys.delegate, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            rootVC.present(picker, animated: true)
            self.debugMsg = "picker presented"
        }
    }

    private func dockButton(icon: String, label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            dockButtonContent(icon: icon, label: label, highlighted: highlighted)
        }
    }

    private func dockButtonContent(icon: String, label: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : Color.secondary)
        }
        .frame(width: 60, height: 56)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.blue)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Picker Delegate

private enum AssociatedKeys {
    static var delegate: UInt8 = 0
}

private class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        guard let url = urls.first else { return }
        onPick(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("3D Views").font(.title).bold()
                    Text("STEP / STL viewer with measurement.")
                    Text("Tap Open to pick a file, or Test to load a demo cube.")
                }
                .padding()
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

#Preview { MainView() }
