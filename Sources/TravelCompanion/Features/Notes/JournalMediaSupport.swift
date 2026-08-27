import AVKit
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct JournalLocalResource: Sendable {
    let url: URL
    let contentType: String
    let fileName: String
    let sizeBytes: Int
}

struct JournalAttachment: Identifiable, @unchecked Sendable {
    static let maximumResourceBytes = 5 * 1024 * 1024 * 1024

    let id = UUID()
    let kind: String
    let primary: JournalLocalResource
    let pairedVideo: JournalLocalResource?
    let previewImage: UIImage?

    init?(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        do {
            let url = try Self.temporaryURL(fileName: "camera-\(UUID().uuidString).jpg")
            try data.write(to: url, options: .atomic)
            primary = .init(
                url: url,
                contentType: "image/jpeg",
                fileName: "camera.jpg",
                sizeBytes: data.count
            )
            kind = "photo"
            pairedVideo = nil
            previewImage = image
        } catch {
            return nil
        }
    }

    init(
        kind: String,
        primary: JournalLocalResource,
        pairedVideo: JournalLocalResource? = nil,
        previewImage: UIImage? = nil
    ) throws {
        guard primary.sizeBytes <= Self.maximumResourceBytes,
              pairedVideo.map({ $0.sizeBytes <= Self.maximumResourceBytes }) ?? true else {
            throw JournalMediaError.tooLarge
        }
        self.kind = kind
        self.primary = primary
        self.pairedVideo = pairedVideo
        self.previewImage = previewImage
    }

    static func load(from item: PhotosPickerItem) async throws -> JournalAttachment {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if (status == .authorized || status == .limited),
           let identifier = item.itemIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            return try await load(from: asset)
        }

        guard let imported = try await item.loadTransferable(type: JournalPickedFile.self) else {
            throw JournalMediaError.unreadable
        }
        return try await loadFile(at: imported.url)
    }

    static func loadFile(at sourceURL: URL) async throws -> JournalAttachment {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let destination = try temporaryURL(fileName: sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let resource = try localResource(at: destination, originalName: sourceURL.lastPathComponent)
        let type = UTType(filenameExtension: destination.pathExtension)
        let kind: String
        if type?.conforms(to: .image) == true {
            kind = "photo"
        } else if type?.conforms(to: .movie) == true {
            kind = "video"
        } else {
            kind = "file"
        }
        return try JournalAttachment(
            kind: kind,
            primary: resource,
            previewImage: kind == "photo" ? UIImage(contentsOfFile: destination.path) : nil
        )
    }

    private static func load(from asset: PHAsset) async throws -> JournalAttachment {
        let resources = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            guard let photo = preferredResource(
                in: resources,
                types: [.photo, .fullSizePhoto, .alternatePhoto]
            ) else { throw JournalMediaError.unreadable }
            let primary = try await copy(photo)
            let pairedResource = preferredResource(
                in: resources,
                types: [.pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo]
            )
            let paired: JournalLocalResource?
            if let pairedResource {
                paired = try await copy(pairedResource)
            } else {
                paired = nil
            }
            return try JournalAttachment(
                kind: paired == nil ? "photo" : "livePhoto",
                primary: primary,
                pairedVideo: paired,
                previewImage: UIImage(contentsOfFile: primary.url.path)
            )
        case .video:
            guard let video = preferredResource(in: resources, types: [.video, .fullSizeVideo]) else {
                throw JournalMediaError.unreadable
            }
            return try JournalAttachment(kind: "video", primary: try await copy(video))
        default:
            throw JournalMediaError.unsupported
        }
    }

    private static func preferredResource(
        in resources: [PHAssetResource],
        types: [PHAssetResourceType]
    ) -> PHAssetResource? {
        for type in types {
            if let resource = resources.first(where: { $0.type == type }) { return resource }
        }
        return nil
    }

    private static func copy(_ resource: PHAssetResource) async throws -> JournalLocalResource {
        let url = try temporaryURL(fileName: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return try localResource(
            at: url,
            originalName: resource.originalFilename,
            uniformTypeIdentifier: resource.uniformTypeIdentifier
        )
    }

    private static func localResource(
        at url: URL,
        originalName: String,
        uniformTypeIdentifier: String? = nil
    ) throws -> JournalLocalResource {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let sizeBytes = values.fileSize else {
            throw JournalMediaError.unreadable
        }
        guard sizeBytes <= maximumResourceBytes else { throw JournalMediaError.tooLarge }
        let uniformType = uniformTypeIdentifier.flatMap { UTType($0) }
            ?? UTType(filenameExtension: url.pathExtension)
        let contentType = uniformType?.preferredMIMEType ?? "application/octet-stream"
        return .init(
            url: url,
            contentType: contentType,
            fileName: String(originalName.prefix(255)),
            sizeBytes: sizeBytes
        )
    }

    private static func temporaryURL(fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelCompanionJournalImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = fileName.isEmpty ? "attachment.bin" : fileName
        return directory.appendingPathComponent(safeName)
    }
}

