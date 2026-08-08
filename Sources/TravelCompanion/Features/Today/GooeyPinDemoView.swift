import SwiftUI
import UIKit

enum GooeyPinID: String, Equatable, Hashable {
    case aggregate
    case single
}

enum GooeyPinSnapState: String, Equatable {
    case fused
    case separated
}

struct GooeyPinNormalizedPoint: Equatable {
    static let center = Self(x: 0.5, y: 0.5)

    var x: CGFloat
    var y: CGFloat

    func normalized(fallback: Self = .center) -> Self {
        Self(
            x: Self.finiteUnit(x, fallback: fallback.x),
            y: Self.finiteUnit(y, fallback: fallback.y)
        )
    }

    private static func finiteUnit(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return min(1, max(0, fallback)) }
        return min(1, max(0, value))
    }
}

struct GooeyPinDemoParameters: Equatable {
    static let standard = Self(
        aggregateWidth: 112,
        blurRadius: 10,
        alphaThreshold: 0.48,
        sourceOpacity: 1,
        strokeWidth: 2,
        shadowRadius: 10,
        separationDistance: 84,
        mergeThreshold: 12,
        splitThreshold: 28,
        springResponse: 0.38,
        springDamping: 0.82
    )

    var aggregateWidth: CGFloat
    var blurRadius: CGFloat
    var alphaThreshold: CGFloat
    var sourceOpacity: CGFloat
    var strokeWidth: CGFloat
    var shadowRadius: CGFloat
    var separationDistance: CGFloat
    var mergeThreshold: CGFloat
    var splitThreshold: CGFloat
    var springResponse: CGFloat
    var springDamping: CGFloat

    func normalized() -> Self {
        var value = self
        value.aggregateWidth = Self.finiteClamp(value.aggregateWidth, 48...180, fallback: 112)
        value.blurRadius = Self.finiteClamp(value.blurRadius, 0...24, fallback: 10)
        value.alphaThreshold = Self.finiteClamp(value.alphaThreshold, 0.05...0.95, fallback: 0.48)
        value.sourceOpacity = Self.finiteClamp(value.sourceOpacity, 0.2...1, fallback: 1)
        value.strokeWidth = Self.finiteClamp(value.strokeWidth, 0...6, fallback: 2)
        value.shadowRadius = Self.finiteClamp(value.shadowRadius, 0...24, fallback: 10)
        value.separationDistance = Self.finiteClamp(value.separationDistance, 40...120, fallback: 84)
        value.mergeThreshold = Self.finiteClamp(value.mergeThreshold, 0...40, fallback: 12)
        value.splitThreshold = Self.finiteClamp(value.splitThreshold, 4...60, fallback: 28)
        if value.splitThreshold < value.mergeThreshold + 4 {
            value.splitThreshold = min(60, value.mergeThreshold + 4)
            value.mergeThreshold = min(value.mergeThreshold, value.splitThreshold - 4)
        }
        value.springResponse = Self.finiteClamp(value.springResponse, 0.1...1, fallback: 0.38)
        value.springDamping = Self.finiteClamp(value.springDamping, 0.2...1, fallback: 0.82)
        return value
    }

    private static func finiteClamp(
        _ value: CGFloat,
        _ range: ClosedRange<CGFloat>,
        fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

enum GooeyPinSnapResolver {
    static func resolvedState(
        surfaceGap: CGFloat,
        previous: GooeyPinSnapState,
        mergeThreshold: CGFloat,
        splitThreshold: CGFloat
    ) -> GooeyPinSnapState {
        let finiteGap = surfaceGap.isFinite ? surfaceGap : 0
        let merge = mergeThreshold.isFinite ? mergeThreshold : 0
        let splitCandidate = splitThreshold.isFinite ? splitThreshold : merge + 4
        let split = max(merge + 4, splitCandidate)
        if finiteGap <= merge { return .fused }
        if finiteGap >= split { return .separated }
        return previous
    }
}

enum GooeyPinNumberScenarioID: String, CaseIterable {
    case rightEdge
    case upperLeft

    var title: String {
        switch self {
        case .rightEdge: "4 · 右侧"
        case .upperLeft: "3 · 左上"
        }
    }
}

struct GooeyPinNumberMember: Identifiable, Equatable {
    let id: String
    let value: String
    let relativePosition: CGPoint
}

struct GooeyPinNumberScenario: Equatable {
    static let rightEdge = Self(
        id: .rightEdge,
        members: [
            GooeyPinNumberMember(id: "right-2", value: "2", relativePosition: CGPoint(x: -1, y: -0.2)),
            GooeyPinNumberMember(id: "right-3", value: "3", relativePosition: CGPoint(x: -0.5, y: 0.3)),
            GooeyPinNumberMember(id: "right-7", value: "7", relativePosition: CGPoint(x: 0, y: -0.4)),
            GooeyPinNumberMember(id: "right-5", value: "5", relativePosition: CGPoint(x: 0.5, y: 0.2)),
            GooeyPinNumberMember(id: "right-4", value: "4", relativePosition: CGPoint(x: 1, y: 0))
        ],
        extractedMemberID: "right-4",
        aggregatePosition: GooeyPinNormalizedPoint(x: 0.18, y: 0.5),
        singlePosition: GooeyPinNormalizedPoint(x: 0.82, y: 0.5)
    )

    static let upperLeft = Self(
        id: .upperLeft,
        members: [
            GooeyPinNumberMember(id: "upper-left-7", value: "7", relativePosition: CGPoint(x: -1, y: 0.1)),
            GooeyPinNumberMember(id: "upper-left-3", value: "3", relativePosition: CGPoint(x: -0.45, y: -1)),
            GooeyPinNumberMember(id: "upper-left-8", value: "8", relativePosition: CGPoint(x: 0.25, y: 0.15)),
            GooeyPinNumberMember(id: "upper-left-12", value: "12", relativePosition: CGPoint(x: 1, y: 0.65))
        ],
        extractedMemberID: "upper-left-3",
        aggregatePosition: GooeyPinNormalizedPoint(x: 0.62, y: 0.64),
        singlePosition: GooeyPinNormalizedPoint(x: 0.16, y: 0.14)
    )

    let id: GooeyPinNumberScenarioID
    let members: [GooeyPinNumberMember]
    let extractedMemberID: String
    let aggregatePosition: GooeyPinNormalizedPoint
    let singlePosition: GooeyPinNormalizedPoint
    let memberOrderIDs: [String]?

    init(
        id: GooeyPinNumberScenarioID,
        members: [GooeyPinNumberMember],
        extractedMemberID: String,
        aggregatePosition: GooeyPinNormalizedPoint,
        singlePosition: GooeyPinNormalizedPoint,
        memberOrderIDs: [String]? = nil
    ) {
        self.id = id
        self.members = members
        self.extractedMemberID = extractedMemberID
        self.aggregatePosition = aggregatePosition
        self.singlePosition = singlePosition
        self.memberOrderIDs = memberOrderIDs
    }

    static func scenario(for id: GooeyPinNumberScenarioID) -> Self {
        switch id {
        case .rightEdge: .rightEdge
        case .upperLeft: .upperLeft
        }
    }

    var orderedMembers: [GooeyPinNumberMember] {
        let spatiallyOrdered = GooeyPinNumberOrdering.ordered(members)
        guard let memberOrderIDs else { return spatiallyOrdered }

        let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var usedIDs = Set<String>()
        let explicitlyOrdered = memberOrderIDs.compactMap { id -> GooeyPinNumberMember? in
            guard usedIDs.insert(id).inserted else { return nil }
            return membersByID[id]
        }
        return explicitlyOrdered + spatiallyOrdered.filter { !usedIDs.contains($0.id) }
    }

    func applyingMemberOrder(_ memberOrderIDs: [String]) -> Self {
        Self(
            id: id,
            members: members,
            extractedMemberID: extractedMemberID,
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition,
            memberOrderIDs: memberOrderIDs
        )
    }

    var remainingMembers: [GooeyPinNumberMember] {
        orderedMembers.filter { $0.id != extractedMemberID }
    }

    var extractedMember: GooeyPinNumberMember {
        orderedMembers.first { $0.id == extractedMemberID } ?? orderedMembers[0]
    }

    var fusedText: String {
        orderedMembers.map(\.value).joined(separator: ".")
    }

    var separatedAggregateText: String {
        remainingMembers.map(\.value).joined(separator: ".")
    }

    var separationDirection: CGVector {
        let point = extractedMember.relativePosition
        let length = hypot(point.x, point.y)
        guard length.isFinite, length > 0.0001 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: point.x / length, dy: point.y / length)
    }
}

enum GooeyPinNumberOrdering {
    static func ordered(_ members: [GooeyPinNumberMember]) -> [GooeyPinNumberMember] {
        members.sorted { lhs, rhs in
            if abs(lhs.relativePosition.x - rhs.relativePosition.x) > 0.0001 {
                return lhs.relativePosition.x < rhs.relativePosition.x
            }
            if abs(lhs.relativePosition.y - rhs.relativePosition.y) > 0.0001 {
                return lhs.relativePosition.y < rhs.relativePosition.y
            }
            return lhs.id < rhs.id
        }
    }

