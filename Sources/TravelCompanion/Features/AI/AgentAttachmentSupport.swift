@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AgentPreparedFile: Sendable {
    let data: Data
    let mediaType: String
    let fileName: String

    var dataURI: String {
        "data:\(mediaType);base64,\(data.base64EncodedString())"
    }
}

enum AgentAttachmentError: LocalizedError {
    case unreadable
    case unsupportedFile
    case emptyFile
    case tooLarge(maximumMegabytes: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "无法读取这个附件，请换一个文件重试。"
        case .unsupportedFile:
            "暂不支持这种文件格式。请选择图片、PDF、文本或常见 Office 文档。"
        case .emptyFile:
            "这个文件没有内容。"
        case .tooLarge(let maximumMegabytes):
            "附件过大，请选择不超过 \(maximumMegabytes) MB 的文件。"
        }
    }
}

enum AgentFileAttachmentProcessor {
    static let maximumBytes = 3_000_000
    static let maximumMegabytes = 3

    private static let supportedExtensions: Set<String> = [
        "csv", "doc", "docx", "heic", "jpeg", "jpg", "json", "md", "pdf",
        "png", "ppt", "pptx", "rtf", "txt", "webp", "xls", "xlsx", "xml"
    ]

    static func prepare(_ url: URL) throws -> AgentPreparedFile {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let fileName = url.lastPathComponent.isEmpty ? "附件" : url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw AgentAttachmentError.unsupportedFile
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AgentAttachmentError.unreadable
        }
        guard !data.isEmpty else { throw AgentAttachmentError.emptyFile }

        if UIImage(data: data) != nil {
            let prepared = try AgentImageAttachmentProcessor.prepare(data)
            return AgentPreparedFile(data: prepared.data, mediaType: prepared.mediaType, fileName: fileName)
        }

        guard data.count <= maximumBytes else {
            throw AgentAttachmentError.tooLarge(maximumMegabytes: maximumMegabytes)
        }
        guard let contentType = UTType(filenameExtension: fileExtension),
              let mediaType = contentType.preferredMIMEType else {
            throw AgentAttachmentError.unsupportedFile
        }
        return AgentPreparedFile(data: data, mediaType: mediaType, fileName: fileName)
    }
}

struct AgentAttachmentPreviewCard: View {
    let attachment: AgentV2TurnRequest.Attachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.72), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("移除\(displayName)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.mediaType.hasPrefix("image/"),
           let data = attachment.decodedData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.5)
                )
        } else {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(PrimaryTabPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(fileTypeLabel)
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 178, height: 76, alignment: .leading)
            .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    private var displayName: String {
        attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (attachment.mediaType.hasPrefix("image/") ? "图片" : "文件")
    }

    private var fileTypeLabel: String {
        let fileExtension = ((attachment.fileName ?? "") as NSString).pathExtension.uppercased()
        return fileExtension.isEmpty ? "文件" : fileExtension
    }
}

private extension AgentV2TurnRequest.Attachment {
    var decodedData: Data? {
        guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURI[dataURI.index(after: commaIndex)...]))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 半屏照片选择：内嵌官方 PHPickerViewController（SwiftUI 的
/// .photosPickerStyle(.inline) 在相册 Face ID 解锁后会把内部导航撑出容器，
/// 导致布局破坏、选择失效；直接内嵌 PHPicker 则解锁后仅在自身视图内刷新）。
struct AgentPhotoPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let maximumSelectionCount: Int
    let onPick: ([PHPickerResult]) -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea()

            AgentPhotoLibraryPicker(selectionLimit: maximumSelectionCount) { results in
                dismiss()
                onPick(results)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
    }
}

struct AgentPhotoLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        picker.overrideUserInterfaceStyle = .dark
        picker.view.backgroundColor = .secondarySystemBackground
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = .dark
        // Unlocking a protected Photos collection briefly rebuilds the
        // picker's remote view hierarchy. Keep the host view opaque so the
        // rebuilt hierarchy never exposes the sheet's black backing view.
        uiViewController.view.backgroundColor = .secondarySystemBackground
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void

        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results)
        }
    }
}

