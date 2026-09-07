import AVKit
import CoreTransferable
import Foundation
import ImageIO
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
    /// 相册资产携带的拍摄地点与时间；无地理信息的资产为 nil。
    var latitude: Double?
    var longitude: Double?
    var capturedAt: Date?

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
        latitude = nil
        longitude = nil
        capturedAt = nil
    }

    init(
        kind: String,
        primary: JournalLocalResource,
        pairedVideo: JournalLocalResource? = nil,
        previewImage: UIImage? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        capturedAt: Date? = nil
    ) throws {
        guard primary.sizeBytes <= Self.maximumResourceBytes,
              pairedVideo.map({ $0.sizeBytes <= Self.maximumResourceBytes }) ?? true else {
            throw JournalMediaError.tooLarge
        }
        self.kind = kind
        self.primary = primary
        self.pairedVideo = pairedVideo
        self.previewImage = previewImage
        self.latitude = latitude
        self.longitude = longitude
        self.capturedAt = capturedAt
    }

    static func load(from item: PhotosPickerItem) async throws -> JournalAttachment {
        // PhotosPicker 本身不需要整库授权。只在用户已经授权时走 PHAsset，避免
        // 选完照片后又出现一层权限弹窗；未授权时从原始文件的 EXIF 读取位置。
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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

    static func load(from wrappedResult: JournalPhotoPickerResult) async throws -> JournalAttachment {
        let result = wrappedResult.value
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if (status == .authorized || status == .limited),
           let identifier = result.assetIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            return try await load(from: asset)
        }

        let provider = result.itemProvider
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { throw JournalMediaError.unsupported }
        let importedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: JournalMediaError.unreadable)
                    return
                }
                do {
                    let type = UTType(typeIdentifier)
                    let originalName = url.lastPathComponent
                    let hasImageExtension = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                    let fileName = hasImageExtension
                        ? originalName
                        : "photo.\(type?.preferredFilenameExtension ?? "jpg")"
                    let destination = try temporaryURL(fileName: fileName)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return try await loadFile(at: importedURL)
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
        let metadata = kind == "photo" ? imageMetadata(at: destination) : nil
        return try JournalAttachment(
            kind: kind,
            primary: resource,
            previewImage: kind == "photo" ? UIImage(contentsOfFile: destination.path) : nil,
            latitude: metadata?.latitude,
            longitude: metadata?.longitude,
            capturedAt: metadata?.capturedAt
        )
    }

    private static func imageMetadata(at url: URL) -> (latitude: Double?, longitude: Double?, capturedAt: Date?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil) }

        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        var latitude = (gps?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue
        var longitude = (gps?[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        if (gps?[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = latitude.map { -$0 } }
        if (gps?[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = longitude.map { -$0 } }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? ((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return (latitude, longitude, dateString.flatMap(formatter.date(from:)))
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
                previewImage: UIImage(contentsOfFile: primary.url.path),
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                capturedAt: asset.creationDate
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

/// PHPickerResult carries an NSItemProvider and has no SDK Sendable conformance.
/// Selection is immutable after the delegate callback, so it is safe to hand to the import task.
struct JournalPhotoPickerResult: @unchecked Sendable {
    let value: PHPickerResult
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

/// 手书照片缩略图加载器：展示层只从本地读取，绝不因滚动或预览而请求服务端。
/// 照片在导入、上传时写入磁盘缓存；之后缩略图、地图与全屏预览共用该缓存。
final class JournalPhotoLoader: @unchecked Sendable {
    static let shared = JournalPhotoLoader()

    private let cache: NSCache<NSString, UIImage>
    private let diskCache = JournalPhotoDiskCache.shared

    private init() {
        cache = NSCache()
        cache.countLimit = 240
    }

    func thumbnail(for url: URL, maxPixelSize: CGFloat, cacheKey: String? = nil) async -> UIImage? {
        let persistentKey = cacheKey ?? url.absoluteString
        let memoryKey = "\(persistentKey)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: memoryKey) { return cached }

        let data: Data
        if let cached = diskCache.data(for: persistentKey) {
            data = cached
        } else if url.isFileURL, let local = FileManager.default.contents(atPath: url.path) {
            data = local
            diskCache.store(local, for: persistentKey)
        } else {
            // 网络同步只传输尚未同步的本地附件；这里是展示路径，不能回源拉图。
            return nil
        }

        guard let image = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: memoryKey)
        return image
    }

    func persistLocalPhoto(at url: URL, key: String) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        diskCache.store(data, for: key)
    }

    static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Application Support 中的稳定照片缓存。key 是服务端媒体 key，而非会过期的
/// 预签名 URL，因此应用重启、链接刷新也不会重新下载同一张照片。
private final class JournalPhotoDiskCache: @unchecked Sendable {
    static let shared = JournalPhotoDiskCache()

    private let directory: URL
    private let lock = NSLock()

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelCompanion/JournalPhotoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.contents(atPath: fileURL(for: key).path)
    }

    func store(_ data: Data, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let destination = fileURL(for: key)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? data.write(to: destination, options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return directory.appendingPathComponent(String(format: "%016llx", hash) + ".photo")
    }
}

/// 手书照片缩略图（SwiftUI）：远端/本地通用，加载中显示占位底色。
struct JournalPhotoThumbnail: View {
    let url: URL?
    var cacheKey: String? = nil
    var maxPixelSize: CGFloat = 600

    var body: some View {
        Group {
            if let url {
                JournalPhotoThumbnailCore(url: url, cacheKey: cacheKey, maxPixelSize: maxPixelSize)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
    }
}

private struct JournalPhotoThumbnailCore: View {
    let url: URL
    let cacheKey: String?
    let maxPixelSize: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(PrimaryTabPalette.elevatedSurface)
            }
        }
        .task(id: url) {
            image = await JournalPhotoLoader.shared.thumbnail(for: url, maxPixelSize: maxPixelSize, cacheKey: cacheKey)
        }
    }
}

/// 手书照片长按预览（context menu preview）：复用瀑布流同规格的 1000px 缩略图缓存，
/// 按原始宽高比放大显示；lift-and-zoom 过场由系统 context menu 动画提供。
struct JournalPhotoPreview: View {
    let url: URL?
    var cacheKey: String? = nil

    var body: some View {
        Group {
            if let url {
                JournalPhotoPreviewCore(url: url, cacheKey: cacheKey)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: 340, maxHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct JournalPhotoPreviewCore: View {
    let url: URL
    let cacheKey: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle().fill(PrimaryTabPalette.elevatedSurface)
            }
        }
        .task(id: url) {
            image = await JournalPhotoLoader.shared.thumbnail(for: url, maxPixelSize: 1000, cacheKey: cacheKey)
        }
    }
}