    static func orderForMerge(
        orderedMembers: [GooeyPinNumberMember],
        extractedMemberID: String,
        direction: CGVector
    ) -> [String] {
        let remainingIDs = orderedMembers
            .filter { $0.id != extractedMemberID }
            .map(\.id)
        guard orderedMembers.contains(where: { $0.id == extractedMemberID }) else {
            return remainingIDs
        }

        let length = hypot(direction.dx, direction.dy)
        let normalizedX = length.isFinite && length > 0.0001 ? direction.dx / length : 1
        let horizontalProgress = min(1, max(0, (normalizedX + 1) / 2))
        let insertionIndex = min(
            remainingIDs.count,
            max(0, Int((horizontalProgress * CGFloat(remainingIDs.count)).rounded()))
        )
        var result = remainingIDs
        result.insert(extractedMemberID, at: insertionIndex)
        return result
    }
}

enum GooeyPinNumberOrderLock {
    static func updated(
        currentlyLocked: Bool,
        surfaceGap: CGFloat,
        splitThreshold: CGFloat
    ) -> Bool {
        guard currentlyLocked else { return false }
        guard surfaceGap.isFinite, splitThreshold.isFinite else { return true }
        return surfaceGap < splitThreshold
    }
}

struct GooeyPinNumberPlacement: Identifiable, Equatable {
    let id: String
    let value: String
    let position: CGPoint
}

struct GooeyPinNumberSeparatorPlacement: Identifiable, Equatable {
    let id: String
    let position: CGPoint
    let opacity: CGFloat
}

struct GooeyPinNumberPresentation: Equatable {
    let extractionProgress: CGFloat
    let memberPlacements: [GooeyPinNumberPlacement]
    let separatorPlacements: [GooeyPinNumberSeparatorPlacement]
    let fontSize: CGFloat

    func placement(for memberID: String) -> GooeyPinNumberPlacement? {
        memberPlacements.first { $0.id == memberID }
    }
}

enum GooeyPinNumberLayout {
    private static let labelFont = UIFont.systemFont(ofSize: 16, weight: .medium)

    static func extractionProgress(
        surfaceGap: CGFloat,
        mergeThreshold: CGFloat,
        splitThreshold: CGFloat
    ) -> CGFloat {
        let merge = mergeThreshold.isFinite ? mergeThreshold : 0
        let splitCandidate = splitThreshold.isFinite ? splitThreshold : merge + 4
        let split = max(merge + 4, splitCandidate)
        let gap = surfaceGap.isFinite ? surfaceGap : merge
        let linear = min(1, max(0, (gap - merge) / (split - merge)))
        return linear * linear * (3 - 2 * linear)
    }

    static func visualExtractionProgress(
        surfaceGap: CGFloat,
        parameters: GooeyPinDemoParameters
    ) -> CGFloat {
        let value = parameters.normalized()
        let alphaReachScale = min(1, max(0.25, 1.1 - value.alphaThreshold))
        let visibleBridgeReach = max(
            0,
            value.blurRadius * alphaReachScale + value.strokeWidth * 0.5
        )
        let outerGap = min(value.mergeThreshold, visibleBridgeReach)
        let transitionSpan = max(
            3,
            min(8, value.blurRadius * 0.5 + value.strokeWidth * 0.5)
        )
        return extractionProgress(
            surfaceGap: surfaceGap,
            mergeThreshold: outerGap - transitionSpan,
            splitThreshold: outerGap
        )
    }

    static func presentation(
        scenario: GooeyPinNumberScenario,
        layout: GooeyPinDemoLayout,
        extractionProgress requestedProgress: CGFloat
    ) -> GooeyPinNumberPresentation {
        let progress = requestedProgress.isFinite ? min(1, max(0, requestedProgress)) : 0
        let orderedMembers = scenario.orderedMembers
        let remainingMembers = scenario.remainingMembers
        let fullSlots = slots(for: orderedMembers, in: layout.aggregateFrame)
        let remainingSlots = slots(for: remainingMembers, in: layout.aggregateFrame)
        let singleCenter = CGPoint(x: layout.singleFrame.midX, y: layout.singleFrame.midY)

        let memberPlacements = orderedMembers.compactMap { member -> GooeyPinNumberPlacement? in
            guard let fullPosition = fullSlots[member.id] else { return nil }
            let targetPosition: CGPoint
            if member.id == scenario.extractedMemberID {
                targetPosition = singleCenter
            } else {
                targetPosition = remainingSlots[member.id] ?? fullPosition
            }
            return GooeyPinNumberPlacement(
                id: member.id,
                value: member.value,
                position: interpolate(from: fullPosition, to: targetPosition, progress: progress)
            )
        }

        let fullSeparators = separators(for: orderedMembers, slots: fullSlots)
        let remainingSeparators = separators(for: remainingMembers, slots: remainingSlots)
        let separatorKeys = Set(fullSeparators.keys).union(remainingSeparators.keys).sorted()
        let separatorPlacements = separatorKeys.compactMap { key -> GooeyPinNumberSeparatorPlacement? in
            switch (fullSeparators[key], remainingSeparators[key]) {
            case let (.some(full), .some(remaining)):
                return GooeyPinNumberSeparatorPlacement(
                    id: key,
                    position: interpolate(from: full, to: remaining, progress: progress),
                    opacity: 1
                )
            case let (.some(full), .none):
                return GooeyPinNumberSeparatorPlacement(id: key, position: full, opacity: 1 - progress)
            case let (.none, .some(remaining)):
                return GooeyPinNumberSeparatorPlacement(id: key, position: remaining, opacity: progress)
            case (.none, .none):
                return nil
            }
        }

        return GooeyPinNumberPresentation(
            extractionProgress: progress,
            memberPlacements: memberPlacements,
            separatorPlacements: separatorPlacements,
            fontSize: labelFont.pointSize
        )
    }