struct AgentCameraSheet: View {
    @Binding var isPresented: Bool
    let onCapture: (UIImage) -> Void
    @StateObject private var camera = AgentCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage = camera.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    if camera.isPermissionDenied {
                        Button("前往设置") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(.white, in: Capsule())
                    }
                }
            } else {
                VStack(spacing: 0) {
                    AgentCameraPreview(session: camera.session, cameraPosition: camera.cameraPosition)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay {
                            if !camera.isReady {
                                ProgressView()
                                    .tint(.white)
                            }
                        }

                    cameraControls
                        .frame(height: 118)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.onCapture = { image in
                isPresented = false
                onCapture(image)
            }
            camera.start()
        }
        .onDisappear {
            camera.stop()
            camera.onCapture = nil
        }
    }

    private var cameraControls: some View {
        HStack {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭相机")

            Spacer()

            Button {
                camera.capture()
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(.white.opacity(0.34), lineWidth: 5).padding(-7))
            }
            .buttonStyle(.plain)
            .disabled(!camera.isReady || camera.isCapturing)
            .opacity(camera.isCapturing ? 0.55 : 1)
            .accessibilityLabel("拍照")

            Spacer()

            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!camera.isReady || camera.isCapturing)
            .accessibilityLabel("切换摄像头")
        }
        .padding(.horizontal, 24)
    }
}

final class AgentCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPermissionDenied = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

    var onCapture: ((UIImage) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.indo.agent.camera-session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    self.publishPermissionDenied()
                }
            }
        case .denied, .restricted:
            publishPermissionDenied()
        @unknown default:
            publishError("无法访问相机，请稍后重试。")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.publishReady(false)
        }
    }

    func capture() {
        guard isReady, !isCapturing else { return }
        isCapturing = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func switchCamera() {
        guard isReady, !isCapturing else { return }
        publishReady(false)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            do {
                try self.replaceVideoInput(position: newPosition)
                DispatchQueue.main.async {
                    self.cameraPosition = newPosition
                    self.isReady = true
                }
            } catch {
                self.publishError("无法切换摄像头，请稍后重试。")
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.isConfigured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    do {
                        try self.addVideoInput(position: .back)
                        guard self.session.canAddOutput(self.photoOutput) else {
                            throw AgentCameraError.unavailable
                        }
                        self.session.addOutput(self.photoOutput)
                        self.session.commitConfiguration()
                        self.isConfigured = true
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                }
                if !self.session.isRunning { self.session.startRunning() }
                self.publishReady(true)
            } catch {
                self.publishError("当前设备无法启动相机。")
            }
        }
    }

    private func addVideoInput(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw AgentCameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AgentCameraError.unavailable }
        session.addInput(input)
    }

    private func replaceVideoInput(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let oldInputs = session.inputs
        for input in oldInputs { session.removeInput(input) }
        do {
            try addVideoInput(position: position)
        } catch {
            for input in oldInputs where session.canAddInput(input) {
                session.addInput(input)
            }
            throw error
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "照片处理失败，请重新拍摄。"
            }
            return
        }
        DispatchQueue.main.async {
            self.isCapturing = false
            self.onCapture?(image)
        }
    }

    private func publishReady(_ value: Bool) {
        DispatchQueue.main.async { self.isReady = value }
    }

    private func publishPermissionDenied() {
        DispatchQueue.main.async {
            self.isReady = false
            self.isPermissionDenied = true
            self.errorMessage = "未获得相机权限，请在系统设置中允许 Indo 使用相机。"
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.isReady = false
            self.errorMessage = message
        }
    }

    private enum AgentCameraError: Error {
        case unavailable
    }
}

private struct AgentCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraPosition: AVCaptureDevice.Position

    func makeUIView(context: Context) -> AgentCameraPreviewView {
        let view = AgentCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: AgentCameraPreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.updateVideoOrientation(cameraPosition: cameraPosition)
    }
}

private final class AgentCameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateVideoOrientation(cameraPosition: .unspecified)
    }

    func updateVideoOrientation(cameraPosition: AVCaptureDevice.Position) {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if cameraPosition != .unspecified {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraPosition == .front
        }
    }
}

struct AgentDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        controller.delegate = context.coordinator
        controller.overrideUserInterfaceStyle = .dark
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = .dark
        uiViewController.view.backgroundColor = .black
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: AgentDocumentPicker

        init(parent: AgentDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
