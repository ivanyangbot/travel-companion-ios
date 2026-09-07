import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// 手书照片地图 pin 数据：来自带拍摄位置的照片（静态图与实况照片的主图）。
/// 坐标沿用 POI 的口径（国内为 GCJ-02），显示时与首页地图同一套转换。
struct JournalPhotoPin: Identifiable, Hashable, Sendable {
    let id: String
    let entryID: Int
    let entryTitle: String
    let imageURL: URL?
    let latitude: Double
    let longitude: Double
    let capturedAt: Date?
    let description: String?

    init?(entry: JournalEntry, image: JournalImage, fallbackCoordinate: CLLocationCoordinate2D? = nil) {
        guard image.kind == nil || image.kind == "photo" || image.kind == "livePhoto" else { return nil }
        guard let latitude = image.latitude ?? fallbackCoordinate?.latitude,
              let longitude = image.longitude ?? fallbackCoordinate?.longitude,
              (-90.0 ... 90.0).contains(latitude),
              (-180.0 ... 180.0).contains(longitude) else { return nil }
        id = image.key
        entryID = entry.id
        entryTitle = entry.title
        imageURL = image.url.flatMap(URL.init(string:))
        self.latitude = latitude
        self.longitude = longitude
        capturedAt = image.capturedAt
        description = image.description
    }
}

/// 手书页的照片地图（仿行程 tab 地图的 MapLibre 风格，独立画布，
/// 不改动首页 TodayMap）：带位置的照片钉在拍摄地点，屏幕上相邻的
/// 照片聚合为堆叠 pin；点击单张或"已放不散"的组弹查看器（组内翻页），
/// 点击可散开的组先放大一级展开。
struct JournalPhotoMapScreen: View {
    let pins: [JournalPhotoPin]
    /// 点击的 pin（单张）或聚合组（多张，查看器内翻页）。
    let onPhotosSelected: ([JournalPhotoPin]) -> Void

    var body: some View {
        ZStack {
            if pins.isEmpty {
                PrimaryTabPalette.background.ignoresSafeArea()
                ContentUnavailableView {
                    Label("journal.mapEmptyTitle", systemImage: "map")
                } description: {
                    Text("journal.mapEmptyDesc")
                }
            } else {
                JournalMapCanvas(pins: pins, onPhotosSelected: onPhotosSelected)
            }
        }
    }
}