    private static func slots(
        for members: [GooeyPinNumberMember],
        in frame: CGRect
    ) -> [String: CGPoint] {
        guard !members.isEmpty else { return [:] }
        let memberWidths = members.map { measuredWidth(of: $0.value) }
        let separatorWidth = measuredWidth(of: ".")
        let totalWidth = memberWidths.reduce(0, +)
            + separatorWidth * CGFloat(max(0, members.count - 1))
        var cursor = frame.midX - totalWidth / 2
        var result: [String: CGPoint] = [:]
        for (index, member) in members.enumerated() {
            let width = memberWidths[index]
            result[member.id] = CGPoint(x: cursor + width / 2, y: frame.midY)
            cursor += width
            if index < members.count - 1 { cursor += separatorWidth }
        }
        return result
    }

    private static func separators(
        for members: [GooeyPinNumberMember],
        slots: [String: CGPoint]
    ) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: zip(members, members.dropFirst()).compactMap { lhs, rhs in
            guard let lhsPoint = slots[lhs.id], let rhsPoint = slots[rhs.id] else { return nil }
            return (
                lhs.id + "→" + rhs.id,
                CGPoint(x: (lhsPoint.x + rhsPoint.x) / 2, y: (lhsPoint.y + rhsPoint.y) / 2)
            )
        })
    }

    private static func interpolate(from: CGPoint, to: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
    }

    private static func measuredWidth(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: labelFont]).width)
    }
}

enum GooeyPinAdaptiveLayout {
    static func layout(
        stageSize: CGSize,
        aggregatePosition: GooeyPinNormalizedPoint,
        singlePosition: GooeyPinNormalizedPoint,
        scenario: GooeyPinNumberScenario,
        parameters: GooeyPinDemoParameters,
        effectPadding: CGFloat,
        fallbackDirection: CGVector
    ) -> GooeyPinDemoLayout {
        let fusedWidth = MapLibrePinLabelGeometry.size(for: scenario.fusedText).width
        let separatedWidth = MapLibrePinLabelGeometry.size(for: scenario.separatedAggregateText).width
        var aggregateWidth = separatedWidth
        var result = GooeyPinDemoGeometry.layout(
            stageSize: stageSize,
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition,
            aggregateWidth: aggregateWidth,
            effectPadding: effectPadding,
            fallbackDirection: fallbackDirection
        )

        for _ in 0..<4 {
            let progress = GooeyPinNumberLayout.visualExtractionProgress(
                surfaceGap: result.metrics.surfaceGap,
                parameters: parameters
            )
            aggregateWidth = fusedWidth + (separatedWidth - fusedWidth) * progress
            result = GooeyPinDemoGeometry.layout(
                stageSize: stageSize,
                aggregatePosition: aggregatePosition,
                singlePosition: singlePosition,
                aggregateWidth: aggregateWidth,
                effectPadding: effectPadding,
                fallbackDirection: fallbackDirection
            )
        }
        return result
    }
}

struct GooeyPinDemoState: Equatable {
    static let standard: Self = {
        let scenario = GooeyPinNumberScenario.rightEdge
        return Self(
            parameters: .standard,
            numberScenarioID: scenario.id,
            numberMemberOrderIDs: scenario.orderedMembers.map(\.id),
            aggregatePosition: scenario.aggregatePosition,
            singlePosition: scenario.singlePosition,
            snapState: .separated,
            lastDirection: scenario.separationDirection,
            lastActivePin: .single
        )
    }()

    var parameters: GooeyPinDemoParameters
    var numberScenarioID: GooeyPinNumberScenarioID
    var numberMemberOrderIDs: [String]
    var aggregatePosition: GooeyPinNormalizedPoint
    var singlePosition: GooeyPinNormalizedPoint
    var snapState: GooeyPinSnapState
    var lastDirection: CGVector
    var lastActivePin: GooeyPinID

    var numberScenario: GooeyPinNumberScenario {
        GooeyPinNumberScenario
            .scenario(for: numberScenarioID)
            .applyingMemberOrder(numberMemberOrderIDs)
    }

    func position(for pin: GooeyPinID) -> GooeyPinNormalizedPoint {
        switch pin {
        case .aggregate: aggregatePosition
        case .single: singlePosition
        }
    }

    mutating func setPosition(_ position: GooeyPinNormalizedPoint, for pin: GooeyPinID) {
        switch pin {
        case .aggregate: aggregatePosition = position.normalized()
        case .single: singlePosition = position.normalized()
        }
    }

    mutating func applyNumberScenario(_ id: GooeyPinNumberScenarioID) {
        let scenario = GooeyPinNumberScenario.scenario(for: id)
        numberScenarioID = id
        numberMemberOrderIDs = scenario.orderedMembers.map(\.id)
        aggregatePosition = scenario.aggregatePosition
        singlePosition = scenario.singlePosition
        snapState = .separated
        lastDirection = scenario.separationDirection
        lastActivePin = .single
    }

    mutating func updateNumberOrderForMerge(direction: CGVector) {
        numberMemberOrderIDs = GooeyPinNumberOrdering.orderForMerge(
            orderedMembers: numberScenario.orderedMembers,
            extractedMemberID: numberScenario.extractedMemberID,
            direction: direction
        )
    }

    mutating func reset() {
        self = .standard
    }
}

struct GooeyPinSpatialMetrics: Equatable {
    let surfaceGap: CGFloat
    let angleDegrees: CGFloat
    let direction: CGVector
    let hasDistinctCenters: Bool
}

enum GooeyPinEffectGeometry {
    static let safetyMargin: CGFloat = 8

    static func shadowOffset(for radius: CGFloat) -> CGFloat {
        let finiteRadius = radius.isFinite ? max(0, radius) : 0
        return finiteRadius / 3
    }

    static func safePadding(for parameters: GooeyPinDemoParameters) -> CGFloat {
        let value = parameters.normalized()
        return max(
            12,
            value.blurRadius
                + value.shadowRadius
                + abs(shadowOffset(for: value.shadowRadius))
                + safetyMargin
        )
    }
}

struct GooeyPinPhysicalPlacement: Equatable {
    let center: CGPoint
    let centerBounds: CGRect
}

struct GooeyPinStagePlacement: Equatable {
    let aggregate: GooeyPinPhysicalPlacement
    let single: GooeyPinPhysicalPlacement

    func placement(for pin: GooeyPinID) -> GooeyPinPhysicalPlacement {
        switch pin {
        case .aggregate: aggregate
        case .single: single
        }
    }
}

struct GooeyPinBoundsReconciliation: Equatable {
    let aggregatePosition: GooeyPinNormalizedPoint?
    let singlePosition: GooeyPinNormalizedPoint?
    let rememberedPlacement: GooeyPinStagePlacement
}

enum GooeyPinBoundsReconciler {
    static func reconcile(
        previous: GooeyPinStagePlacement?,
        current: GooeyPinStagePlacement
    ) -> GooeyPinBoundsReconciliation {
        guard let previous else {
            return GooeyPinBoundsReconciliation(
                aggregatePosition: nil,
                singlePosition: nil,
                rememberedPlacement: current
            )
        }

        let aggregate = reconcilePin(previous: previous.aggregate, current: current.aggregate)
        let single = reconcilePin(previous: previous.single, current: current.single)
        return GooeyPinBoundsReconciliation(
            aggregatePosition: aggregate.position,
            singlePosition: single.position,
            rememberedPlacement: GooeyPinStagePlacement(
                aggregate: aggregate.remembered,
                single: single.remembered
            )
        )
    }

