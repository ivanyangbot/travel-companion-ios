import SwiftUI

@MainActor
func dismissWithoutAnimation(_ updatePresentationState: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, updatePresentationState)
}

/// 瀑布流/详情网格把当前屏幕中的照片位置传给全屏查看器，关闭时据此飞回原位。
struct JournalPhotoSourceFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

enum JournalPhotoDismissalPhysics {
    static let fullProgressDistance: CGFloat = 240
    static let releaseDistance: CGFloat = 110
    static let predictedReleaseDistance: CGFloat = 210
    static let directionLockDistance: CGFloat = 12
    static let pagingDirectionRatio: CGFloat = 1.2

    static func distance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    static func progress(_ translation: CGSize) -> CGFloat {
        min(1, distance(translation) / fullProgressDistance)
    }

    static func shouldDismiss(translation: CGSize, predicted: CGSize) -> Bool {
        distance(translation) >= releaseDistance || distance(predicted) >= predictedReleaseDistance
    }

    static func isHorizontalPaging(_ translation: CGSize, hasMultiplePhotos: Bool) -> Bool {
        hasMultiplePhotos
            && abs(translation.width) >= directionLockDistance
            && abs(translation.width) > abs(translation.height) * pagingDirectionRatio
    }

    static func scale(progress: CGFloat, viewportWidth: CGFloat, sourceWidth: CGFloat?) -> CGFloat {
        let sourceScale: CGFloat
        if let sourceWidth, viewportWidth > 0 {
            sourceScale = min(0.82, max(0.18, sourceWidth / viewportWidth))
        } else {
            sourceScale = 0.42
        }
        return 1 - (1 - sourceScale) * min(1, max(0, progress))
    }
}

/// A gesture chooses its owner once, even if the finger subsequently changes direction.
enum JournalPhotoDragIntent: Equatable {
    case undecided
    case paging
    case dismissing

    func resolving(translation: CGSize, hasMultiplePhotos: Bool) -> Self {
        guard self == .undecided,
              JournalPhotoDismissalPhysics.distance(translation) >= JournalPhotoDismissalPhysics.directionLockDistance
        else { return self }
        return JournalPhotoDismissalPhysics.isHorizontalPaging(translation, hasMultiplePhotos: hasMultiplePhotos)
            ? .paging : .dismissing
    }
}

/// 全屏手书照片查看器：捏合缩放、拖拽平移、双击缩放、多图左右翻页、底部描述查看与编辑。
/// 详情页照片网格（多图翻页）与地图照片 pin 弹窗（单图）共用。
struct JournalPhotoViewer: View {
    struct Photo: Identifiable {
        let id: String
        let url: URL?
        let description: String?
        let capturedAt: Date?
        let media: JournalImage?
        let sourceFrame: CGRect?

        init(
            id: String,
            url: URL?,
            description: String?,
            capturedAt: Date?,
            media: JournalImage? = nil,
            sourceFrame: CGRect? = nil
        ) {
            self.id = id
            self.url = url
            self.description = description
            self.capturedAt = capturedAt
            self.media = media
            self.sourceFrame = sourceFrame
        }
    }

    let photos: [Photo]
    let initialIndex: Int
    /// 非nil 时描述条可进入编辑并保存（imageKey 随当前页走，翻页后保存的是
    /// 正在看的那张）；nil 表示只读（无描述编辑入口）。
    let onSaveDescription: ((_ imageKey: String, _ description: String) async -> Void)?
    /// 自定义飞回动画结束后由宿主直接移除 cover，避免系统再执行一次向下退场。
    let onDismissAfterTransition: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var isEditingDescription = false
    @State private var draftDescription = ""
    @State private var isSavingDescription = false
    /// 已保存描述的本地回显（index → 最新值），避免保存后依赖外部重建才刷新。
    @State private var savedDescriptions: [Int: String] = [:]
    @State private var dismissTranslation: CGSize = .zero
    @State private var dismissProgress: CGFloat = 0
    @State private var isCompletingDismiss = false
    @State private var isCurrentPhotoZoomed = false
    @State private var dragIntent: JournalPhotoDragIntent = .undecided
    @State private var pagingOffset: CGFloat = 0
    @State private var isSettlingPage = false
    @FocusState private var descriptionFieldFocused: Bool