struct JournalMapCanvas: UIViewRepresentable {
    let pins: [JournalPhotoPin]
    let onPhotosSelected: ([JournalPhotoPin]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "TodayMapStyle", withExtension: "json")
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.backgroundColor = UIColor(red: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1)
        mapView.minimumZoomLevel = 1
        mapView.maximumZoomLevel = 20
        mapView.allowsTilting = false
        mapView.allowsRotating = false
        mapView.showsUserLocation = false
        mapView.showsLogoView = false
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 12, y: 24)
        context.coordinator.updateContent(on: mapView, pins: pins, onPhotosSelected: onPhotosSelected)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.updateContent(on: mapView, pins: pins, onPhotosSelected: onPhotosSelected)
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor MLNMapViewDelegate {
        /// 两组中心的最小屏幕间距（pt）：低于它合并为堆叠 pin。
        private static let clusterThreshold: CGFloat = 56
        /// 已放到街道级仍聚在一起（或完全同点）时不再放大，直接弹组内翻页。
        private static let expandZoomLimit: Double = 16.5
        /// 完全同点判定（约 0.1m 内，放大也无法散开）。
        private static let sameLocationEpsilon = 1e-6

        private var allAnnotations: [JournalPhotoAnnotation] = []
        private var displayedPins: [JournalPhotoPin] = []
        /// 锚点 pin id → 组内成员（含锚点自身）；仅锚点的 annotation view 可见。
        private var clusterMembers: [String: [JournalPhotoPin]] = [:]
        private var onPhotosSelected: (([JournalPhotoPin]) -> Void)?
        private var hasFinishedLoadingMap = false

        func updateContent(
            on mapView: MLNMapView,
            pins: [JournalPhotoPin],
            onPhotosSelected: @escaping ([JournalPhotoPin]) -> Void
        ) {
            self.onPhotosSelected = onPhotosSelected
            guard pins != displayedPins else { return }
            // 仅 pin 集合增减时重新取景；预签名 URL 刷新等元数据变化不打断用户当前视角。
            let pinSetChanged = Set(pins.map(\.id)) != Set(displayedPins.map(\.id))
            displayedPins = pins
            mapView.removeAnnotations(allAnnotations)
            allAnnotations = pins.map { pin in
                let annotation = JournalPhotoAnnotation()
                annotation.coordinate = MapLibreCoordinateTransform.displayCoordinate(
                    for: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                )
                annotation.pin = pin
                return annotation
            }
            mapView.addAnnotations(allAnnotations)
            relayoutClusters(on: mapView)
            if pinSetChanged, !allAnnotations.isEmpty {
                fitAllPins(on: mapView, remainingRetries: 3)
            }
        }

        func tearDown() {
            onPhotosSelected = nil
        }

        // MARK: - 聚合布局

        /// 把所有 pin 投影到屏幕坐标做贪心碰撞分组：
        /// 顺序扫描（数组顺序即分组优先级），与已建组锚点距离小于阈值的并入该组。
        private func relayoutClusters(on mapView: MLNMapView) {
            var groups: [(anchor: JournalPhotoAnnotation, anchorPoint: CGPoint, members: [JournalPhotoPin])] = []
            for annotation in allAnnotations {
                guard let pin = annotation.pin else { continue }
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                if let index = groups.firstIndex(where: { group in
                    hypot(group.anchorPoint.x - point.x, group.anchorPoint.y - point.y) < Self.clusterThreshold
                }) {
                    groups[index].members.append(pin)
                } else {
                    groups.append((annotation, point, [pin]))
                }
            }
            clusterMembers = Dictionary(
                groups.compactMap { group -> (String, [JournalPhotoPin])? in
                    guard let id = group.anchor.pin?.id else { return nil }
                    return (id, group.members)
                },
                uniquingKeysWith: { first, _ in first }
            )

            for annotation in allAnnotations {
                guard let view = mapView.view(for: annotation) as? JournalPhotoAnnotationView,
                      let pin = annotation.pin else { continue }
                if let members = clusterMembers[pin.id] {
                    view.configure(pin: pin, memberCount: members.count)
                    view.isHidden = false
                } else {
                    view.isHidden = true
                }
            }
        }

        /// 组内成员是否全部同点（放大也散不开，直接翻页浏览）。
        private static func isSameLocation(_ members: [JournalPhotoPin]) -> Bool {
            guard let first = members.first else { return true }
            return members.allSatisfy { pin in
                abs(pin.latitude - first.latitude) < sameLocationEpsilon
                    && abs(pin.longitude - first.longitude) < sameLocationEpsilon
            }
        }

        // MARK: - 相机

        /// 首次进入或照片集合变化时框住全部照片。
        private func fitAllPins(on mapView: MLNMapView, remainingRetries: Int) {
            // makeUIView 阶段 bounds 尚为 zero，延后一个 runloop 再试。
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
                guard remainingRetries > 0 else { return }
                Task { @MainActor [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.fitAllPins(on: mapView, remainingRetries: remainingRetries - 1)
                }
                return
            }
            let coordinates = allAnnotations.map(\.coordinate)
            guard let first = coordinates.first else { return }
            var minLatitude = first.latitude
            var maxLatitude = first.latitude
            var minLongitude = first.longitude
            var maxLongitude = first.longitude
            for coordinate in coordinates {
                minLatitude = min(minLatitude, coordinate.latitude)
                maxLatitude = max(maxLatitude, coordinate.latitude)
                minLongitude = min(minLongitude, coordinate.longitude)
                maxLongitude = max(maxLongitude, coordinate.longitude)
            }
            // 单点时给一个可视街区级跨度，避免过度放大。
            if coordinates.count == 1 || (maxLatitude - minLatitude < 0.002 && maxLongitude - minLongitude < 0.002) {
                minLatitude -= 0.01
                maxLatitude += 0.01
                minLongitude -= 0.01
                maxLongitude += 0.01
            }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude),
                ne: CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude)
            )
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 90, left: 36, bottom: 120, right: 36),
                animated: true
            )
        }

        // MARK: - MLNMapViewDelegate

        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: any MLNAnnotation
        ) -> MLNAnnotationView? {
            guard let annotation = annotation as? JournalPhotoAnnotation, let pin = annotation.pin else {
                return nil
            }
            let identifier = JournalPhotoAnnotationView.reuseIdentifier
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? JournalPhotoAnnotationView
                ?? JournalPhotoAnnotationView(reuseIdentifier: identifier)
            view.configure(pin: pin, memberCount: clusterMembers[pin.id]?.count ?? 1)
            return view
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: any MLNAnnotation) {
            guard let annotation = annotation as? JournalPhotoAnnotation, let pin = annotation.pin else {
                return
            }
            mapView.deselectAnnotation(annotation, animated: false)
            let members = clusterMembers[pin.id] ?? [pin]
            guard members.count > 1 else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onPhotosSelected?(members)
                return
            }
            // 聚合组：同点或已放到街道级 → 组内翻页；否则放大一级让重排散开。
            if Self.isSameLocation(members) || mapView.zoomLevel >= Self.expandZoomLimit {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onPhotosSelected?(members)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let center = CLLocationCoordinate2D(
                    latitude: members.map(\.latitude).reduce(0, +) / Double(members.count),
                    longitude: members.map(\.longitude).reduce(0, +) / Double(members.count)
                )
                mapView.setCenter(center, zoomLevel: mapView.zoomLevel + 1.5, animated: true)
            }
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            hasFinishedLoadingMap = true
            relayoutClusters(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // 相机静止后重算聚合（缩放/平移把不同照片推近或拉开）。
            guard hasFinishedLoadingMap || mapView.bounds.width > 0 else { return }
            relayoutClusters(on: mapView)
        }
    }
}