    private static func reconcilePin(
        previous: GooeyPinPhysicalPlacement,
        current: GooeyPinPhysicalPlacement
    ) -> (position: GooeyPinNormalizedPoint?, remembered: GooeyPinPhysicalPlacement) {
        guard !approximatelyEqual(previous.centerBounds, current.centerBounds) else {
            return (nil, current)
        }
        let preservedCenter = clamped(previous.center, to: current.centerBounds)
        let position = GooeyPinDemoGeometry.normalizedPosition(
            for: preservedCenter,
            in: current.centerBounds
        )
        return (
            position,
            GooeyPinPhysicalPlacement(center: preservedCenter, centerBounds: current.centerBounds)
        )
    }

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX, max(bounds.minX, point.x.isFinite ? point.x : bounds.midX)),
            y: min(bounds.maxY, max(bounds.minY, point.y.isFinite ? point.y : bounds.midY))
        )
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.001
            && abs(lhs.minY - rhs.minY) < 0.001
            && abs(lhs.width - rhs.width) < 0.001
            && abs(lhs.height - rhs.height) < 0.001
    }
}

struct GooeyPinDemoLayout: Equatable {
    static let pinHeight: CGFloat = 32

    let stageSize: CGSize
    let effectPadding: CGFloat
    let contentFrame: CGRect
    let aggregateCenterBounds: CGRect
    let singleCenterBounds: CGRect
    let aggregateFrame: CGRect
    let singleFrame: CGRect
    let metrics: GooeyPinSpatialMetrics

    func centerBounds(for pin: GooeyPinID) -> CGRect {
        switch pin {
        case .aggregate: aggregateCenterBounds
        case .single: singleCenterBounds
        }
    }

    var placement: GooeyPinStagePlacement {
        GooeyPinStagePlacement(
            aggregate: GooeyPinPhysicalPlacement(
                center: CGPoint(x: aggregateFrame.midX, y: aggregateFrame.midY),
                centerBounds: aggregateCenterBounds
            ),
            single: GooeyPinPhysicalPlacement(
                center: CGPoint(x: singleFrame.midX, y: singleFrame.midY),
                centerBounds: singleCenterBounds
            )
        )
    }
}

enum GooeyPinHitTarget: Equatable {
    case aggregate
    case single
}

struct GooeyPinHitGeometry: Equatable {
    static let minimumTargetSize: CGFloat = 56
    static let aggregateEndHandleWidth: CGFloat = 32

    let aggregateTargetFrame: CGRect
    let singleTargetFrame: CGRect
    let singlePriorityFrame: CGRect
    let aggregateEndHandleFrames: [CGRect]

    init(layout: GooeyPinDemoLayout) {
        aggregateTargetFrame = CGRect(
            x: layout.aggregateFrame.midX - max(Self.minimumTargetSize, layout.aggregateFrame.width) / 2,
            y: layout.aggregateFrame.midY - Self.minimumTargetSize / 2,
            width: max(Self.minimumTargetSize, layout.aggregateFrame.width),
            height: Self.minimumTargetSize
        )
        singleTargetFrame = CGRect(
            x: layout.singleFrame.midX - Self.minimumTargetSize / 2,
            y: layout.singleFrame.midY - Self.minimumTargetSize / 2,
            width: Self.minimumTargetSize,
            height: Self.minimumTargetSize
        )
        singlePriorityFrame = layout.singleFrame
        aggregateEndHandleFrames = [layout.aggregateFrame.minX, layout.aggregateFrame.maxX].map { centerX in
            CGRect(
                x: centerX - Self.aggregateEndHandleWidth / 2,
                y: layout.aggregateFrame.midY - Self.minimumTargetSize / 2,
                width: Self.aggregateEndHandleWidth,
                height: Self.minimumTargetSize
            )
        }
    }

    func hitTarget(at point: CGPoint) -> GooeyPinHitTarget? {
        let priorityRadius = min(singlePriorityFrame.width, singlePriorityFrame.height) / 2
        if hypot(point.x - singlePriorityFrame.midX, point.y - singlePriorityFrame.midY) <= priorityRadius {
            return .single
        }
        if aggregateEndHandleFrames.contains(where: { $0.contains(point) }) {
            return .aggregate
        }
        let singleRadius = singleTargetFrame.width / 2
        if hypot(point.x - singleTargetFrame.midX, point.y - singleTargetFrame.midY) <= singleRadius {
            return .single
        }
        if aggregateTargetFrame.contains(point) {
            return .aggregate
        }
        return nil
    }
}

enum GooeyPinDemoGeometry {
    static let fusedSurfaceGap: CGFloat = -12

    static func layout(
        stageSize: CGSize,
        aggregatePosition: GooeyPinNormalizedPoint,
        singlePosition: GooeyPinNormalizedPoint,
        aggregateWidth requestedWidth: CGFloat,
        effectPadding requestedPadding: CGFloat,
        fallbackDirection: CGVector = CGVector(dx: 1, dy: 0)
    ) -> GooeyPinDemoLayout {
        let stageWidth = finitePositive(stageSize.width, fallback: 520)
        let stageHeight = finitePositive(stageSize.height, fallback: 280)
        let sanitizedStageSize = CGSize(width: stageWidth, height: stageHeight)
        let pinHeight = min(GooeyPinDemoLayout.pinHeight, min(stageWidth, stageHeight))
        let maximumPadding = max(
            0,
            min((stageWidth - pinHeight) / 2, (stageHeight - pinHeight) / 2)
        )
        let padding = finiteClamp(requestedPadding, 0...maximumPadding, fallback: 0)
        let content = CGRect(
            x: padding,
            y: padding,
            width: max(pinHeight, stageWidth - padding * 2),
            height: max(pinHeight, stageHeight - padding * 2)
        )
        let minimumAggregateWidth = min(pinHeight, content.width)
        let maximumAggregateWidth = min(180, content.width)
        let aggregateWidth = finiteClamp(
            requestedWidth,
            minimumAggregateWidth...maximumAggregateWidth,
            fallback: minimumAggregateWidth
        )
        let aggregateSize = CGSize(width: aggregateWidth, height: pinHeight)
        let singleSize = CGSize(width: pinHeight, height: pinHeight)
        let aggregateBounds = centerBounds(content: content, itemSize: aggregateSize)
        let singleBounds = centerBounds(content: content, itemSize: singleSize)
        let aggregateCenter = center(
            for: aggregatePosition.normalized(fallback: .standardAggregate),
            in: aggregateBounds
        )
        let singleCenter = center(
            for: singlePosition.normalized(fallback: .standardSingle),
            in: singleBounds
        )
        let aggregateFrame = CGRect(
            x: aggregateCenter.x - aggregateSize.width / 2,
            y: aggregateCenter.y - aggregateSize.height / 2,
            width: aggregateSize.width,
            height: aggregateSize.height
        )
        let singleFrame = CGRect(
            x: singleCenter.x - singleSize.width / 2,
            y: singleCenter.y - singleSize.height / 2,
            width: singleSize.width,
            height: singleSize.height
        )

        return GooeyPinDemoLayout(
            stageSize: sanitizedStageSize,
            effectPadding: padding,
            contentFrame: content,
            aggregateCenterBounds: aggregateBounds,
            singleCenterBounds: singleBounds,
            aggregateFrame: aggregateFrame,
            singleFrame: singleFrame,
            metrics: spatialMetrics(
                aggregateFrame: aggregateFrame,
                singleFrame: singleFrame,
                fallbackDirection: fallbackDirection
            )
        )
    }