private struct JournalPickedFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let destination = try JournalAttachment.temporaryImportedURL(
                fileName: received.file.lastPathComponent
            )
            try FileManager.default.copyItem(at: received.file, to: destination)
            return JournalPickedFile(url: destination)
        }
    }
}

extension JournalAttachment {
    fileprivate static func temporaryImportedURL(fileName: String) throws -> URL {
        try temporaryURL(fileName: fileName)
    }
}

enum JournalMediaError: LocalizedError {
    case tooLarge
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "media.tooLarge")
        case .unreadable: String(localized: "media.unreadable")
        case .unsupported: String(localized: "media.unsupported")
        }
    }
}

struct JournalMediaView: View {
    let media: JournalImage

    var body: some View {
        Group {
            if media.kind == "livePhoto",
               let photoURL = media.url.flatMap(URL.init(string:)),
               let videoURL = media.pairedVideo?.url.flatMap(URL.init(string:)) {
                JournalLivePhotoView(photoURL: photoURL, videoURL: videoURL)
            } else if media.kind == "video", let url = media.url.flatMap(URL.init(string:)) {
                VideoPlayer(player: AVPlayer(url: url))
            } else if media.kind == "file" {
                JournalFileTile(name: media.fileName ?? media.key)
            } else if let url = media.url.flatMap(URL.init(string:)) {
                JournalHDRImage(url: url)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .overlay(alignment: .topLeading) {
            if media.kind == "livePhoto" {
                Label("journal.liveBadge", systemImage: "livephoto")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
    }
}

private struct JournalHDRImage: View {
    let url: URL

    var body: some View {
        if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .allowedDynamicRange(.high)
                .scaledToFill()
        } else {
            AsyncImage(url: url) { image in
                image.resizable().allowedDynamicRange(.high).scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
        }
    }
}

private struct JournalFileTile: View {
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 42))
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
    }
}

private struct JournalLivePhotoView: View {
    let photoURL: URL
    let videoURL: URL
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        Group {
            if let livePhoto {
                LivePhotoRepresentable(livePhoto: livePhoto)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .task(id: "\(photoURL.absoluteString)|\(videoURL.absoluteString)") {
            livePhoto = try? await Self.load(photoURL: photoURL, videoURL: videoURL)
        }
    }

    private static func load(photoURL: URL, videoURL: URL) async throws -> PHLivePhoto {
        async let photo = localResource(from: photoURL)
        async let video = localResource(from: videoURL)
        let resources = try await [photo, video]
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(
                withResourceFileURLs: resources,
                placeholderImage: nil,
                targetSize: CGSize(width: 1_200, height: 1_200),
                contentMode: .aspectFit
            ) { livePhoto, info in
                if let livePhoto { continuation.resume(returning: livePhoto) }
                else {
                    continuation.resume(throwing: (info[PHLivePhotoInfoErrorKey] as? Error) ?? JournalMediaError.unreadable)
                }
            }
        }
    }

    private static func localResource(from url: URL) async throws -> URL {
        if url.isFileURL { return url }
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-live-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }
}

private struct LivePhotoRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        guard view.livePhoto !== livePhoto else { return }
        view.livePhoto = livePhoto
        view.startPlayback(with: .hint)
    }
}
