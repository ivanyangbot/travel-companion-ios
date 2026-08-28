@preconcurrency import AVFoundation
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
            String(localized: "attachment.unreadable")
        case .unsupportedFile:
            String(localized: "attachment.unsupported")
        case .emptyFile:
            String(localized: "attachment.empty")
        case .tooLarge(let maximumMegabytes):
            String(format: String(localized: "attachment.tooLarge"), maximumMegabytes)
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

        let fileName = url.lastPathComponent.isEmpty ? String(localized: "attachment.nameFallback") : url.lastPathComponent
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
            .accessibilityLabel(Text(String(format: String(localized: "attachment.removeA11y"), displayName)))
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
            ?? (attachment.mediaType.hasPrefix("image/") ? String(localized: "attachment.imageFallback") : String(localized: "attachment.fileFallback"))
    }

    private var fileTypeLabel: String {
        let fileExtension = ((attachment.fileName ?? "") as NSString).pathExtension.uppercased()
        return fileExtension.isEmpty ? String(localized: "attachment.fileTypeFallback") : fileExtension
    }
}

/// Read-only attachment gallery rendered above a submitted user bubble. It
/// deliberately has no remove affordance: after send, the images are part of
/// the conversation rather than editable composer state.
struct AgentSentAttachmentStrip: View {
    let attachments: [AgentV2TurnRequest.Attachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AgentSentAttachmentCard(attachment: attachment)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled(false)
    }
}

private struct AgentSentAttachmentCard: View {
    let attachment: AgentV2TurnRequest.Attachment

    @ViewBuilder
    var body: some View {
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
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(PrimaryTabPalette.accent)
                .frame(width: 76, height: 76)
                .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                )
                .accessibilityLabel(attachment.fileName ?? String(localized: "attachment.fileFallback"))
        }
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
                        Button("attachment.goSettings") {
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
            .accessibilityLabel(Text("attachment.closeCameraA11y"))

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
            .accessibilityLabel(Text("attachment.takePhotoA11y"))

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
            .accessibilityLabel(Text("attachment.switchCameraA11y"))
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
            publishError(String(localized: "attachment.cameraUnavailable"))
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
                self.publishError(String(localized: "attachment.switchFailed"))
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
                self.publishError(String(localized: "attachment.cameraStartFailed"))
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
                self.errorMessage = String(localized: "attachment.processFailed")
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
            self.errorMessage = String(localized: "attachment.cameraPermission")
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