    init(
        photos: [Photo],
        initialIndex: Int = 0,
        onSaveDescription: ((_ imageKey: String, _ description: String) async -> Void)? = nil,
        onDismissAfterTransition: (() -> Void)? = nil
    ) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.onSaveDescription = onSaveDescription
        self.onDismissAfterTransition = onDismissAfterTransition
        _currentIndex = State(initialValue: min(max(0, initialIndex), max(0, photos.count - 1)))
    }

    private var currentPhoto: Photo? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .opacity(max(0.04, 1 - dismissProgress * 0.96))
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                photoPager(in: proxy.size)
                    .scaleEffect(interactiveScale(in: proxy.size))
                    .offset(dismissTranslation)

                viewerChrome
                    .opacity(max(0, 1 - dismissProgress * 2.2))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(interactiveDismissGesture(in: proxy))
        }
        .presentationBackground(.clear)
        .statusBarHidden()
        .onAppear {
            draftDescription = currentPhoto?.description ?? ""
        }
    }

    private func photoPager(in size: CGSize) -> some View {
        // No independently scrolling TabView: this strip and dismissal share one drag owner.
        ZStack {
            ForEach(photos.indices.filter { abs($0 - currentIndex) <= 1 }, id: \.self) { index in
                JournalZoomablePhoto(
                    photo: photos[index],
                    isZoomed: index == currentIndex ? $isCurrentPhotoZoomed : .constant(false),
                    isActive: index == currentIndex && !isSettlingPage
                )
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: CGFloat(index - currentIndex) * size.width + pagingOffset)
                .allowsHitTesting(index == currentIndex && !isSettlingPage)
                .accessibilityHidden(index != currentIndex)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var viewerChrome: some View {
        ZStack {
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.66), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.close"))
                }
                if photos.count > 1 {
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            }
            .padding(.top, 8)
            .padding(.trailing, 16)

            VStack(spacing: 10) {
                Spacer()
                if hasDescription || isEditingDescription {
                    descriptionBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }
            }
        }
    }

    private func interactiveDismissGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !isCurrentPhotoZoomed, !isEditingDescription, !isCompletingDismiss, !isSettlingPage else { return }
                dragIntent = dragIntent.resolving(translation: value.translation, hasMultiplePhotos: photos.count > 1)
                if dragIntent == .paging {
                    let atEdge = (currentIndex == 0 && value.translation.width > 0)
                        || (currentIndex == photos.count - 1 && value.translation.width < 0)
                    pagingOffset = value.translation.width * (atEdge ? 0.25 : 1)
                    return
                }
                guard dragIntent == .dismissing else { return }
                dismissTranslation = value.translation
                dismissProgress = JournalPhotoDismissalPhysics.progress(value.translation)
            }
            .onEnded { value in
                defer { dragIntent = .undecided }
                guard !isCurrentPhotoZoomed, !isEditingDescription, !isCompletingDismiss, !isSettlingPage else { return }
                if dragIntent == .paging {
                    settlePage(translation: value.translation.width, predicted: value.predictedEndTranslation.width, width: proxy.size.width)
                    return
                }
                guard dragIntent == .dismissing else { return }
                if JournalPhotoDismissalPhysics.shouldDismiss(
                    translation: value.translation,
                    predicted: value.predictedEndTranslation
                ) {
                    completeDismiss(in: proxy)
                } else {
                    restorePreview()
                }
            }
    }

    private func settlePage(translation: CGFloat, predicted: CGFloat, width: CGFloat) {
        let distance = abs(translation) > width * 0.25 ? translation : predicted
        let direction = abs(distance) > width * 0.25 ? (distance < 0 ? 1 : -1) : 0
        let target = min(max(0, currentIndex + direction), max(0, photos.count - 1))
        isSettlingPage = true
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .removed) {
            pagingOffset = -CGFloat(target - currentIndex) * width
        } completion: {
            dismissWithoutAnimation {
                currentIndex = target
                pagingOffset = 0
                isSettlingPage = false
                isCurrentPhotoZoomed = false
            }
        }
    }

    private func interactiveScale(in size: CGSize) -> CGFloat {
        JournalPhotoDismissalPhysics.scale(
            progress: dismissProgress,
            viewportWidth: size.width,
            sourceWidth: currentPhoto?.sourceFrame?.width
        )
    }

    private func completeDismiss(in proxy: GeometryProxy) {
        isCompletingDismiss = true
        let rootFrame = proxy.frame(in: .global)
        let targetTranslation: CGSize
        if let sourceFrame = currentPhoto?.sourceFrame {
            targetTranslation = CGSize(
                width: sourceFrame.midX - rootFrame.midX,
                height: sourceFrame.midY - rootFrame.midY
            )
        } else {
            targetTranslation = dismissTranslation
        }
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            dismissTranslation = targetTranslation
            dismissProgress = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            if let onDismissAfterTransition {
                onDismissAfterTransition()
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dismiss() }
            }
        }
    }

    private func restorePreview() {
        guard !isCompletingDismiss else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.16)) {
            dismissTranslation = .zero
            dismissProgress = 0
        }
    }

    private var descriptionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let capturedAt = currentPhoto?.capturedAt {
                Label(capturedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .bottom, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .padding(.bottom, 5)

                if isEditingDescription {
                    TextField("journal.descriptionPlaceholder", text: $draftDescription, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1...3)
                        .focused($descriptionFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(saveDescription)

                    Button {
                        saveDescription()
                    } label: {
                        if isSavingDescription {
                            ProgressView()
                                .frame(width: 44, height: 32)
                        } else {
                            Text("common.save")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                        }
                    }
                    .buttonStyle(.plain)
                    .background(PrimaryTabPalette.accent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .disabled(isSavingDescription)
                } else {
                    Text(displayDescription)
                        .font(.subheadline)
                        .foregroundStyle(hasDescription ? .white.opacity(0.92) : .white.opacity(0.5))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard onSaveDescription != nil else { return }
                            draftDescription = editableDescription
                            isEditingDescription = true
                            descriptionFieldFocused = true
                        }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    /// 进入编辑时的草稿值：优先本会话已保存的，其次照片携带的。
    private var editableDescription: String {
        if let saved = savedDescriptions[currentIndex] { return saved }
        return currentPhoto?.description ?? ""
    }

    private var hasDescription: Bool {
        !editableDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayDescription: String {
        hasDescription
            ? editableDescription
            : (onSaveDescription != nil ? String(localized: "journal.addDescription") : "")
    }

    private func saveDescription() {
        guard let onSaveDescription, let imageKey = currentPhoto?.id, !isSavingDescription else { return }
        let trimmed = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingDescription = true
        descriptionFieldFocused = false
        Task {
            await onSaveDescription(imageKey, trimmed)
            savedDescriptions[currentIndex] = trimmed
            isSavingDescription = false
            isEditingDescription = false
        }
    }
}

/// 单张可缩放照片页：缩放/拖拽状态页内独立，翻页自动复位。
private struct JournalZoomablePhoto: View {
    let photo: JournalPhotoViewer.Photo
    @Binding var isZoomed: Bool
    let isActive: Bool

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    /// 实况照片的主图和配对视频都从持久化缓存解析，绝不把远端 URL 交给预览层。
    private var localLivePhotoResources: (photo: URL, video: URL)? {
        guard let media = photo.media,
              media.kind == "livePhoto",
              let paired = media.pairedVideo,
              let photoURL = JournalPhotoLoader.shared.localResourceURL(
                originalURL: photo.url,
                cacheKey: media.key,
                preferredFileName: media.fileName
              ),
              let videoURL = JournalPhotoLoader.shared.localResourceURL(
                originalURL: paired.url.flatMap(URL.init(string:)),
                cacheKey: paired.key,
                preferredFileName: paired.fileName
              )
        else { return nil }
        return (photoURL, videoURL)
    }

    /// HDR 必须把本地原始 HEIC 直接交给 UIImageView。若先生成 CGImage
    /// 缩略图，系统相册写入的增益图会丢失，之后再请求高动态范围也只能显示 SDR。
    private var localOriginalPhotoURL: URL? {
        guard let media = photo.media else { return nil }
        return JournalPhotoLoader.shared.localResourceURL(
            originalURL: photo.url,
            cacheKey: media.key,
            preferredFileName: media.fileName
        )
    }

    var body: some View {
        GeometryReader { viewport in
            Group {
                if let resources = localLivePhotoResources {
                    JournalLivePhotoView(photoURL: resources.photo, videoURL: resources.video, isActive: isActive)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoomGesture)
                        .gesture(panGesture, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2, perform: toggleZoom)
                        .overlay(alignment: .topLeading) {
                            Label("journal.liveBadge", systemImage: "livephoto")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                } else if photo.media?.isHDR == true, let originalURL = localOriginalPhotoURL {
                    JournalHDRPhotoView(url: originalURL)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoomGesture)
                        .gesture(panGesture, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2, perform: toggleZoom)
                        .overlay(alignment: .topLeading) {
                            Text("HDR")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .allowedDynamicRange(.high)
                        .scaledToFit()
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        // 捏合与双击始终可用；拖拽仅在放大后启用，
                        // 未放大时由查看器的统一拖动入口决定翻页或关闭。
                        .gesture(zoomGesture)
                        .gesture(panGesture, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2, perform: toggleZoom)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: photo.url) {
            guard let url = photo.url else { return }
            // 查看器严格读取本地持久化缓存；点击照片不会触发远端下载。
            image = await JournalPhotoLoader.shared.localThumbnail(
                for: url,
                maxPixelSize: 2400,
                cacheKey: photo.id
            )
        }
        .onChange(of: isActive) { _, active in
            if !active {
                scale = 1
                settledScale = 1
                resetOffset()
            }
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                scale = min(5, max(1, settledScale * value.magnification))
                isZoomed = scale > 1.01
            }
            .onEnded { _ in
                settledScale = scale
                isZoomed = scale > 1.01
                if scale == 1 {
                    resetOffset()
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                if scale > 1 {
                    settledOffset = offset
                } else {
                    resetOffset()
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if scale > 1 {
                scale = 1
                settledScale = 1
                isZoomed = false
                resetOffset()
            } else {
                scale = 2
                settledScale = 2
                isZoomed = true
            }
        }
    }

    private func resetOffset() {
        offset = .zero
        settledOffset = .zero
    }
}
