import PhotosUI
import SwiftUI

/// 手书条目只读详情页：沉浸阅读 + 照片网格 + 快捷加照片。
/// 编辑由 toolbar 铅笔入口进入（NotesView 弹出既有编辑器 sheet）。
struct JournalEntryDetailView: View {
    let entry: JournalEntry
    let groups: [JournalGroup]
    let onEdit: () -> Void
    /// 快捷加照片：选完系统对勾后直接落库（上传 + PATCH / 本地保存），无中间确认。
    let onAddPhotos: ([JournalAttachment]) async -> Void
    /// 查看器里保存照片描述：(imageKey, description)。
    let onSaveDescription: (String, String) async -> Void

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var mediaError: String?
    @State private var presentedViewer: PresentedViewer?
    @State private var photoSourceFrames: [String: CGRect] = [:]

    private struct PresentedViewer: Identifiable {
        let id: String
        let photos: [JournalPhotoViewer.Photo]
        let initialIndex: Int
    }

    /// 可进入查看器的照片（静态图与实况照片的主图）。
    private var viewablePhotos: [JournalPhotoViewer.Photo] {
        entry.images
            .filter { $0.kind == nil || $0.kind == "photo" || $0.kind == "livePhoto" }
            .map { image in
                JournalPhotoViewer.Photo(
                    id: image.key,
                    url: image.url.flatMap(URL.init(string:)),
                    description: image.description,
                    capturedAt: image.capturedAt,
                    media: image,
                    sourceFrame: photoSourceFrames[image.key],
                    sourceCornerRadius: 16
                )
            }
    }

    var body: some View {
        ZStack {
            PrimaryTabPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let content = entry.content, !content.isEmpty {
                        Text(content)
                            .font(.system(size: 17))
                            .lineSpacing(7)
                            .foregroundStyle(.white.opacity(0.88))
                            .textSelection(.enabled)
                    }
                    photoSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                }
                .accessibilityLabel(Text("common.edit"))
            }
        }
        .fullScreenCover(item: $presentedViewer) { presented in
            JournalPhotoViewer(
                photos: presented.photos,
                initialIndex: presented.initialIndex,
                onSaveDescription: { imageKey, description in
                    await onSaveDescription(imageKey, description)
                },
                onDismissAfterTransition: {
                    dismissWithoutAnimation { presentedViewer = nil }
                }
            )
        }
        .onPreferenceChange(JournalPhotoSourceFramePreferenceKey.self) { frames in
            photoSourceFrames = frames
        }
        .onChange(of: pickerItems) { _, values in
            Task { await importPhotoItems(values) }
        }
        .alert(
            "journal.cannotAttachTitle",
            isPresented: Binding(
                get: { mediaError != nil },
                set: { if !$0 { mediaError = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(mediaError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(entry.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                if let group = groups.first(where: { $0.id == entry.groupId }) {
                    Label(group.name, systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.accent)
                }
            }
            Text(entry.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("journal.photoSection")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                if !entry.images.isEmpty {
                    Text(String(entry.images.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                Spacer()
                addPhotoButton
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(entry.images) { image in
                    photoCell(image)
                }
                if isImporting {
                    importingCell
                } else if entry.images.isEmpty {
                    emptyAddTile
                }
            }
        }
    }

    private var addPhotoButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: nil,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(PrimaryTabPalette.elevatedSurface, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .disabled(isImporting)
        .accessibilityLabel(Text("journal.addPhotos"))
    }

    /// 空态时的大号"添加照片"入口：直接打开系统相册。
    private var emptyAddTile: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: nil,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 26))
                Text("journal.addPhotos")
                    .font(.subheadline)
            }
            .foregroundStyle(PrimaryTabPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityLabel(Text("journal.addPhotos"))
    }

    @ViewBuilder
    private func photoCell(_ image: JournalImage) -> some View {
        let isViewable = image.kind == nil || image.kind == "photo" || image.kind == "livePhoto"
        Button {
            guard isViewable, let index = viewablePhotos.firstIndex(where: { $0.id == image.key }) else { return }
            presentedViewer = PresentedViewer(
                id: image.key,
                photos: viewablePhotos,
                initialIndex: index
            )
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if isViewable {
                    JournalPhotoThumbnail(
                        url: image.url.flatMap(URL.init(string:)),
                        cacheKey: image.key,
                        maxPixelSize: 800,
                        prefersHighDynamicRange: image.isHDR == true
                    )
                } else {
                    JournalMediaView(media: image)
                }
                photoBadges(image)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: JournalPhotoSourceFramePreferenceKey.self,
                        value: [image.key: proxy.frame(in: .global)]
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image.description ?? image.fileName ?? String(localized: "journal.photoSection"))
    }

    /// Media and metadata indicators stay attached to the lower-right corner.
    @ViewBuilder
    private func photoBadges(_ image: JournalImage) -> some View {
        if image.kind == "livePhoto" || image.isHDR == true || image.latitude != nil || image.description != nil {
            HStack(spacing: 6) {
                if image.kind == "livePhoto" {
                    Image(systemName: "livephoto")
                }
                if image.isHDR == true {
                    Text("HDR")
                }
                if image.latitude != nil {
                    Image(systemName: "mappin")
                }
                if image.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Image(systemName: "text.bubble")
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    private var importingCell: some View {
        ZStack {
            Rectangle().fill(PrimaryTabPalette.elevatedSurface)
            ProgressView()
                .tint(.white.opacity(0.7))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(Text("journal.preparingFile"))
    }

    private func importPhotoItems(_ values: [PhotosPickerItem]) async {
        guard !values.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            pickerItems = []
        }
        var attachments: [JournalAttachment] = []
        do {
            for item in values {
                attachments.append(try await JournalAttachment.load(from: item))
            }
        } catch {
            mediaError = error.localizedDescription
        }
        guard !attachments.isEmpty else { return }
        await onAddPhotos(attachments)
    }
}