final class JournalPhotoAnnotation: MLNPointAnnotation {
    var pin: JournalPhotoPin?
}

/// 照片 pin：白描边圆角缩略方块，中心即拍摄坐标；聚合时叠两张错位底片
/// 并在右下角显示数量胶囊，选中时弹簧放大。
final class JournalPhotoAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "JournalPhotoPin"

    /// 容器尺寸（容纳堆叠底片的错位）。
    private static let containerSide: CGFloat = 68
    private static let photoSide: CGFloat = 48

    private let photoBack1 = UIView()
    private let photoBack2 = UIView()
    private let photoBacking = UIView()
    private let imageView = UIImageView()
    private let countBadge = UILabel()
    private var loadTask: Task<Void, Never>?
    private var memberCount = 1
    private var currentPinID: String?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.containerSide, height: Self.containerSide)
        backgroundColor = .clear

        let side = Self.photoSide
        let photoFrame = CGRect(
            x: (Self.containerSide - side) / 2,
            y: (Self.containerSide - side) / 2,
            width: side,
            height: side
        )

        for (view, offset, rotation) in [(photoBack1, -5.0, -0.05), (photoBack2, 5.0, 0.06)] {
            view.frame = photoFrame.insetBy(dx: 2, dy: 2)
            view.center = CGPoint(
                x: photoFrame.midX + offset,
                y: photoFrame.midY - offset
            )
            view.backgroundColor = .white
            view.layer.cornerRadius = 10
            view.layer.cornerCurve = .continuous
            view.layer.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        photoBacking.frame = photoFrame
        photoBacking.backgroundColor = .white
        photoBacking.layer.cornerRadius = 12
        photoBacking.layer.cornerCurve = .continuous
        photoBacking.layer.shadowColor = UIColor.black.cgColor
        photoBacking.layer.shadowOpacity = 0.4
        photoBacking.layer.shadowRadius = 5
        photoBacking.layer.shadowOffset = CGSize(width: 0, height: 3)
        photoBacking.isUserInteractionEnabled = false
        addSubview(photoBacking)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 9.5
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor(white: 0.13, alpha: 1)
        imageView.frame = photoFrame.insetBy(dx: 2.5, dy: 2.5)
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        countBadge.text = "2"
        countBadge.font = .systemFont(ofSize: 12, weight: .bold)
        countBadge.textColor = .white
        countBadge.textAlignment = .center
        countBadge.backgroundColor = UIColor(white: 0, alpha: 0.78)
        countBadge.layer.cornerRadius = 9
        countBadge.layer.cornerCurve = .continuous
        countBadge.layer.masksToBounds = true
        countBadge.frame = CGRect(x: 0, y: 0, width: 30, height: 18)
        countBadge.center = CGPoint(
            x: photoFrame.maxX - 3,
            y: photoFrame.maxY + 1
        )
        countBadge.isHidden = true
        countBadge.isUserInteractionEnabled = false
        addSubview(countBadge)

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "journal.photoPinA11y")
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(pin: JournalPhotoPin, memberCount: Int) {
        let countChanged = memberCount != self.memberCount
        let pinChanged = pin.id != currentPinID
        self.memberCount = memberCount
        currentPinID = pin.id
        photoBack1.isHidden = memberCount < 3
        photoBack2.isHidden = memberCount < 2
        countBadge.isHidden = memberCount < 2
        if memberCount >= 2 {
            countBadge.text = "\(memberCount)"
            countBadge.sizeToFit()
            let center = countBadge.center
            var frame = countBadge.frame
            frame.size.width = max(frame.width + 12, 26)
            frame.size.height = 18
            countBadge.frame = frame
            countBadge.center = center
            accessibilityValue = "\(memberCount)"
        }
        if countChanged, memberCount > 1 {
            // 聚合数量变化时给一个轻微的弹性确认。
            transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0.6,
                options: [.allowUserInteraction]
            ) {
                self.transform = .identity
            }
        }
        // 相机每次静止都会重排聚合并重调 configure；同图不清缓存重载，避免闪烁。
        guard pinChanged else { return }
        loadTask?.cancel()
        imageView.image = nil
        guard let url = pin.imageURL else { return }
        loadTask = Task { [weak self] in
            let image = await JournalPhotoLoader.shared.thumbnail(for: url, maxPixelSize: 120, cacheKey: pin.id)
            guard !Task.isCancelled, let self else { return }
            self.imageView.image = image
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        let target = selected
            ? CGAffineTransform(scaleX: 1.2, y: 1.2)
            : .identity
        if animated {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                usingSpringWithDamping: 0.55,
                initialSpringVelocity: 0.5,
                options: [.allowUserInteraction]
            ) {
                self.transform = target
            }
        } else {
            transform = target
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        memberCount = 1
        currentPinID = nil
        transform = .identity
        photoBack1.isHidden = true
        photoBack2.isHidden = true
        countBadge.isHidden = true
    }
}
