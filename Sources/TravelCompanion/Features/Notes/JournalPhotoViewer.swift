import SwiftUI

/// 全屏手书照片查看器：捏合缩放、拖拽平移、双击缩放、多图左右翻页、底部描述查看与编辑。
/// 详情页照片网格（多图翻页）与地图照片 pin 弹窗（单图）共用。
struct JournalPhotoViewer: View {
    struct Photo: Identifiable {
        let id: String
        let url: URL?
        let description: String?
        let capturedAt: Date?

        init(id: String, url: URL?, description: String?, capturedAt: Date?) {
            self.id = id
            self.url = url
            self.description = description
            self.capturedAt = capturedAt
        }
    }

    let photos: [Photo]
    let initialIndex: Int
    /// 非nil 时描述条可进入编辑并保存（imageKey 随当前页走，翻页后保存的是
    /// 正在看的那张）；nil 表示只读（无描述编辑入口）。
    let onSaveDescription: ((_ imageKey: String, _ description: String) async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var isEditingDescription = false
    @State private var draftDescription = ""
    @State private var isSavingDescription = false
    /// 已保存描述的本地回显（index → 最新值），避免保存后依赖外部重建才刷新。
    @State private var savedDescriptions: [Int: String] = [:]
    @FocusState private var descriptionFieldFocused: Bool

    init(
        photos: [Photo],
        initialIndex: Int = 0,
        onSaveDescription: ((_ imageKey: String, _ description: String) async -> Void)? = nil
    ) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.onSaveDescription = onSaveDescription
        _currentIndex = State(initialValue: min(max(0, initialIndex), max(0, photos.count - 1)))
    }

    private var currentPhoto: Photo? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if photos.count > 1 {
                TabView(selection: $currentIndex) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        JournalZoomablePhoto(id: photo.id, url: photo.url)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentIndex) { _ in
                    isEditingDescription = false
                    descriptionFieldFocused = false
                }
            } else if let photo = currentPhoto {
                JournalZoomablePhoto(id: photo.id, url: photo.url)
            }

            // 顶部：关闭 + 页码
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

            // 底部：拍摄时间 + 描述（可编辑）
            VStack(spacing: 10) {
                Spacer()
                descriptionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
        }
        .presentationBackground(.black)
        .statusBarHidden()
        .onAppear {
            draftDescription = currentPhoto?.description ?? ""
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
    let id: String
    let url: URL?

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    // 捏合与双击始终可用；拖拽仅在放大后启用，
                    // 未放大时把滑动手势留给 TabView 翻页。
                    .gesture(zoomGesture)
                    .gesture(panGesture, including: scale > 1 ? .all : .none)
                    .onTapGesture(count: 2, perform: toggleZoom)
            } else {
                ProgressView()
                    .tint(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard let url else { return }
            // 全尺寸查看用较大像素上限，兼顾内存与清晰度；命中 NSCache 时零开销。
            image = await JournalPhotoLoader.shared.thumbnail(for: url, maxPixelSize: 2400, cacheKey: id)
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                scale = min(5, max(1, settledScale * value.magnification))
            }
            .onEnded { _ in
                settledScale = scale
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
                resetOffset()
            } else {
                scale = 2
                settledScale = 2
            }
        }
    }

    private func resetOffset() {
        offset = .zero
        settledOffset = .zero
    }
}