    static func spatialMetrics(
        aggregateFrame: CGRect,
        singleFrame: CGRect,
        fallbackDirection: CGVector
    ) -> GooeyPinSpatialMetrics {
        let aggregateCenter = CGPoint(x: aggregateFrame.midX, y: aggregateFrame.midY)
        let singleCenter = CGPoint(x: singleFrame.midX, y: singleFrame.midY)
        let dx = singleCenter.x - aggregateCenter.x
        let dy = singleCenter.y - aggregateCenter.y
        let centerDistance = hypot(dx, dy)
        let hasDistinctCenters = centerDistance.isFinite && centerDistance > 0.0001
        let direction = hasDistinctCenters
            ? CGVector(dx: dx / centerDistance, dy: dy / centerDistance)
            : normalizedDirection(fallbackDirection)
        var angle = atan2(direction.dy, direction.dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        if angle >= 360 { angle.formTruncatingRemainder(dividingBy: 360) }

        let aggregateRadius = max(0, aggregateFrame.height / 2)
        let singleRadius = max(0, min(singleFrame.width, singleFrame.height) / 2)
        let segmentMinX = min(aggregateFrame.maxX - aggregateRadius, aggregateFrame.minX + aggregateRadius)
        let segmentMaxX = max(aggregateFrame.maxX - aggregateRadius, aggregateFrame.minX + aggregateRadius)
        let nearestX = min(segmentMaxX, max(segmentMinX, singleCenter.x))
        let distanceToCenterLine = hypot(singleCenter.x - nearestX, singleCenter.y - aggregateCenter.y)
        let rawGap = distanceToCenterLine - aggregateRadius - singleRadius
        let surfaceGap = rawGap.isFinite ? rawGap : 0

        return GooeyPinSpatialMetrics(
            surfaceGap: surfaceGap,
            angleDegrees: angle.isFinite ? angle : 0,
            direction: direction,
            hasDistinctCenters: hasDistinctCenters
        )
    }

    static func draggedPosition(
        start: GooeyPinNormalizedPoint,
        translation: CGSize,
        pin: GooeyPinID,
        layout: GooeyPinDemoLayout
    ) -> GooeyPinNormalizedPoint {
        let bounds = layout.centerBounds(for: pin)
        let startCenter = center(for: start.normalized(), in: bounds)
        let dx = translation.width.isFinite ? translation.width : 0
        let dy = translation.height.isFinite ? translation.height : 0
        return normalizedPosition(
            for: CGPoint(x: startCenter.x + dx, y: startCenter.y + dy),
            in: bounds
        )
    }

    static func draggedPosition(
        startCenter: CGPoint,
        translation: CGSize,
        pin: GooeyPinID,
        layout: GooeyPinDemoLayout
    ) -> GooeyPinNormalizedPoint {
        let bounds = layout.centerBounds(for: pin)
        let finiteStartX = startCenter.x.isFinite ? startCenter.x : bounds.midX
        let finiteStartY = startCenter.y.isFinite ? startCenter.y : bounds.midY
        let dx = translation.width.isFinite ? translation.width : 0
        let dy = translation.height.isFinite ? translation.height : 0
        return normalizedPosition(
            for: CGPoint(x: finiteStartX + dx, y: finiteStartY + dy),
            in: bounds
        )
    }

    static func assistedPosition(
        moving pin: GooeyPinID,
        to state: GooeyPinSnapState,
        layout: GooeyPinDemoLayout,
        separationDistance: CGFloat,
        fallbackDirection: CGVector
    ) -> GooeyPinNormalizedPoint {
        let direction = layout.metrics.hasDistinctCenters
            ? layout.metrics.direction
            : normalizedDirection(fallbackDirection)
        let desiredGap = state == .fused
            ? fusedSurfaceGap
            : (separationDistance.isFinite ? separationDistance : GooeyPinDemoParameters.standard.separationDistance)
        let radialDistance = distanceAlongRay(
            direction: direction,
            aggregateSize: layout.aggregateFrame.size,
            singleSize: layout.singleFrame.size,
            targetSurfaceGap: desiredGap
        )
        let proposedCenter: CGPoint
        switch pin {
        case .single:
            proposedCenter = CGPoint(
                x: layout.aggregateFrame.midX + direction.dx * radialDistance,
                y: layout.aggregateFrame.midY + direction.dy * radialDistance
            )
        case .aggregate:
            proposedCenter = CGPoint(
                x: layout.singleFrame.midX - direction.dx * radialDistance,
                y: layout.singleFrame.midY - direction.dy * radialDistance
            )
        }
        return normalizedPosition(for: proposedCenter, in: layout.centerBounds(for: pin))
    }

    static func center(
        for position: GooeyPinNormalizedPoint,
        in bounds: CGRect
    ) -> CGPoint {
        let value = position.normalized()
        return CGPoint(
            x: bounds.minX + bounds.width * value.x,
            y: bounds.minY + bounds.height * value.y
        )
    }

    static func normalizedPosition(for point: CGPoint, in bounds: CGRect) -> GooeyPinNormalizedPoint {
        let finiteX = point.x.isFinite ? point.x : bounds.midX
        let finiteY = point.y.isFinite ? point.y : bounds.midY
        let x = bounds.width > 0 ? (finiteX - bounds.minX) / bounds.width : 0.5
        let y = bounds.height > 0 ? (finiteY - bounds.minY) / bounds.height : 0.5
        return GooeyPinNormalizedPoint(x: x, y: y).normalized()
    }

    private static func centerBounds(content: CGRect, itemSize: CGSize) -> CGRect {
        let minimumX = content.minX + itemSize.width / 2
        let maximumX = content.maxX - itemSize.width / 2
        let minimumY = content.minY + itemSize.height / 2
        let maximumY = content.maxY - itemSize.height / 2
        return CGRect(
            x: min(minimumX, maximumX),
            y: min(minimumY, maximumY),
            width: max(0, maximumX - minimumX),
            height: max(0, maximumY - minimumY)
        )
    }

    private static func distanceAlongRay(
        direction: CGVector,
        aggregateSize: CGSize,
        singleSize: CGSize,
        targetSurfaceGap: CGFloat
    ) -> CGFloat {
        let normalized = normalizedDirection(direction)
        let target = targetSurfaceGap.isFinite ? targetSurfaceGap : 0
        let aggregateFrame = CGRect(
            x: -aggregateSize.width / 2,
            y: -aggregateSize.height / 2,
            width: aggregateSize.width,
            height: aggregateSize.height
        )
        var lower: CGFloat = 0
        var upper = max(512, aggregateSize.width + singleSize.width + abs(target) + 64)
        for _ in 0..<48 {
            let midpoint = (lower + upper) / 2
            let singleFrame = CGRect(
                x: normalized.dx * midpoint - singleSize.width / 2,
                y: normalized.dy * midpoint - singleSize.height / 2,
                width: singleSize.width,
                height: singleSize.height
            )
            let gap = spatialMetrics(
                aggregateFrame: aggregateFrame,
                singleFrame: singleFrame,
                fallbackDirection: normalized
            ).surfaceGap
            if gap < target {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return (lower + upper) / 2
    }

    private static func normalizedDirection(_ vector: CGVector) -> CGVector {
        let dx = vector.dx.isFinite ? vector.dx : 1
        let dy = vector.dy.isFinite ? vector.dy : 0
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0.0001 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    private static func finitePositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func finiteClamp(
        _ value: CGFloat,
        _ range: ClosedRange<CGFloat>,
        fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return min(range.upperBound, max(range.lowerBound, fallback)) }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

private extension GooeyPinNormalizedPoint {
    static let standardAggregate = GooeyPinDemoState.standard.aggregatePosition
    static let standardSingle = GooeyPinDemoState.standard.singlePosition
}

enum GooeyPinInteraction {
    static func dragging(
        state: GooeyPinDemoState,
        pin: GooeyPinID,
        startPosition: GooeyPinNormalizedPoint,
        translation: CGSize,
        layout: GooeyPinDemoLayout
    ) -> GooeyPinDemoState {
        var value = state
        value.setPosition(
            GooeyPinDemoGeometry.draggedPosition(
                start: startPosition,
                translation: translation,
                pin: pin,
                layout: layout
            ),
            for: pin
        )
        value.lastActivePin = pin
        return value
    }

    static func endingDrag(state: GooeyPinDemoState) -> GooeyPinDemoState {
        state
    }
}

struct GooeyPinDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var demoState = GooeyPinDemoState.standard
    @State private var aggregateDragStartCenter: CGPoint?
    @State private var singleDragStartCenter: CGPoint?
    @State private var activeDragPin: GooeyPinID?
    @State private var numberOrderLockedForDrag: Bool?
    @State private var stageMetrics = GooeyPinStageMetrics.standard
    @State private var previousStagePlacement: GooeyPinStagePlacement?

    private var numberScenario: GooeyPinNumberScenario {
        demoState.numberScenario
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    stage
                    layoutPanel
                    appearancePanel
                    behaviorPanel
                    resetButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pin Gooey Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityLabel("关闭 Pin Gooey Demo")
                }
            }
        }
        .onChange(of: demoState.parameters.mergeThreshold) { _, _ in
            resolveSnapState(using: stageMetrics.surfaceGap)
        }
        .onChange(of: demoState.parameters.splitThreshold) { _, _ in
            resolveSnapState(using: stageMetrics.surfaceGap)
        }
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    demoState.snapState == .fused ? "融合" : "分离",
                    systemImage: demoState.snapState == .fused ? "drop.fill" : "circle.dotted"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(
                    "表面间距 \(Int(stageMetrics.surfaceGap.rounded())) pt · 角度 \(Int(stageMetrics.angleDegrees.rounded()) % 360)°"
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(
                "融合 \(numberScenario.fusedText) · 分离 \(numberScenario.separatedAggregateText) + \(numberScenario.extractedMember.value)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            GooeyPinStage(
                aggregatePosition: demoState.aggregatePosition,
                singlePosition: demoState.singlePosition,
                fallbackDirection: demoState.lastDirection,
                parameters: demoState.parameters.normalized(),
                numberScenario: numberScenario,
                activeDragPin: activeDragPin,
                onDragChanged: dragChanged,
                onDragEnded: dragEnded,
                onAccessibilityAction: accessibilityAction
            )
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .background(Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onPreferenceChange(GooeyPinStageMetricsPreferenceKey.self) { metrics in
                let reconciliation = GooeyPinBoundsReconciler.reconcile(
                    previous: previousStagePlacement,
                    current: metrics.placement
                )
                previousStagePlacement = reconciliation.rememberedPlacement
                if activeDragPin != .aggregate,
                   let aggregatePosition = reconciliation.aggregatePosition {
                    demoState.aggregatePosition = aggregatePosition
                }
                if activeDragPin != .single,
                   let singlePosition = reconciliation.singlePosition {
                    demoState.singlePosition = singlePosition
                }
                stageMetrics = metrics
                resolveSnapState(using: metrics.surfaceGap)
                if metrics.hasDistinctCenters {
                    demoState.lastDirection = metrics.direction
                }
            }
        }
    }

    private var layoutPanel: some View {
        parameterGroup("布局") {
            Picker(
                "数字分离示例",
                selection: Binding(
                    get: { demoState.numberScenarioID },
                    set: { newValue in selectNumberScenario(newValue) }
                )
            ) {
                ForEach(GooeyPinNumberScenarioID.allCases, id: \.self) { scenarioID in
                    Text(scenarioID.title).tag(scenarioID)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("数字分离示例")
            Text("数字先按成员相对位置稳定排序；分离成员沿自身方位移动，其他数字连续补位。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("聚合 Pin 宽度按首页文字测量规则自动适配", systemImage: "textformat.size")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appearancePanel: some View {
        parameterGroup("Gooey 外观") {
            parameterSlider("模糊半径", value: $demoState.parameters.blurRadius, range: 0...24, unit: "pt")
            parameterSlider("Alpha 阈值", value: $demoState.parameters.alphaThreshold, range: 0.05...0.95, digits: 2)
            parameterSlider("源不透明度", value: $demoState.parameters.sourceOpacity, range: 0.2...1, digits: 2)
            parameterSlider("橙色描边", value: $demoState.parameters.strokeWidth, range: 0...6, unit: "pt", digits: 1)
            parameterSlider("阴影", value: $demoState.parameters.shadowRadius, range: 0...24, unit: "pt")
        }
    }

    private var behaviorPanel: some View {
        parameterGroup("辅助动作与滞回") {
            parameterSlider("辅助分离距离", value: $demoState.parameters.separationDistance, range: 40...120, unit: "pt")
            parameterSlider(
                "融合阈值",
                value: Binding(
                    get: { demoState.parameters.mergeThreshold },
                    set: { newValue in
                        demoState.parameters.mergeThreshold = min(
                            newValue,
                            demoState.parameters.splitThreshold - 4
                        )
                    }
                ),
                range: 0...40,
                unit: "pt"
            )
            parameterSlider(
                "分离阈值",
                value: Binding(
                    get: { demoState.parameters.splitThreshold },
                    set: { newValue in
                        demoState.parameters.splitThreshold = max(
                            newValue,
                            demoState.parameters.mergeThreshold + 4
                        )
                    }
                ),
                range: 4...60,
                unit: "pt"
            )
            parameterSlider("弹簧响应", value: $demoState.parameters.springResponse, range: 0.1...1, unit: "s", digits: 2)
            parameterSlider("弹簧阻尼", value: $demoState.parameters.springDamping, range: 0.2...1, digits: 2)
        }
    }

    private var resetButton: some View {
        Button {
            clearDragStarts()
            previousStagePlacement = nil
            animateAssistance {
                demoState.reset()
            }
        } label: {
            Label("恢复默认", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("恢复全部 Gooey 参数、数字示例和 Pin 位置默认值")
    }

    private func selectNumberScenario(_ id: GooeyPinNumberScenarioID) {
        guard id != demoState.numberScenarioID else { return }
        clearDragStarts()
        previousStagePlacement = nil
        animateAssistance {
            demoState.applyNumberScenario(id)
        }
    }

    private func dragChanged(
        _ pin: GooeyPinID,
        translation: CGSize,
        layout: GooeyPinDemoLayout
    ) {
        if activeDragPin == nil {
            activeDragPin = pin
        }
        guard activeDragPin == pin else { return }
        if numberOrderLockedForDrag == nil {
            numberOrderLockedForDrag = demoState.snapState == .fused
        }
        let startCenter: CGPoint
        switch pin {
        case .aggregate:
            if aggregateDragStartCenter == nil {
                aggregateDragStartCenter = CGPoint(
                    x: layout.aggregateFrame.midX,
                    y: layout.aggregateFrame.midY
                )
            }
            startCenter = aggregateDragStartCenter ?? CGPoint(
                x: layout.aggregateFrame.midX,
                y: layout.aggregateFrame.midY
            )
        case .single:
            if singleDragStartCenter == nil {
                singleDragStartCenter = CGPoint(
                    x: layout.singleFrame.midX,
                    y: layout.singleFrame.midY
                )
            }
            startCenter = singleDragStartCenter ?? CGPoint(
                x: layout.singleFrame.midX,
                y: layout.singleFrame.midY
            )
        }

        var targetState = demoState
        var targetLayout = layout
        for _ in 0..<4 {
            targetState.setPosition(
                GooeyPinDemoGeometry.draggedPosition(
                    startCenter: startCenter,
                    translation: translation,
                    pin: pin,
                    layout: targetLayout
                ),
                for: pin
            )
            targetLayout = adaptiveLayout(for: targetState, stageSize: layout.stageSize)
        }
        targetState.lastActivePin = pin

        if let numberOrderLockedForDrag {
            self.numberOrderLockedForDrag = GooeyPinNumberOrderLock.updated(
                currentlyLocked: numberOrderLockedForDrag,
                surfaceGap: targetLayout.metrics.surfaceGap,
                splitThreshold: targetState.parameters.splitThreshold
            )
        }
        if self.numberOrderLockedForDrag == false,
           targetLayout.metrics.hasDistinctCenters {
            targetState.lastDirection = targetLayout.metrics.direction
            targetState.updateNumberOrderForMerge(direction: targetLayout.metrics.direction)
        }
        demoState = targetState
    }

    private func dragEnded(
        _ pin: GooeyPinID,
        translation: CGSize,
        layout: GooeyPinDemoLayout
    ) {
        dragChanged(pin, translation: translation, layout: layout)
        demoState = GooeyPinInteraction.endingDrag(state: demoState)
        switch pin {
        case .aggregate: aggregateDragStartCenter = nil
        case .single: singleDragStartCenter = nil
        }
        activeDragPin = nil
        numberOrderLockedForDrag = nil
    }

    private func accessibilityAction(
        _ pin: GooeyPinID,
        action: GooeyPinAccessibilityAction,
        layout: GooeyPinDemoLayout
    ) {
        clearDragStarts()
        var targetState = demoState
        targetState.lastActivePin = pin
        if layout.metrics.hasDistinctCenters {
            targetState.lastDirection = layout.metrics.direction
        }
        switch action {
        case .move(let translation):
            targetState.setPosition(
                GooeyPinDemoGeometry.draggedPosition(
                    start: targetState.position(for: pin),
                    translation: translation,
                    pin: pin,
                    layout: layout
                ),
                for: pin
            )
            if targetState.snapState == .separated {
                let targetLayout = adaptiveLayout(for: targetState, stageSize: layout.stageSize)
                if targetLayout.metrics.hasDistinctCenters {
                    targetState.lastDirection = targetLayout.metrics.direction
                    targetState.updateNumberOrderForMerge(direction: targetLayout.metrics.direction)
                }
            }
        case .snap(let snapState):
            if snapState == .fused,
               targetState.snapState == .separated,
               layout.metrics.hasDistinctCenters {
                targetState.updateNumberOrderForMerge(direction: layout.metrics.direction)
            }
            targetState.setPosition(
                GooeyPinDemoGeometry.assistedPosition(
                    moving: pin,
                    to: snapState,
                    layout: layout,
                    separationDistance: targetState.parameters.separationDistance,
                    fallbackDirection: targetState.lastDirection
                ),
                for: pin
            )
            targetState.snapState = snapState
        }
        animateAssistance {
            demoState = targetState
        }
    }

    private func animateAssistance(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(
                .spring(
                    response: demoState.parameters.springResponse,
                    dampingFraction: demoState.parameters.springDamping,
                    blendDuration: 0
                ),
                changes
            )
        }
    }

    private func clearDragStarts() {
        aggregateDragStartCenter = nil
        singleDragStartCenter = nil
        activeDragPin = nil
        numberOrderLockedForDrag = nil
    }

    private func adaptiveLayout(
        for state: GooeyPinDemoState,
        stageSize: CGSize
    ) -> GooeyPinDemoLayout {
        GooeyPinAdaptiveLayout.layout(
            stageSize: stageSize,
            aggregatePosition: state.aggregatePosition,
            singlePosition: state.singlePosition,
            scenario: state.numberScenario,
            parameters: state.parameters,
            effectPadding: GooeyPinEffectGeometry.safePadding(for: state.parameters),
            fallbackDirection: state.lastDirection
        )
    }

    private func resolveSnapState(using surfaceGap: CGFloat) {
        demoState.snapState = GooeyPinSnapResolver.resolvedState(
            surfaceGap: surfaceGap,
            previous: demoState.snapState,
            mergeThreshold: demoState.parameters.mergeThreshold,
            splitThreshold: demoState.parameters.splitThreshold
        )
    }

    private func parameterGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func parameterSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        unit: String = "",
        digits: Int = 0
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(Double(value.wrappedValue).formatted(.number.precision(.fractionLength(digits))) + unit)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(Double(value.wrappedValue).formatted(.number.precision(.fractionLength(digits))) + unit)
        }
    }
}

private struct GooeyPinStageMetrics: Equatable {
    static let standard = Self(
        surfaceGap: GooeyPinDemoParameters.standard.separationDistance,
        angleDegrees: 0,
        direction: CGVector(dx: 1, dy: 0),
        hasDistinctCenters: true,
        placement: GooeyPinStagePlacement(
            aggregate: GooeyPinPhysicalPlacement(center: .zero, centerBounds: .zero),
            single: GooeyPinPhysicalPlacement(center: .zero, centerBounds: .zero)
        )
    )

    let surfaceGap: CGFloat
    let angleDegrees: CGFloat
    let direction: CGVector
    let hasDistinctCenters: Bool
    let placement: GooeyPinStagePlacement
}

private struct GooeyPinStageMetricsPreferenceKey: PreferenceKey {
    static let defaultValue = GooeyPinStageMetrics.standard

    static func reduce(
        value: inout GooeyPinStageMetrics,
        nextValue: () -> GooeyPinStageMetrics
    ) {
        value = nextValue()
    }
}

private enum GooeyPinAccessibilityAction {
    case move(CGSize)
    case snap(GooeyPinSnapState)
}

private struct GooeyPinStage: View {
    let aggregatePosition: GooeyPinNormalizedPoint
    let singlePosition: GooeyPinNormalizedPoint
    let fallbackDirection: CGVector
    let parameters: GooeyPinDemoParameters
    let numberScenario: GooeyPinNumberScenario
    let activeDragPin: GooeyPinID?
    let onDragChanged: (GooeyPinID, CGSize, GooeyPinDemoLayout) -> Void
    let onDragEnded: (GooeyPinID, CGSize, GooeyPinDemoLayout) -> Void
    let onAccessibilityAction: (GooeyPinID, GooeyPinAccessibilityAction, GooeyPinDemoLayout) -> Void

    var body: some View {
        GeometryReader { proxy in
            let padding = GooeyPinEffectGeometry.safePadding(for: parameters)
            let layout = GooeyPinAdaptiveLayout.layout(
                stageSize: proxy.size,
                aggregatePosition: aggregatePosition,
                singlePosition: singlePosition,
                scenario: numberScenario,
                parameters: parameters,
                effectPadding: padding,
                fallbackDirection: fallbackDirection
            )

            ZStack(alignment: .topLeading) {
                GooeyBlobLayer(
                    layout: layout,
                    inset: 0,
                    color: Color(red: 1, green: 110 / 255, blue: 0),
                    blurRadius: parameters.blurRadius,
                    alphaThreshold: parameters.alphaThreshold,
                    sourceOpacity: parameters.sourceOpacity
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                GooeyBlobLayer(
                    layout: layout,
                    inset: parameters.strokeWidth,
                    color: .white,
                    blurRadius: parameters.blurRadius,
                    alphaThreshold: parameters.alphaThreshold,
                    sourceOpacity: parameters.sourceOpacity
                )
                .frame(width: proxy.size.width, height: proxy.size.height)

                GooeyPinNumberLayer(
                    scenario: numberScenario,
                    layout: layout,
                    parameters: parameters
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)

                pinTargets(layout: layout)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .shadow(
                color: .black.opacity(0.42),
                radius: parameters.shadowRadius,
                y: GooeyPinEffectGeometry.shadowOffset(for: parameters.shadowRadius)
            )
            .preference(
                key: GooeyPinStageMetricsPreferenceKey.self,
                value: GooeyPinStageMetrics(
                    surfaceGap: layout.metrics.surfaceGap,
                    angleDegrees: layout.metrics.angleDegrees,
                    direction: layout.metrics.direction,
                    hasDistinctCenters: layout.metrics.hasDistinctCenters,
                    placement: layout.placement
                )
            )
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func pinTargets(layout: GooeyPinDemoLayout) -> some View {
        let hitGeometry = GooeyPinHitGeometry(layout: layout)

        Color.clear
            .frame(
                width: hitGeometry.aggregateTargetFrame.width,
                height: hitGeometry.aggregateTargetFrame.height
            )
            .contentShape(Capsule())
            .position(
                x: hitGeometry.aggregateTargetFrame.midX,
                y: hitGeometry.aggregateTargetFrame.midY
            )
            .gesture(dragGesture(for: .aggregate, layout: layout))
            .allowsHitTesting(activeDragPin != .single)
            .zIndex(activeDragPin == .aggregate ? 4 : 1)
            .accessibilityElement()
            .accessibilityLabel("聚合 Pin")
            .accessibilityValue(accessibilityValue(for: .aggregate, layout: layout))
            .accessibilityHint("可二维拖动，或使用动作移动、融合和分离")
            .modifier(PinAccessibilityActions(pin: .aggregate, layout: layout, handler: onAccessibilityAction))

        Color.clear
            .frame(width: hitGeometry.singleTargetFrame.width, height: hitGeometry.singleTargetFrame.height)
            .contentShape(Circle())
            .position(x: hitGeometry.singleTargetFrame.midX, y: hitGeometry.singleTargetFrame.midY)
            .gesture(dragGesture(for: .single, layout: layout))
            .allowsHitTesting(activeDragPin != .aggregate)
            .zIndex(activeDragPin == .single ? 4 : 1.25)
            .accessibilityElement()
            .accessibilityLabel("单体 Pin")
            .accessibilityValue(accessibilityValue(for: .single, layout: layout))
            .accessibilityHint("可二维拖动，或使用动作移动、融合和分离")
            .modifier(PinAccessibilityActions(pin: .single, layout: layout, handler: onAccessibilityAction))

        ForEach(hitGeometry.aggregateEndHandleFrames.indices, id: \.self) { index in
            let frame = hitGeometry.aggregateEndHandleFrames[index]
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(dragGesture(for: .aggregate, layout: layout))
                .allowsHitTesting(activeDragPin != .single)
                .zIndex(activeDragPin == .aggregate ? 4.5 : 1.5)
                .accessibilityHidden(true)
        }

        Color.clear
            .frame(
                width: hitGeometry.singlePriorityFrame.width,
                height: hitGeometry.singlePriorityFrame.height
            )
            .contentShape(Circle())
            .position(
                x: hitGeometry.singlePriorityFrame.midX,
                y: hitGeometry.singlePriorityFrame.midY
            )
            .gesture(dragGesture(for: .single, layout: layout))
            .allowsHitTesting(activeDragPin != .aggregate)
            .zIndex(activeDragPin == .single ? 5 : 2)
            .accessibilityHidden(true)
    }

    private func dragGesture(for pin: GooeyPinID, layout: GooeyPinDemoLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { onDragChanged(pin, $0.translation, layout) }
            .onEnded { onDragEnded(pin, $0.translation, layout) }
    }

    private func accessibilityValue(for pin: GooeyPinID, layout: GooeyPinDemoLayout) -> String {
        let frame = pin == .aggregate ? layout.aggregateFrame : layout.singleFrame
        let progress = GooeyPinNumberLayout.visualExtractionProgress(
            surfaceGap: layout.metrics.surfaceGap,
            parameters: parameters
        )
        let numberText: String
        switch pin {
        case .aggregate:
            numberText = progress < 0.5
                ? numberScenario.fusedText
                : numberScenario.separatedAggregateText
        case .single:
            numberText = numberScenario.extractedMember.value
        }
        return "数字 \(numberText)，横坐标 \(Int(frame.midX.rounded()))，纵坐标 \(Int(frame.midY.rounded()))"
    }
}

private struct PinAccessibilityActions: ViewModifier {
    let pin: GooeyPinID
    let layout: GooeyPinDemoLayout
    let handler: (GooeyPinID, GooeyPinAccessibilityAction, GooeyPinDemoLayout) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("向上移动")) {
                handler(pin, .move(CGSize(width: 0, height: -12)), layout)
            }
            .accessibilityAction(named: Text("向下移动")) {
                handler(pin, .move(CGSize(width: 0, height: 12)), layout)
            }
            .accessibilityAction(named: Text("向左移动")) {
                handler(pin, .move(CGSize(width: -12, height: 0)), layout)
            }
            .accessibilityAction(named: Text("向右移动")) {
                handler(pin, .move(CGSize(width: 12, height: 0)), layout)
            }
            .accessibilityAction(named: Text("融合")) {
                handler(pin, .snap(.fused), layout)
            }
            .accessibilityAction(named: Text("分离")) {
                handler(pin, .snap(.separated), layout)
            }
    }
}

private struct GooeyBlobLayer: View {
    let layout: GooeyPinDemoLayout
    let inset: CGFloat
    let color: Color
    let blurRadius: CGFloat
    let alphaThreshold: CGFloat
    let sourceOpacity: CGFloat

    var body: some View {
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: alphaThreshold, color: color))
            context.addFilter(.blur(radius: blurRadius))
            context.drawLayer { layer in
                layer.opacity = sourceOpacity
                let aggregate = layout.aggregateFrame.insetBy(dx: inset, dy: inset)
                let single = layout.singleFrame.insetBy(dx: inset, dy: inset)
                if aggregate.width > 0, aggregate.height > 0 {
                    layer.fill(
                        Path(roundedRect: aggregate, cornerRadius: aggregate.height / 2),
                        with: .color(.white)
                    )
                }
                if single.width > 0, single.height > 0 {
                    layer.fill(Path(ellipseIn: single), with: .color(.white))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GooeyPinNumberLayer: View {
    let scenario: GooeyPinNumberScenario
    let layout: GooeyPinDemoLayout
    let parameters: GooeyPinDemoParameters

    var body: some View {
        let progress = GooeyPinNumberLayout.visualExtractionProgress(
            surfaceGap: layout.metrics.surfaceGap,
            parameters: parameters
        )
        let presentation = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: progress
        )

        ZStack(alignment: .topLeading) {
            ForEach(presentation.separatorPlacements) { separator in
                Text(".")
                    .font(.system(size: presentation.fontSize, weight: .medium))
                    .foregroundStyle(.black)
                    .opacity(separator.opacity)
                    .position(separator.position)
            }
            ForEach(presentation.memberPlacements) { member in
                Text(member.value)
                    .font(.system(size: presentation.fontSize, weight: .medium))
                    .foregroundStyle(.black)
                    .position(member.position)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
