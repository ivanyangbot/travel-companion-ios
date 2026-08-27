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

struct AgentCameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: AgentCameraPicker

        init(parent: AgentCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.isPresented = false
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
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
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

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
