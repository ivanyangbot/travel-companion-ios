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
    case generated

    var title: String {
        switch self {
        case .rightEdge: "4 · 右侧"
        case .upperLeft: "3 · 左上"
        case .generated: "随机"
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
        case .generated: .rightEdge
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

struct GooeyPinSupplementalPin: Identifiable, Equatable {
    let id: String
    let text: String
    var position: GooeyPinNormalizedPoint
}

struct GooeyPinRandomLayout: Equatable {
    let numberScenario: GooeyPinNumberScenario
    let supplementalPins: [GooeyPinSupplementalPin]

    var visiblePinCount: Int { 2 + supplementalPins.count }
}

enum GooeyPinRandomLayoutGenerator {
    static let pinCountRange = 2...12

    static func make(pinCount requestedCount: Int) -> GooeyPinRandomLayout {
        var generator = SystemRandomNumberGenerator()
        return make(pinCount: requestedCount, using: &generator)
    }

    static func make<Generator: RandomNumberGenerator>(
        pinCount requestedCount: Int,
        using generator: inout Generator
    ) -> GooeyPinRandomLayout {
        let pinCount = min(
            pinCountRange.upperBound,
            max(pinCountRange.lowerBound, requestedCount)
        )
        let template: GooeyPinNumberScenario = Bool.random(using: &generator)
            ? .rightEdge
            : .upperLeft
        let angle = CGFloat.random(in: 0..<(2 * .pi), using: &generator)
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let aggregatePosition = GooeyPinNormalizedPoint(
            x: CGFloat.random(in: 0.32...0.68, using: &generator),
            y: CGFloat.random(in: 0.32...0.68, using: &generator)
        )
        let separation = CGFloat.random(in: 0.34...0.48, using: &generator)
        let singlePosition = GooeyPinNormalizedPoint(
            x: min(0.92, max(0.08, aggregatePosition.x + direction.dx * separation)),
            y: min(0.92, max(0.08, aggregatePosition.y + direction.dy * separation))
        )
        let numberScenario = GooeyPinNumberScenario(
            id: .generated,
            members: template.members,
            extractedMemberID: template.extractedMemberID,
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition
        )
        let supplementalPins = (0..<max(0, pinCount - 2)).map { index in
            GooeyPinSupplementalPin(
                id: "generated-pin-\(index)",
                text: randomPinText(using: &generator),
                position: GooeyPinNormalizedPoint(
                    x: CGFloat.random(in: 0.08...0.92, using: &generator),
                    y: CGFloat.random(in: 0.08...0.92, using: &generator)
                )
            )
        }
        return GooeyPinRandomLayout(
            numberScenario: numberScenario,
            supplementalPins: supplementalPins
        )
    }

    private static func randomPinText<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> String {
        let memberCount = Int.random(in: 1...4, using: &generator)
        return (0..<memberCount)
            .map { _ in String(Int.random(in: 1...12, using: &generator)) }
            .joined(separator: ".")
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

struct GooeyPinVisualNumberNode: Identifiable, Equatable {
    static let primaryAggregateID = "primary-aggregate"
    static let primarySingleID = "primary-single"

    let id: String
    let members: [GooeyPinNumberMember]
    let frame: CGRect
}

struct GooeyPinNumberMergePair: Equatable {
    let firstNodeID: String
    let secondNodeID: String
    let surfaceGap: CGFloat
    let mergeProgress: CGFloat
}

enum GooeyPinMultiNumberLayout {
    private static let labelFont = UIFont.systemFont(ofSize: 16, weight: .medium)

    static func presentation(
        nodes: [GooeyPinVisualNumberNode],
        primaryScenario: GooeyPinNumberScenario,
        parameters: GooeyPinDemoParameters,
        movingNodeID: String?
    ) -> GooeyPinNumberPresentation {
        let pair = activePair(
            nodes: nodes,
            parameters: parameters,
            movingNodeID: movingNodeID
        )
        var positions: [String: CGPoint] = [:]
        var membersByID: [String: GooeyPinNumberMember] = [:]
        var separators: [String: GooeyPinNumberSeparatorPlacement] = [:]

        for node in nodes {
            let nodeSlots = slots(for: node.members, centeredAt: center(of: node.frame))
            positions.merge(nodeSlots) { _, new in new }
            for member in node.members { membersByID[member.id] = member }
            for (id, point) in separatorPositions(for: node.members, slots: nodeSlots) {
                separators[id] = GooeyPinNumberSeparatorPlacement(
                    id: id,
                    position: point,
                    opacity: 1
                )
            }
        }

        guard let pair,
              let first = nodes.first(where: { $0.id == pair.firstNodeID }),
              let second = nodes.first(where: { $0.id == pair.secondNodeID }) else {
            return presentation(
                positions: positions,
                membersByID: membersByID,
                separators: separators,
                progress: 0
            )
        }

        let mergedMembers = mergedOrder(
            first: first,
            second: second,
            primaryScenario: primaryScenario
        )
        let host = mergeHost(first: first, second: second, movingNodeID: movingNodeID)
        let mergedSlots = slots(for: mergedMembers, centeredAt: center(of: host.frame))
        for member in mergedMembers {
            guard let start = positions[member.id], let target = mergedSlots[member.id] else { continue }
            positions[member.id] = interpolate(
                from: start,
                to: target,
                progress: pair.mergeProgress
            )
        }

        let pairMemberIDs = Set(first.members.map(\.id) + second.members.map(\.id))
        separators = separators.filter { separator in
            let memberIDs = separator.key.components(separatedBy: "→")
            return !memberIDs.allSatisfy(pairMemberIDs.contains)
        }
        let firstSlots = slots(for: first.members, centeredAt: center(of: first.frame))
        let secondSlots = slots(for: second.members, centeredAt: center(of: second.frame))
        let initialSeparators = separatorPositions(for: first.members, slots: firstSlots)
            .merging(separatorPositions(for: second.members, slots: secondSlots)) { _, new in new }
        let mergedSeparators = separatorPositions(for: mergedMembers, slots: mergedSlots)
        for id in Set(initialSeparators.keys).union(mergedSeparators.keys) {
            switch (initialSeparators[id], mergedSeparators[id]) {
            case let (.some(start), .some(target)):
                separators[id] = GooeyPinNumberSeparatorPlacement(
                    id: id,
                    position: interpolate(from: start, to: target, progress: pair.mergeProgress),
                    opacity: 1
                )
            case let (.some(start), .none):
                separators[id] = GooeyPinNumberSeparatorPlacement(
                    id: id,
                    position: start,
                    opacity: 1 - pair.mergeProgress
                )
            case let (.none, .some(target)):
                separators[id] = GooeyPinNumberSeparatorPlacement(
                    id: id,
                    position: target,
                    opacity: pair.mergeProgress
                )
            case (.none, .none):
                break
            }
        }

        return presentation(
            positions: positions,
            membersByID: membersByID,
            separators: separators,
            progress: pair.mergeProgress
        )
    }

    static func activePair(
        nodes: [GooeyPinVisualNumberNode],
        parameters: GooeyPinDemoParameters,
        movingNodeID: String? = nil
    ) -> GooeyPinNumberMergePair? {
        guard nodes.count >= 2 else { return nil }
        var candidates: [GooeyPinNumberMergePair] = []
        for firstIndex in nodes.indices {
            for secondIndex in nodes.indices where secondIndex > firstIndex {
                let first = nodes[firstIndex]
                let second = nodes[secondIndex]
                let gap = capsuleSurfaceGap(first.frame, second.frame)
                let mergeProgress = 1 - GooeyPinNumberLayout.visualExtractionProgress(
                    surfaceGap: gap,
                    parameters: parameters
                )
                guard mergeProgress > 0.0001 else { continue }
                candidates.append(
                    GooeyPinNumberMergePair(
                        firstNodeID: first.id,
                        secondNodeID: second.id,
                        surfaceGap: gap,
                        mergeProgress: mergeProgress
                    )
                )
            }
        }
        let eligibleCandidates: [GooeyPinNumberMergePair]
        if let movingNodeID {
            let movingCandidates = candidates.filter {
                $0.firstNodeID == movingNodeID || $0.secondNodeID == movingNodeID
            }
            eligibleCandidates = movingCandidates.isEmpty ? candidates : movingCandidates
        } else {
            eligibleCandidates = candidates
        }
        return eligibleCandidates.max {
            if abs($0.mergeProgress - $1.mergeProgress) > 0.0001 {
                return $0.mergeProgress < $1.mergeProgress
            }
            return $0.surfaceGap > $1.surfaceGap
        }
    }

    static func capsuleSurfaceGap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let firstRadius = max(0, min(first.width, first.height) / 2)
        let secondRadius = max(0, min(second.width, second.height) / 2)
        let firstRange = (first.minX + firstRadius)...(first.maxX - firstRadius)
        let secondRange = (second.minX + secondRadius)...(second.maxX - secondRadius)
        let horizontalGap: CGFloat
        if firstRange.upperBound < secondRange.lowerBound {
            horizontalGap = secondRange.lowerBound - firstRange.upperBound
        } else if secondRange.upperBound < firstRange.lowerBound {
            horizontalGap = firstRange.lowerBound - secondRange.upperBound
        } else {
            horizontalGap = 0
        }
        return hypot(horizontalGap, abs(first.midY - second.midY)) - firstRadius - secondRadius
    }

    private static func mergedOrder(
        first: GooeyPinVisualNumberNode,
        second: GooeyPinVisualNumberNode,
        primaryScenario: GooeyPinNumberScenario
    ) -> [GooeyPinNumberMember] {
        let pairIDs = Set([first.id, second.id])
        if pairIDs == Set([
            GooeyPinVisualNumberNode.primaryAggregateID,
            GooeyPinVisualNumberNode.primarySingleID
        ]) {
            return primaryScenario.orderedMembers
        }

        if first.members.count == 1, second.members.count > 1 {
            return inserting(single: first, into: second)
        }
        if second.members.count == 1, first.members.count > 1 {
            return inserting(single: second, into: first)
        }
        let orderedNodes = [first, second].sorted { lhs, rhs in
            if abs(lhs.frame.midX - rhs.frame.midX) > 0.001 {
                return lhs.frame.midX < rhs.frame.midX
            }
            return lhs.frame.midY < rhs.frame.midY
        }
        return orderedNodes.flatMap(\.members)
    }

    private static func inserting(
        single: GooeyPinVisualNumberNode,
        into aggregate: GooeyPinVisualNumberNode
    ) -> [GooeyPinNumberMember] {
        let dx = single.frame.midX - aggregate.frame.midX
        let dy = single.frame.midY - aggregate.frame.midY
        let length = hypot(dx, dy)
        let normalizedX = length > 0.0001 ? dx / length : 1
        let horizontalProgress = min(1, max(0, (normalizedX + 1) / 2))
        let insertionIndex = min(
            aggregate.members.count,
            max(0, Int((horizontalProgress * CGFloat(aggregate.members.count)).rounded()))
        )
        var result = aggregate.members
        result.insert(single.members[0], at: insertionIndex)
        return result
    }

    private static func mergeHost(
        first: GooeyPinVisualNumberNode,
        second: GooeyPinVisualNumberNode,
        movingNodeID: String?
    ) -> GooeyPinVisualNumberNode {
        if movingNodeID == first.id { return second }
        if movingNodeID == second.id { return first }
        if first.members.count == 1, second.members.count > 1 { return second }
        if second.members.count == 1, first.members.count > 1 { return first }
        return first.frame.width >= second.frame.width ? first : second
    }

    private static func presentation(
        positions: [String: CGPoint],
        membersByID: [String: GooeyPinNumberMember],
        separators: [String: GooeyPinNumberSeparatorPlacement],
        progress: CGFloat
    ) -> GooeyPinNumberPresentation {
        GooeyPinNumberPresentation(
            extractionProgress: 1 - progress,
            memberPlacements: positions.keys.sorted().compactMap { id in
                guard let member = membersByID[id], let position = positions[id] else { return nil }
                return GooeyPinNumberPlacement(id: id, value: member.value, position: position)
            },
            separatorPlacements: separators.values.sorted { $0.id < $1.id },
            fontSize: labelFont.pointSize
        )
    }

    private static func slots(
        for members: [GooeyPinNumberMember],
        centeredAt center: CGPoint
    ) -> [String: CGPoint] {
        guard !members.isEmpty else { return [:] }
        let widths = members.map { measuredWidth(of: $0.value) }
        let separatorWidth = measuredWidth(of: ".")
        let totalWidth = widths.reduce(0, +)
            + separatorWidth * CGFloat(max(0, members.count - 1))
        var cursor = center.x - totalWidth / 2
        var result: [String: CGPoint] = [:]
        for (index, member) in members.enumerated() {
            result[member.id] = CGPoint(x: cursor + widths[index] / 2, y: center.y)
            cursor += widths[index]
            if index < members.count - 1 { cursor += separatorWidth }
        }
        return result
    }

    private static func separatorPositions(
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

    private static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
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

struct GooeyPinSupplementalLayout: Equatable {
    let frame: CGRect
    let centerBounds: CGRect
}

enum GooeyPinSupplementalGeometry {
    static func layout(
        for pin: GooeyPinSupplementalPin,
        stageSize: CGSize,
        effectPadding: CGFloat
    ) -> GooeyPinSupplementalLayout {
        let stageWidth = stageSize.width.isFinite ? max(GooeyPinDemoLayout.pinHeight, stageSize.width) : 520
        let stageHeight = stageSize.height.isFinite ? max(GooeyPinDemoLayout.pinHeight, stageSize.height) : 280
        let maximumPadding = max(
            0,
            min(
                (stageWidth - GooeyPinDemoLayout.pinHeight) / 2,
                (stageHeight - GooeyPinDemoLayout.pinHeight) / 2
            )
        )
        let padding = effectPadding.isFinite
            ? min(maximumPadding, max(0, effectPadding))
            : 0
        let content = CGRect(
            x: padding,
            y: padding,
            width: max(GooeyPinDemoLayout.pinHeight, stageWidth - padding * 2),
            height: max(GooeyPinDemoLayout.pinHeight, stageHeight - padding * 2)
        )
        let requestedWidth = MapLibrePinLabelGeometry.size(for: pin.text).width
        let width = min(content.width, max(GooeyPinDemoLayout.pinHeight, requestedWidth))
        let height = GooeyPinDemoLayout.pinHeight
        let bounds = CGRect(
            x: content.minX + width / 2,
            y: content.minY + height / 2,
            width: max(0, content.width - width),
            height: max(0, content.height - height)
        )
        let center = GooeyPinDemoGeometry.center(for: pin.position, in: bounds)
        return GooeyPinSupplementalLayout(
            frame: CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ),
            centerBounds: bounds
        )
    }

    static func draggedPosition(
        startCenter: CGPoint,
        translation: CGSize,
        centerBounds: CGRect
    ) -> GooeyPinNormalizedPoint {
        let dx = translation.width.isFinite ? translation.width : 0
        let dy = translation.height.isFinite ? translation.height : 0
        return GooeyPinDemoGeometry.normalizedPosition(
            for: CGPoint(x: startCenter.x + dx, y: startCenter.y + dy),
            in: centerBounds
        )
    }
}

struct GooeyPinDemoCameraState: Equatable {
    static let standard = Self(scale: 1, offset: .zero)

    var scale: CGFloat
    var offset: CGSize

    func normalized() -> Self {
        Self(
            scale: scale.isFinite ? min(3, max(0.5, scale)) : 1,
            offset: CGSize(
                width: offset.width.isFinite ? offset.width : 0,
                height: offset.height.isFinite ? offset.height : 0
            )
        )
    }
}

struct GooeyPinDemoScreenPlacement: Equatable {
    let center: CGPoint
    let pointingCorner: MapLibreEdgePinPointingCorner?
    let edge: MapLibreEdgePinEdge?

    var isEdgePinned: Bool { edge != nil }
}

struct GooeyPinDemoRenderedShape: Equatable {
    let frame: CGRect
    let pointingCorner: MapLibreEdgePinPointingCorner?
}

enum GooeyPinDemoMapGeometry {
    static func screenPlacement(
        worldCenter: CGPoint,
        pinSize: CGSize,
        stageSize: CGSize,
        effectPadding: CGFloat,
        camera requestedCamera: GooeyPinDemoCameraState
    ) -> GooeyPinDemoScreenPlacement {
        let width = stageSize.width.isFinite ? max(1, stageSize.width) : 1
        let height = stageSize.height.isFinite ? max(1, stageSize.height) : 1
        let stageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let stageCenter = CGPoint(x: stageBounds.midX, y: stageBounds.midY)
        let camera = requestedCamera.normalized()
        let rawCenter = CGPoint(
            x: stageCenter.x + (worldCenter.x - stageCenter.x) * camera.scale + camera.offset.width,
            y: stageCenter.y + (worldCenter.y - stageCenter.y) * camera.scale + camera.offset.height
        )
        guard MapLibreEdgePinTrigger.isOutsideScreen(rawCenter, screenBounds: stageBounds) else {
            return GooeyPinDemoScreenPlacement(center: rawCenter, pointingCorner: nil, edge: nil)
        }

        let requestedInset = effectPadding.isFinite ? max(12, effectPadding) : 12
        let maximumInset = max(0, min((width - pinSize.width) / 2, (height - pinSize.height) / 2))
        let inset = min(requestedInset, maximumInset)
        let safeRect = stageBounds.insetBy(dx: inset, dy: inset)
        guard let projection = MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: rawCenter,
            labelSize: pinSize,
            topExtent: pinSize.height / 2,
            bottomExtent: pinSize.height / 2,
            rayOrigin: stageCenter
        ) else {
            return GooeyPinDemoScreenPlacement(
                center: CGPoint(
                    x: min(stageBounds.maxX, max(stageBounds.minX, rawCenter.x)),
                    y: min(stageBounds.maxY, max(stageBounds.minY, rawCenter.y))
                ),
                pointingCorner: nil,
                edge: nil
            )
        }
        return GooeyPinDemoScreenPlacement(
            center: projection.point,
            pointingCorner: MapLibreEdgePinGeometry.pointingCorner(
                for: projection,
                safeRect: safeRect
            ),
            edge: projection.edge
        )
    }

    static func displayedLayout(
        from worldLayout: GooeyPinDemoLayout,
        camera: GooeyPinDemoCameraState
    ) -> (layout: GooeyPinDemoLayout, shapes: [GooeyPinDemoRenderedShape]) {
        let aggregate = screenPlacement(
            worldCenter: CGPoint(x: worldLayout.aggregateFrame.midX, y: worldLayout.aggregateFrame.midY),
            pinSize: worldLayout.aggregateFrame.size,
            stageSize: worldLayout.stageSize,
            effectPadding: worldLayout.effectPadding,
            camera: camera
        )
        let single = screenPlacement(
            worldCenter: CGPoint(x: worldLayout.singleFrame.midX, y: worldLayout.singleFrame.midY),
            pinSize: worldLayout.singleFrame.size,
            stageSize: worldLayout.stageSize,
            effectPadding: worldLayout.effectPadding,
            camera: camera
        )
        let aggregateFrame = frame(size: worldLayout.aggregateFrame.size, center: aggregate.center)
        let singleFrame = frame(size: worldLayout.singleFrame.size, center: single.center)
        let layout = GooeyPinDemoLayout(
            stageSize: worldLayout.stageSize,
            effectPadding: worldLayout.effectPadding,
            contentFrame: worldLayout.contentFrame,
            aggregateCenterBounds: worldLayout.aggregateCenterBounds,
            singleCenterBounds: worldLayout.singleCenterBounds,
            aggregateFrame: aggregateFrame,
            singleFrame: singleFrame,
            metrics: GooeyPinDemoGeometry.spatialMetrics(
                aggregateFrame: aggregateFrame,
                singleFrame: singleFrame,
                fallbackDirection: worldLayout.metrics.direction
            )
        )
        return (
            layout,
            [
                GooeyPinDemoRenderedShape(
                    frame: aggregateFrame,
                    pointingCorner: aggregate.pointingCorner
                ),
                GooeyPinDemoRenderedShape(
                    frame: singleFrame,
                    pointingCorner: single.pointingCorner
                )
            ]
        )
    }

    static func displayedSupplementalLayout(
        from worldLayout: GooeyPinSupplementalLayout,
        stageSize: CGSize,
        effectPadding: CGFloat,
        camera: GooeyPinDemoCameraState
    ) -> (layout: GooeyPinSupplementalLayout, shape: GooeyPinDemoRenderedShape) {
        let placement = screenPlacement(
            worldCenter: CGPoint(x: worldLayout.frame.midX, y: worldLayout.frame.midY),
            pinSize: worldLayout.frame.size,
            stageSize: stageSize,
            effectPadding: effectPadding,
            camera: camera
        )
        let displayedFrame = frame(size: worldLayout.frame.size, center: placement.center)
        return (
            GooeyPinSupplementalLayout(
                frame: displayedFrame,
                centerBounds: worldLayout.centerBounds
            ),
            GooeyPinDemoRenderedShape(
                frame: displayedFrame,
                pointingCorner: placement.pointingCorner
            )
        )
    }

    private static func frame(size: CGSize, center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct GooeyPinDemoState: Equatable {
    static let standard: Self = {
        let scenario = GooeyPinNumberScenario.rightEdge
        return Self(
            parameters: .standard,
            numberScenarioID: scenario.id,
            numberScenarioDefinition: scenario,
            numberMemberOrderIDs: scenario.orderedMembers.map(\.id),
            supplementalPins: [],
            aggregatePosition: scenario.aggregatePosition,
            singlePosition: scenario.singlePosition,
            snapState: .separated,
            lastDirection: scenario.separationDirection,
            lastActivePin: .single
        )
    }()

    var parameters: GooeyPinDemoParameters
    var numberScenarioID: GooeyPinNumberScenarioID
    var numberScenarioDefinition: GooeyPinNumberScenario
    var numberMemberOrderIDs: [String]
    var supplementalPins: [GooeyPinSupplementalPin]
    var aggregatePosition: GooeyPinNormalizedPoint
    var singlePosition: GooeyPinNormalizedPoint
    var snapState: GooeyPinSnapState
    var lastDirection: CGVector
    var lastActivePin: GooeyPinID

    var numberScenario: GooeyPinNumberScenario {
        numberScenarioDefinition.applyingMemberOrder(numberMemberOrderIDs)
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
        numberScenarioDefinition = scenario
        numberMemberOrderIDs = scenario.orderedMembers.map(\.id)
        supplementalPins = []
        aggregatePosition = scenario.aggregatePosition
        singlePosition = scenario.singlePosition
        snapState = .separated
        lastDirection = scenario.separationDirection
        lastActivePin = .single
    }

    mutating func applyGeneratedLayout(_ layout: GooeyPinRandomLayout) {
        let scenario = layout.numberScenario
        numberScenarioID = scenario.id
        numberScenarioDefinition = scenario
        numberMemberOrderIDs = scenario.orderedMembers.map(\.id)
        supplementalPins = layout.supplementalPins
        aggregatePosition = scenario.aggregatePosition
        singlePosition = scenario.singlePosition
        snapState = .separated
        lastDirection = scenario.separationDirection
        lastActivePin = .single
    }

    mutating func setSupplementalPosition(
        _ position: GooeyPinNormalizedPoint,
        id: String
    ) {
        guard let index = supplementalPins.firstIndex(where: { $0.id == id }) else { return }
        supplementalPins[index].position = position.normalized()
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
        let maximumAggregateWidth = content.width
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

private enum GooeyDemoTab: String, CaseIterable {
    case gooey
    case agentIntro

    var title: String {
        switch self {
        case .gooey: "Gooey Pin"
        case .agentIntro: "Agent 初始页"
        }
    }

    var navigationTitle: String {
        switch self {
        case .gooey: "Pin Gooey Demo"
        case .agentIntro: "Agent 初始页 Demo"
        }
    }
}

struct GooeyPinDemoView: View {
    private static let initialPinCount = 5

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var demoState: GooeyPinDemoState
    @State private var requestedPinCount: Int
    @State private var aggregateDragStartCenter: CGPoint?
    @State private var singleDragStartCenter: CGPoint?
    @State private var activeDragPin: GooeyPinID?
    @State private var activeSupplementalPinID: String?
    @State private var preferredNumberNodeID: String?
    @State private var supplementalDragStartCenters: [String: CGPoint] = [:]
    @State private var numberOrderLockedForDrag: Bool?
    @State private var stageMetrics = GooeyPinStageMetrics.standard
    @State private var previousStagePlacement: GooeyPinStagePlacement?
    @State private var mapCamera = GooeyPinDemoCameraState.standard
    @State private var manualControlEnabled = true
    @State private var selectedDemoTab: GooeyDemoTab = .gooey

    init() {
        let layout = GooeyPinRandomLayoutGenerator.make(pinCount: Self.initialPinCount)
        var initialState = GooeyPinDemoState.standard
        initialState.applyGeneratedLayout(layout)
        _demoState = State(initialValue: initialState)
        _requestedPinCount = State(initialValue: Self.initialPinCount)
    }

    private var numberScenario: GooeyPinNumberScenario {
        demoState.numberScenario
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Demo 页面", selection: $selectedDemoTab) {
                    ForEach(GooeyDemoTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch selectedDemoTab {
                case .gooey:
                    gooeyContent
                case .agentIntro:
                    AgentIntroDemoView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                selectedDemoTab == .agentIntro
                    ? PrimaryTabPalette.background
                    : Color(uiColor: .systemGroupedBackground)
            )
            .animation(.snappy(duration: 0.25), value: selectedDemoTab)
            .navigationTitle(selectedDemoTab.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityLabel("关闭 Demo")
                }
            }
        }
        .onChange(of: demoState.parameters.mergeThreshold) { _, _ in
            resolveSnapState(using: stageMetrics.surfaceGap)
        }
        .onChange(of: demoState.parameters.splitThreshold) { _, _ in
            resolveSnapState(using: stageMetrics.surfaceGap)
        }
        .onChange(of: manualControlEnabled) { _, enabled in
            clearDragStarts()
            preferredNumberNodeID = nil
            if !enabled {
                resolveSnapState(using: stageMetrics.surfaceGap)
            }
        }
    }

    private var gooeyContent: some View {
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
                "主示例：融合 \(numberScenario.fusedText) · 分离 \(numberScenario.separatedAggregateText) + \(numberScenario.extractedMember.value)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            GooeyPinStage(
                aggregatePosition: demoState.aggregatePosition,
                singlePosition: demoState.singlePosition,
                fallbackDirection: demoState.lastDirection,
                parameters: demoState.parameters.normalized(),
                numberScenario: numberScenario,
                supplementalPins: demoState.supplementalPins,
                camera: $mapCamera,
                activeDragPin: activeDragPin,
                activeSupplementalPinID: activeSupplementalPinID,
                preferredNumberNodeID: preferredNumberNodeID,
                manualControlEnabled: manualControlEnabled,
                onDragChanged: dragChanged,
                onDragEnded: dragEnded,
                onSupplementalDragChanged: supplementalDragChanged,
                onSupplementalDragEnded: supplementalDragEnded,
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
            Toggle("手动控制", isOn: $manualControlEnabled)
                .accessibilityHint(
                    manualControlEnabled
                        ? "开启时可直接拖动每个 Pin"
                        : "关闭时由地图平移和缩放自动驱动 Pin 融合与分离"
                )

            Stepper(
                value: $requestedPinCount,
                in: GooeyPinRandomLayoutGenerator.pinCountRange
            ) {
                HStack {
                    Text("生成 Pin 数量")
                    Spacer()
                    Text("\(requestedPinCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityLabel("生成 Pin 数量")
            .accessibilityValue("\(requestedPinCount) 个")

            Button {
                regenerateRandomLayout()
            } label: {
                Label("随机生成布局", systemImage: "die.face.5.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("生成新的成员相对位置、抽取成员和分离方位")

            Text("当前舞台有 \(2 + demoState.supplementalPins.count) 个可见 Pin；聚合 Pin 无论包含多少数字都只计为 1 个。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                manualControlEnabled
                    ? "可直接拖动任意 Pin；接近时融合数字，拖离后可按新相对位置插入另一个 Pin。"
                    : "首页自动模式：Pin 不可单独拖动；拖拽地图或双指缩放改变屏幕位置，碰撞时自动聚合，离开时自动分离。"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("聚合 Pin 宽度按首页文字测量规则自动适配", systemImage: "textformat.size")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Label(
                    "地图缩放 \(Double(mapCamera.scale).formatted(.number.precision(.fractionLength(2))))×",
                    systemImage: "map"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Spacer()
                Button("重置视角") {
                    animateAssistance { mapCamera = .standard }
                }
                .font(.caption)
            }
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
            regenerateRandomLayout(resetParameters: true)
        } label: {
            Label("恢复默认", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("恢复全部 Gooey 参数并重新随机生成布局")
    }

    private func regenerateRandomLayout() {
        regenerateRandomLayout(resetParameters: false)
    }

    private func regenerateRandomLayout(resetParameters: Bool) {
        let layout = GooeyPinRandomLayoutGenerator.make(pinCount: requestedPinCount)
        clearDragStarts()
        previousStagePlacement = nil
        mapCamera = .standard
        preferredNumberNodeID = nil
        animateAssistance {
            if resetParameters {
                demoState.parameters = .standard
                manualControlEnabled = true
            }
            demoState.applyGeneratedLayout(layout)
        }
    }

    private func supplementalDragChanged(
        _ id: String,
        translation: CGSize,
        layout: GooeyPinSupplementalLayout
    ) {
        if activeSupplementalPinID == nil {
            activeSupplementalPinID = id
        }
        guard activeSupplementalPinID == id, activeDragPin == nil else { return }
        preferredNumberNodeID = id
        if supplementalDragStartCenters[id] == nil {
            supplementalDragStartCenters[id] = CGPoint(
                x: layout.frame.midX,
                y: layout.frame.midY
            )
        }
        guard let startCenter = supplementalDragStartCenters[id] else { return }
        demoState.setSupplementalPosition(
            GooeyPinSupplementalGeometry.draggedPosition(
                startCenter: startCenter,
                translation: translation,
                centerBounds: layout.centerBounds
            ),
            id: id
        )
    }

    private func supplementalDragEnded(
        _ id: String,
        translation: CGSize,
        layout: GooeyPinSupplementalLayout
    ) {
        supplementalDragChanged(id, translation: translation, layout: layout)
        supplementalDragStartCenters[id] = nil
        activeSupplementalPinID = nil
    }

    private func dragChanged(
        _ pin: GooeyPinID,
        translation: CGSize,
        layout: GooeyPinDemoLayout
    ) {
        guard activeSupplementalPinID == nil else { return }
        if activeDragPin == nil {
            activeDragPin = pin
        }
        guard activeDragPin == pin else { return }
        preferredNumberNodeID = switch pin {
        case .aggregate: GooeyPinVisualNumberNode.primaryAggregateID
        case .single: GooeyPinVisualNumberNode.primarySingleID
        }
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
        activeSupplementalPinID = nil
        supplementalDragStartCenters.removeAll()
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
    let supplementalPins: [GooeyPinSupplementalPin]
    @Binding var camera: GooeyPinDemoCameraState
    let activeDragPin: GooeyPinID?
    let activeSupplementalPinID: String?
    let preferredNumberNodeID: String?
    let manualControlEnabled: Bool
    let onDragChanged: (GooeyPinID, CGSize, GooeyPinDemoLayout) -> Void
    let onDragEnded: (GooeyPinID, CGSize, GooeyPinDemoLayout) -> Void
    let onSupplementalDragChanged: (String, CGSize, GooeyPinSupplementalLayout) -> Void
    let onSupplementalDragEnded: (String, CGSize, GooeyPinSupplementalLayout) -> Void
    let onAccessibilityAction: (GooeyPinID, GooeyPinAccessibilityAction, GooeyPinDemoLayout) -> Void

    @State private var mapPanStartOffset: CGSize?
    @State private var mapZoomStartScale: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let padding = GooeyPinEffectGeometry.safePadding(for: parameters)
            let worldLayout = GooeyPinAdaptiveLayout.layout(
                stageSize: proxy.size,
                aggregatePosition: aggregatePosition,
                singlePosition: singlePosition,
                scenario: numberScenario,
                parameters: parameters,
                effectPadding: padding,
                fallbackDirection: fallbackDirection
            )
            let displayed = GooeyPinDemoMapGeometry.displayedLayout(
                from: worldLayout,
                camera: camera
            )
            let worldSupplementalLayouts = Dictionary(
                uniqueKeysWithValues: supplementalPins.map { pin in
                    (
                        pin.id,
                        GooeyPinSupplementalGeometry.layout(
                            for: pin,
                            stageSize: proxy.size,
                            effectPadding: padding
                        )
                    )
                }
            )
            let displayedSupplemental: [
                String: (
                    layout: GooeyPinSupplementalLayout,
                    shape: GooeyPinDemoRenderedShape
                )
            ] = Dictionary(
                uniqueKeysWithValues: supplementalPins.compactMap { pin in
                    guard let world = worldSupplementalLayouts[pin.id] else { return nil }
                    return (
                        pin.id,
                        GooeyPinDemoMapGeometry.displayedSupplementalLayout(
                            from: world,
                            stageSize: proxy.size,
                            effectPadding: padding,
                            camera: camera
                        )
                    )
                }
            )
            let renderedShapes = displayed.shapes + supplementalPins.compactMap {
                displayedSupplemental[$0.id]?.shape
            }
            let supplementalNumberNodes = supplementalPins.compactMap { pin -> GooeyPinVisualNumberNode? in
                guard let frame = displayedSupplemental[pin.id]?.layout.frame else { return nil }
                let members = pin.text
                    .split(separator: ".")
                    .enumerated()
                    .map { index, value in
                        GooeyPinNumberMember(
                            id: pin.id + "-member-\(index)",
                            value: String(value),
                            relativePosition: .zero
                        )
                    }
                return GooeyPinVisualNumberNode(id: pin.id, members: members, frame: frame)
            }
            let numberNodes = [
                GooeyPinVisualNumberNode(
                    id: GooeyPinVisualNumberNode.primaryAggregateID,
                    members: numberScenario.remainingMembers,
                    frame: displayed.layout.aggregateFrame
                ),
                GooeyPinVisualNumberNode(
                    id: GooeyPinVisualNumberNode.primarySingleID,
                    members: [numberScenario.extractedMember],
                    frame: displayed.layout.singleFrame
                )
            ] + supplementalNumberNodes
            let movingNumberNodeID: String? = if manualControlEnabled {
                if let activeSupplementalPinID {
                    activeSupplementalPinID
                } else {
                    switch activeDragPin {
                    case .aggregate: GooeyPinVisualNumberNode.primaryAggregateID
                    case .single: GooeyPinVisualNumberNode.primarySingleID
                    case nil: preferredNumberNodeID
                    }
                }
            } else {
                nil
            }

            ZStack(alignment: .topLeading) {
                GooeyPinMapBackground(camera: camera)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(mapPanGesture)
                    .simultaneousGesture(mapZoomGesture)

                GooeyBlobLayer(
                    renderedShapes: renderedShapes,
                    inset: 0,
                    color: Color(red: 1, green: 110 / 255, blue: 0),
                    blurRadius: parameters.blurRadius,
                    alphaThreshold: parameters.alphaThreshold,
                    sourceOpacity: parameters.sourceOpacity
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                GooeyBlobLayer(
                    renderedShapes: renderedShapes,
                    inset: parameters.strokeWidth,
                    color: .white,
                    blurRadius: parameters.blurRadius,
                    alphaThreshold: parameters.alphaThreshold,
                    sourceOpacity: parameters.sourceOpacity
                )
                .frame(width: proxy.size.width, height: proxy.size.height)

                GooeyPinMultiNumberLayer(
                    nodes: numberNodes,
                    primaryScenario: numberScenario,
                    parameters: parameters,
                    movingNodeID: movingNumberNodeID
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)

                if manualControlEnabled {
                    pinTargets(displayLayout: displayed.layout, worldLayout: worldLayout)
                    supplementalPinTargets(
                        displayLayouts: displayedSupplemental.mapValues(\.layout),
                        worldLayouts: worldSupplementalLayouts
                    )
                }
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
                    surfaceGap: displayed.layout.metrics.surfaceGap,
                    angleDegrees: displayed.layout.metrics.angleDegrees,
                    direction: displayed.layout.metrics.direction,
                    hasDistinctCenters: displayed.layout.metrics.hasDistinctCenters,
                    placement: worldLayout.placement
                )
            )
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func pinTargets(
        displayLayout: GooeyPinDemoLayout,
        worldLayout: GooeyPinDemoLayout
    ) -> some View {
        let hitGeometry = GooeyPinHitGeometry(layout: displayLayout)

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
            .gesture(dragGesture(for: .aggregate, layout: worldLayout))
            .allowsHitTesting(activeSupplementalPinID == nil && activeDragPin != .single)
            .zIndex(activeDragPin == .aggregate ? 4 : 1)
            .accessibilityElement()
            .accessibilityLabel("聚合 Pin")
            .accessibilityValue(accessibilityValue(for: .aggregate, layout: displayLayout))
            .accessibilityHint("可二维拖动，或使用动作移动、融合和分离")
            .modifier(PinAccessibilityActions(pin: .aggregate, layout: worldLayout, handler: onAccessibilityAction))

        Color.clear
            .frame(width: hitGeometry.singleTargetFrame.width, height: hitGeometry.singleTargetFrame.height)
            .contentShape(Circle())
            .position(x: hitGeometry.singleTargetFrame.midX, y: hitGeometry.singleTargetFrame.midY)
            .gesture(dragGesture(for: .single, layout: worldLayout))
            .allowsHitTesting(activeSupplementalPinID == nil && activeDragPin != .aggregate)
            .zIndex(activeDragPin == .single ? 4 : 1.25)
            .accessibilityElement()
            .accessibilityLabel("单体 Pin")
            .accessibilityValue(accessibilityValue(for: .single, layout: displayLayout))
            .accessibilityHint("可二维拖动，或使用动作移动、融合和分离")
            .modifier(PinAccessibilityActions(pin: .single, layout: worldLayout, handler: onAccessibilityAction))

        ForEach(hitGeometry.aggregateEndHandleFrames.indices, id: \.self) { index in
            let frame = hitGeometry.aggregateEndHandleFrames[index]
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(dragGesture(for: .aggregate, layout: worldLayout))
                .allowsHitTesting(activeSupplementalPinID == nil && activeDragPin != .single)
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
            .gesture(dragGesture(for: .single, layout: worldLayout))
            .allowsHitTesting(activeSupplementalPinID == nil && activeDragPin != .aggregate)
            .zIndex(activeDragPin == .single ? 5 : 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func supplementalPinTargets(
        displayLayouts: [String: GooeyPinSupplementalLayout],
        worldLayouts: [String: GooeyPinSupplementalLayout]
    ) -> some View {
        ForEach(supplementalPins) { pin in
            if let displayLayout = displayLayouts[pin.id],
               let worldLayout = worldLayouts[pin.id] {
                let targetWidth = max(GooeyPinHitGeometry.minimumTargetSize, displayLayout.frame.width)
                Color.clear
                    .frame(width: targetWidth, height: GooeyPinHitGeometry.minimumTargetSize)
                    .contentShape(Capsule())
                    .position(x: displayLayout.frame.midX, y: displayLayout.frame.midY)
                    .gesture(supplementalDragGesture(for: pin.id, layout: worldLayout))
                    .allowsHitTesting(
                        activeDragPin == nil
                            && (activeSupplementalPinID == nil || activeSupplementalPinID == pin.id)
                    )
                    .zIndex(activeSupplementalPinID == pin.id ? 5 : 2.5)
                    .accessibilityElement()
                    .accessibilityLabel(pin.text.contains(".") ? "聚合 Pin" : "单体 Pin")
                    .accessibilityValue("数字 \(pin.text)")
                    .accessibilityHint("可二维拖动并与其他 Pin 产生 Gooey 融合")
            }
        }
    }

    private func dragGesture(for pin: GooeyPinID, layout: GooeyPinDemoLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { onDragChanged(pin, worldTranslation($0.translation), layout) }
            .onEnded { onDragEnded(pin, worldTranslation($0.translation), layout) }
    }

    private func supplementalDragGesture(
        for id: String,
        layout: GooeyPinSupplementalLayout
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { onSupplementalDragChanged(id, worldTranslation($0.translation), layout) }
            .onEnded { onSupplementalDragEnded(id, worldTranslation($0.translation), layout) }
    }

    private var mapPanGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if mapPanStartOffset == nil {
                    mapPanStartOffset = camera.offset
                }
                let start = mapPanStartOffset ?? camera.offset
                camera.offset = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in mapPanStartOffset = nil }
    }

    private var mapZoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if mapZoomStartScale == nil {
                    mapZoomStartScale = camera.scale
                }
                let start = mapZoomStartScale ?? camera.scale
                camera.scale = min(3, max(0.5, start * value.magnification))
            }
            .onEnded { _ in mapZoomStartScale = nil }
    }

    private func worldTranslation(_ screenTranslation: CGSize) -> CGSize {
        let scale = camera.normalized().scale
        return CGSize(
            width: screenTranslation.width / scale,
            height: screenTranslation.height / scale
        )
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
    let renderedShapes: [GooeyPinDemoRenderedShape]
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
                for renderedShape in renderedShapes {
                    let shape = renderedShape.frame.insetBy(dx: inset, dy: inset)
                    if shape.width > 0, shape.height > 0 {
                        layer.fill(
                            Path(
                                MapLibrePinCornerTransitionGeometry.path(
                                    in: shape,
                                    pointingCorner: renderedShape.pointingCorner
                                )
                            ),
                            with: .color(.white)
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GooeyPinMapBackground: View {
    let camera: GooeyPinDemoCameraState

    var body: some View {
        Canvas { context, size in
            let value = camera.normalized()
            let spacing = max(24, 44 * value.scale)
            let startX = value.offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = value.offset.height.truncatingRemainder(dividingBy: spacing)
            var grid = Path()
            var x = startX - spacing
            while x <= size.width + spacing {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = startY - spacing
            while y <= size.height + spacing {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(grid, with: .color(.white.opacity(0.055)), lineWidth: 1)
        }
        .background(Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255))
        .accessibilityLabel("模拟地图，可拖拽平移并双指缩放")
    }
}

private struct GooeyPinMultiNumberLayer: View {
    let nodes: [GooeyPinVisualNumberNode]
    let primaryScenario: GooeyPinNumberScenario
    let parameters: GooeyPinDemoParameters
    let movingNodeID: String?

    var body: some View {
        let presentation = GooeyPinMultiNumberLayout.presentation(
            nodes: nodes,
            primaryScenario: primaryScenario,
            parameters: parameters,
            movingNodeID: movingNodeID
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

// MARK: - Agent 初始页 Demo

/// Agent 页面初始状态的视觉实验：ASCII 码铺满背景，中央渲染一个旋转的
/// ASCII 地球（正交投影 + 光照梯度字符），配合欢迎文案与输入提示胶囊。
private struct AgentIntroDemoView: View {
    var body: some View {
        ZStack {
            PrimaryTabPalette.background

            AgentIntroASCIIBackgroundView()

            // 中心提亮、四周压暗的暗角，让 ASCII 底纹不干扰主体阅读。
            RadialGradient(
                colors: [.clear, PrimaryTabPalette.background.opacity(0.74)],
                center: .center,
                startRadius: 100,
                endRadius: 330
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(PrimaryTabPalette.accent.opacity(0.16))
                        .frame(width: 264, height: 264)
                        .blur(radius: 48)
                    Circle()
                        .stroke(PrimaryTabPalette.accent.opacity(0.22), lineWidth: 1)
                        .frame(width: 256, height: 256)
                    AgentIntroGlobeView(diameter: 224)
                }

                Text("一起把旅程安排好")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 40)
                Text("说说你想去哪里、同行人和时间范围。\n我会先给出可检查的建议，确认后才会加入行程。")
                    .font(.subheadline)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(PrimaryTabPalette.accent)
                    Text("告诉 Agent 你的想法…")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(PrimaryTabPalette.elevatedSurface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1)
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
        }
    }
}

/// 静态 ASCII 底纹：按网格坐标哈希取字符，内容稳定、只随布局尺寸重绘。
private struct AgentIntroASCIIBackgroundView: View {
    private let cell: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let columns = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for row in 0 ... rows {
                for column in 0 ... columns {
                    context.draw(
                        Text(String(Self.glyph(column: column, row: row)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.09)),
                        at: CGPoint(
                            x: (CGFloat(column) + 0.5) * cell,
                            y: (CGFloat(row) + 0.5) * cell
                        )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static let glyphPool: [Character] = Array("01·:+*")

    private static func glyph(column: Int, row: Int) -> Character {
        let seed = UInt(bitPattern: (column &* 2_654_435_761) ^ (row &* 2_246_822_519))
        return glyphPool[Int(seed % UInt(glyphPool.count))]
    }
}

/// 旋转 ASCII 地球：贴图与昼夜混合参考 globe-master（真实地球贴图 +
/// 顶部光源昼夜过渡），字符本体附着在 Fibonacci 球面采样点上，
/// 经自转与地轴倾角变换后做透视投影，随深度产生缩放与透明度衰减。
private struct AgentIntroGlobeView: View {
    let diameter: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / 30)) { context in
            Canvas { canvas, size in
                let rotation = (context.date.timeIntervalSince1970 * 0.35)
                    .truncatingRemainder(dividingBy: .pi * 2)
                AgentIntroGlobeRenderer.draw(
                    context: &canvas,
                    size: size,
                    rotation: rotation
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("旋转的 ASCII 地球")
    }
}

private enum AgentIntroGlobeRenderer {
    private static let tilt = 23.5 * Double.pi / 180

    // 光照方向以观察者为主、略偏左上：整个球面以白天贴图为主，
    // 仅在边缘与右下背光处平滑过渡到黑夜贴图，避免昼夜分界线压在赤道上。
    private static let light: (x: Double, y: Double, z: Double) = {
        let raw = (x: -0.55, y: 0.4, z: 1.0)
        let length = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
        return (raw.x / length, raw.y / length, raw.z / length)
    }()

    static func draw(context: inout GraphicsContext, size: CGSize, rotation: Double) {
        let radius = Double(min(size.width, size.height)) / 2 * 0.94
        guard radius > 0 else { return }
        let centerX = Double(size.width) / 2
        let centerY = Double(size.height) / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let cosT = cos(tilt)
        let sinT = sin(tilt)

        for point in AgentIntroEarthTexture.samples {
            // 自转（绕竖直轴）+ 地轴倾角
            let rotatedX = point.x * cosR + point.z * sinR
            let rotatedZ = -point.x * sinR + point.z * cosR
            let tiltedY = point.y * cosT - rotatedZ * sinT
            let tiltedZ = point.y * sinT + rotatedZ * cosT
            guard tiltedZ > 0 else { continue }

            // 光照决定昼夜贴图混合比例（法线即单位球面位置向量）
            let diffuse = rotatedX * Self.light.x + tiltedY * Self.light.y + tiltedZ * Self.light.z
            let luminance = min(1, max(0, 0.15 + 1.15 * diffuse))
            let sampled = AgentIntroEarthTexture.sample(
                longitude: point.longitude,
                sineLatitude: point.y
            )
            let blended = (1 - luminance) * sampled.night + luminance * sampled.day
            let index = min(
                AgentIntroEarthTexture.palette.count - 1,
                max(0, Int(blended.rounded()))
            )
            let glyph = AgentIntroEarthTexture.palette[index]
            guard glyph != " " else { continue }

            // 透视深度：越靠边缘的字符越小越淡
            let depth = tiltedZ
            context.draw(
                Text(String(glyph))
                    .font(.system(size: 12 * (0.78 + 0.32 * depth), design: .monospaced))
                    .foregroundStyle(PrimaryTabPalette.accent.opacity(0.4 + 0.6 * depth)),
                at: CGPoint(x: centerX + rotatedX * radius, y: centerY - tiltedY * radius)
            )
        }
    }
}

/// 地球贴图数据，内容来自 globe-master 的 earth.txt / earth_night.txt
///（300×76，等距圆柱投影，首列为 180°W、向东递增，首行为北极）。
/// 按 palette 下标（0...H）逐行 RLE 编码，避免长串空白字符在源码中丢失。
private enum AgentIntroEarthTexture {
    static let width = 300
    static let height = 76
    static let palette: [Character] = Array(" .:;',wiogOLXHWYV@")

    private static let dayRLE = """
    1686,D1,126,D16,1241,D5,13,95,H9,96,13,910,H18,93,16,D2,148,D5,12,D3,11,D5,123,D4,1125,D3,13,D1,11,D5,11,91,11,91,H1,91,H1,92,H1,91,H7,91,17,91,H36,91,12,D1,125,91,11,95,13,D2,116,D3,14,D4,126,D1,13,91,12,D1,12,D2,1110,D1,18,D8,13,D2,12,D1,11,91,12,97,11,D1,14,D1,11,98,H32,91,128,D1,13,D1,11,D3,130,D7,120,D7,94,15,D2,120,D4,177,D1,111,D2,12,D2,11,D1,11,91,11,D1,92,11,92,11,93,11,93,11,D2,115,D1,11,91,H28,91,11,D1,160,D1,11,92,11,D2,115,D5,95,H12,95,11,D3,15,D2,18,D2,15,D1,11,D4,124,D2,117,D1,125,D1,94,11,91,H2,95,11,91,H1,91,11,D2,11,92,11,92,11,D1,11,91,H2,92,H2,93,H1,91,11,D3,113,91,H24,91,H1,91,161,D1,91,H1,91,D1,18,D1,93,11,D1,91,D1,11,91,11,93,H29,94,H4,91,12,D6,11,94,14,D2,122,D2,111,D2,11,94,H1,97,17,D5,14,91,16,D2,11,93,H5,94,D3,12,93,11,D2,13,H2,91,14,91,H4,92,112,93,H20,91,12,D1,130,D3,12,99,12,D3,19,D2,12,D5,14,D3,91,H3,12,H46,92,H17,96,18,D1,16,D2,94,D4,13,D1,11,92,H39,96,H3,95,H2,91,H5,91,11,91,H2,91,13,D1,13,91,H4,92,12,D1,16,91,H15,91,11,D3,110,D1,125,91,H15,95,11,D3,91,11,D1,94,H1,93,H1,91,H6,91,H3,91,11,H88,D3,11,92,11,D1,12,D1,11,94,H59,92,11,92,11,D2,14,D1,11,91,H4,13,D1,17,D1,11,H9,91,D3,111,97,D1,119,D1,11,91,H6,91,D1,11,91,H8,14,92,H1,91,H111,91,18,D2,12,D1,11,93,H56,91,11,D1,13,D2,11,D1,11,D2,12,D1,11,D1,12,92,12,D1,110,D1,91,H5,91,D1,117,D3,18,D1,19,D1,11,92,H6,91,11,D2,92,H111,92,H2,92,H7,93,12,D1,111,D1,11,92,H7,95,13,95,H36,D1,113,91,H4,92,D1,12,D1,113,D2,12,91,D1,139,91,H9,91,D1,11,D1,96,H95,97,H2,91,11,D1,14,93,15,D1,121,D2,11,92,11,91,11,D1,111,D1,91,H34,91,11,D3,110,H6,93,H2,91,D1,147,91,11,D1,15,D1,15,91,H3,D2,14,91,H94,92,11,D1,17,D2,12,D1,11,92,H1,91,D1,126,D3,11,D2,12,D1,115,D1,11,92,H34,92,12,D3,11,D2,11,H13,11,D2,141,D1,11,92,H1,18,D1,92,11,92,12,D3,91,H95,91,11,D1,113,D1,H4,91,D1,123,D3,128,D1,11,91,H38,91,D1,11,91,H17,91,D1,137,D1,91,H1,91,D1,11,91,H1,91,13,D1,12,91,H2,95,H1,91,H97,94,12,D1,110,91,H1,11,D1,159,92,H37,92,H10,96,12,91,138,D3,11,D1,11,92,11,91,11,92,H113,D1,92,19,D1,11,D1,162,D1,11,92,H44,94,D3,11,D1,94,141,D1,11,93,H115,91,11,91,D1,177,H47,91,H1,91,16,D3,143,H11,92,H12,91,12,91,H1,91,11,91,H7,91,12,D1,11,91,H69,91,D1,13,D1,177,H44,91,11,D2,11,D2,144,D1,13,D2,11,H4,93,13,H1,91,12,92,H8,91,D1,12,D3,11,D1,11,92,H4,14,91,H65,94,D1,13,D1,92,11,D2,174,H41,92,11,D1,151,H7,91,16,91,11,D1,14,D2,91,H2,93,H1,14,93,11,D3,91,H5,91,D1,11,D1,11,91,H54,92,H5,91,D1,17,D1,91,D2,176,D1,91,H39,91,D1,153,91,H6,91,12,D1,18,D2,91,D1,11,D1,91,H1,91,D1,11,91,H18,D1,13,H53,91,D2,11,D2,91,H1,91,D1,19,91,D1,179,91,H37,91,155,D2,11,91,13,D2,16,92,12,D2,14,D1,12,D3,11,91,12,92,11,H11,91,13,H54,91,11,D1,12,D1,91,H1,91,13,D3,92,H1,184,91,H32,91,11,D1,156,D1,11,H1,93,H9,91,D1,117,D1,12,H69,91,D1,17,D1,11,92,11,91,11,D2,186,H1,92,H26,11,D1,158,91,H17,93,D2,11,D1,93,11,D8,H72,D1,18,D1,192,D1,91,11,91,H12,92,13,91,11,D3,12,H1,158,D1,11,H23,92,H23,11,D1,91,H58,1103,D1,91,11,D1,91,H10,D1,111,91,H1,D1,155,91,H38,12,91,H9,91,D3,94,H52,1108,D2,91,H7,91,116,D1,152,H41,D2,91,H10,91,D2,11,91,D4,11,D3,11,91,H41,91,D3,1106,D1,13,H6,91,110,D3,13,D1,150,91,H42,91,13,H15,91,19,91,H1,91,H12,94,H13,91,H1,93,12,D1,171,D1,142,91,H6,16,H2,17,D1,12,D2,12,D1,144,91,H44,13,H14,110,D2,11,H9,92,D1,15,H10,91,D2,91,D1,1120,D1,12,91,H3,94,H2,91,18,D1,12,D2,11,D2,11,D2,11,D1,139,H44,91,D1,11,D1,91,H8,92,11,D1,112,D1,H7,91,11,D1,18,H1,91,H7,91,D3,19,91,1116,D4,11,H3,94,D1,117,D1,131,D1,14,D1,91,H45,91,11,D1,11,H5,91,11,D1,118,H5,D1,110,D2,12,H8,110,91,1123,D2,11,91,H2,110,D2,144,91,H48,11,91,11,D3,121,91,H3,91,110,D1,13,D1,H1,11,92,H5,D1,112,D1,1124,H1,18,91,H1,11,92,12,D1,13,D1,136,D1,11,91,H47,13,93,121,91,H2,115,D1,91,14,91,H1,11,D1,18,D1,11,D1,91,1129,91,12,92,H3,91,H8,91,139,91,H51,91,121,D1,11,D1,11,91,113,D1,91,14,D1,19,D2,15,91,D1,1130,H15,91,13,D1,134,D1,11,91,H2,93,H1,91,12,D2,91,H35,91,125,D1,112,D3,12,91,112,91,11,D1,11,D1,11,D1,11,D1,1129,91,H21,136,D1,111,D3,H30,91,142,91,11,D1,91,H1,D1,16,D1,11,H3,D1,1134,D1,91,H23,D1,148,D1,H28,91,D1,143,D1,91,H1,93,13,D1,92,H5,12,D4,12,91,D1,1115,D2,17,D1,H24,91,H1,92,11,D1,145,H26,91,D1,146,D1,11,H2,91,D2,12,91,H5,16,D2,13,D1,11,91,12,D3,16,D1,1109,D1,H31,93,11,D1,139,D1,91,H23,D1,149,D2,91,H2,11,D1,12,D1,16,91,11,91,D1,12,D4,11,D1,91,11,91,H4,91,11,D1,16,D1,1105,H36,92,139,91,H21,91,153,D1,13,D5,14,D4,18,D2,11,D1,91,H5,91,11,D2,11,D1,12,D1,1103,D1,91,H35,91,139,D1,H22,156,D3,13,D9,11,D1,13,D1,17,93,D1,11,91,12,D1,14,D5,1100,91,H33,142,91,H21,166,D2,11,D2,14,D3,112,D3,17,D2,1101,91,H30,91,D1,141,D1,91,H21,91,171,D1,13,91,H2,92,14,H1,1119,91,H28,143,91,H22,91,13,D1,11,91,H1,91,161,D1,91,H1,92,H5,11,D1,12,D1,H2,91,D1,117,D2,18,D1,189,D1,11,91,H25,D1,141,D1,H20,91,11,D1,13,D1,H4,D1,159,D1,91,H12,93,H3,91,118,D1,18,D1,192,H24,144,D1,91,H17,D1,16,D1,H3,91,155,D2,12,91,H21,91,11,D1,112,D1,1103,91,H20,93,146,D1,H17,17,91,H2,91,154,D1,91,H28,91,113,D1,1102,91,H17,91,11,D1,150,91,H14,91,11,D1,16,D1,92,D1,155,H31,91,D1,1112,D1,H18,153,D1,91,H13,D1,166,D1,H32,91,1113,H17,155,D1,91,H10,91,D1,168,D1,H31,91,1112,91,H15,91,D1,156,D1,H8,91,172,91,H6,93,12,D2,11,91,H14,91,D1,1111,D1,H11,94,D1,160,91,14,D2,174,92,11,D4,110,92,H9,91,D1,117,D1,193,D1,91,H12,1162,D1,12,H6,92,D1,118,D1,12,D2,189,D1,H9,13,D1,1165,D2,11,D1,11,D2,122,H1,11,D1,190,91,H5,91,1174,D1,92,119,D1,91,11,D1,193,91,H4,92,D1,1174,D1,11,D1,115,D1,11,92,11,D1,193,H5,91,1196,91,11,D1,194,91,H5,91,1113,D1,1179,91,H4,91,D1,15,D3,1285,D1,11,93,H1,11,D1,15,D1,1289,D2,12,D1,1904,D5,1291,D1,11,91,11,D4,190,D4,136,D4,15,D3,1147,D1,11,92,11,D1,187,D3,13,91,H5,92,18,D1,17,D3,12,914,H4,94,H3,913,H6,96,12,D1,12,D1,12,D1,1108,D3,92,12,H3,91,11,D1,144,D1,12,D1,14,D11,11,D2,11,D9,11,92,14,91,H22,92,11,D2,12,92,H61,92,H1,94,11,D6,174,D2,14,D7,16,D1,12,D1,13,93,11,H5,138,D2,11,91,H1,92,H1,92,H1,93,H55,13,91,H79,92,137,D1,11,D1,12,D3,18,92,12,91,11,91,11,91,11,91,13,D6,12,91,H12,93,H3,92,H9,92,11,D1,132,D3,11,91,H148,91,12,D1,129,D1,13,D2,12,93,H57,91,11,91,13,D3,115,D2,19,D1,13,94,H156,91,D1,11,D3,122,D1,11,D2,12,D1,14,92,H55,95,D2,12,D1,11,D1,11,D2,12,D2,16,D1,11,91,H4,91,15,D1,13,95,H155,91,11,D4,125,D2,13,D2,11,93,H62,93,H1,94,14,D1,13,D2,16,D3,11,96,H163,12,D2,115,D2,18,97,H79,93,H188,95,15,H600
    """

    private static let nightRLE = """
    0686,11,026,116,0241,15,03,35,29,36,03,310,218,33,06,12,048,15,02,13,01,15,023,14,0125,13,03,11,01,15,01,31,01,31,21,31,21,32,21,31,27,31,07,31,236,31,02,11,025,31,01,35,03,12,016,13,04,14,026,11,03,31,02,11,02,12,0110,11,08,18,03,12,02,11,01,31,02,37,01,11,04,11,01,38,232,31,028,11,03,11,01,13,030,17,020,17,34,05,12,020,14,077,11,011,12,02,12,01,11,01,31,01,11,32,01,32,01,33,01,33,01,12,015,11,01,31,228,31,01,11,060,11,01,32,01,12,015,15,35,212,35,01,13,05,12,08,12,05,11,01,14,024,12,017,11,025,11,34,01,31,22,35,01,31,21,31,01,12,01,32,01,32,01,11,01,31,22,32,22,33,21,31,01,13,013,31,224,31,21,31,061,11,31,21,31,11,08,11,33,01,11,31,11,01,31,01,33,229,34,24,31,02,16,01,34,04,12,022,12,011,12,01,34,21,37,07,15,04,31,06,12,01,33,25,34,13,02,33,01,12,03,22,31,04,31,24,32,012,33,220,31,02,11,030,13,02,39,02,13,09,12,02,15,04,13,31,23,02,246,32,217,36,08,11,06,12,34,14,03,11,01,32,239,36,23,35,22,31,25,31,01,31,22,31,03,11,03,31,24,32,02,11,06,31,215,31,01,13,010,11,025,31,215,35,01,13,31,01,11,34,21,33,21,31,26,31,23,31,01,288,13,01,32,01,11,02,11,01,34,259,32,01,32,01,12,04,11,01,31,24,03,11,07,11,01,29,31,13,011,37,11,019,11,01,31,26,31,11,01,31,28,04,32,21,31,2111,31,08,12,02,11,01,33,256,31,01,11,03,12,01,11,01,12,02,11,01,11,02,32,02,11,010,11,31,25,31,11,017,13,08,11,09,11,01,32,26,31,01,12,32,2111,32,22,32,27,33,02,11,011,11,01,32,27,35,03,35,236,11,013,31,24,32,11,02,11,013,12,02,31,11,039,31,29,31,11,01,11,36,295,37,22,31,01,11,04,33,05,11,021,12,01,32,01,31,01,11,011,11,31,234,31,01,13,010,26,33,22,31,11,047,31,01,11,05,11,05,31,23,12,04,31,294,32,01,11,07,12,02,11,01,32,21,31,11,026,13,01,12,02,11,015,11,01,32,234,32,02,13,01,12,01,213,01,12,041,11,01,32,21,08,11,32,01,32,02,13,31,295,31,01,11,013,11,24,31,11,023,13,028,11,01,31,238,31,11,01,31,217,31,11,037,11,31,21,31,11,01,31,21,31,03,11,02,31,22,35,21,31,297,34,02,11,010,31,21,01,11,059,32,237,32,210,36,02,31,038,13,01,11,01,32,01,31,01,32,2113,11,32,09,11,01,11,062,11,01,32,244,34,13,01,11,34,041,11,01,33,2115,31,01,31,11,077,247,31,21,31,06,13,043,211,32,212,31,02,31,21,31,01,31,27,31,02,11,01,31,269,31,11,03,11,077,244,31,01,12,01,12,044,11,03,12,01,24,33,03,21,31,02,32,28,31,11,02,13,01,11,01,32,24,04,31,265,34,11,03,11,32,01,12,074,241,32,01,11,051,27,31,06,31,01,11,04,12,31,22,33,21,04,33,01,13,31,25,31,11,01,11,01,31,254,32,25,31,11,07,11,31,12,076,11,31,239,31,11,053,31,26,31,02,11,08,12,31,11,01,11,31,21,31,11,01,31,218,11,03,253,31,12,01,12,31,21,31,11,09,31,11,079,31,237,31,055,12,01,31,03,12,06,32,02,12,04,11,02,13,01,31,02,32,01,211,31,03,254,31,01,11,02,11,31,21,31,03,13,32,21,084,31,232,31,01,11,056,11,01,21,33,29,31,11,017,11,02,269,31,11,07,11,01,32,01,31,01,12,086,21,32,226,01,11,058,31,217,33,12,01,11,33,01,18,272,11,08,11,092,11,31,01,31,212,32,03,31,01,13,02,21,058,11,01,223,32,223,01,11,31,258,0103,11,31,01,11,31,210,11,011,31,21,11,055,31,238,02,31,29,31,13,34,252,0108,12,31,27,31,016,11,052,241,12,31,210,31,12,01,31,14,01,13,01,31,241,31,13,0106,11,03,26,31,010,13,03,11,050,31,242,31,03,215,31,09,31,21,31,212,34,213,31,21,33,02,11,071,11,042,31,26,06,22,07,11,02,12,02,11,044,31,244,03,214,010,12,01,29,32,11,05,210,31,12,31,11,0120,11,02,31,23,34,22,31,08,11,02,12,01,12,01,12,01,11,039,244,31,11,01,11,31,28,32,01,11,012,11,27,31,01,11,08,21,31,27,31,13,09,31,0116,14,01,23,34,11,017,11,031,11,04,11,31,245,31,01,11,01,25,31,01,11,018,25,11,010,12,02,28,010,31,0123,12,01,31,22,010,12,044,31,248,01,31,01,13,021,31,23,31,010,11,03,11,21,01,32,25,11,012,11,0124,21,08,31,21,01,32,02,11,03,11,036,11,01,31,247,03,33,021,31,22,015,11,31,04,31,21,01,11,08,11,01,11,31,0129,31,02,32,23,31,28,31,039,31,251,31,021,11,01,11,01,31,013,11,31,04,11,09,12,05,31,11,0130,215,31,03,11,034,11,01,31,22,33,21,31,02,12,31,235,31,025,11,012,13,02,31,012,31,01,11,01,11,01,11,01,11,0129,31,221,036,11,011,13,230,31,042,31,01,11,31,21,11,06,11,01,23,11,0134,11,31,223,11,048,11,228,31,11,043,11,31,21,33,03,11,32,25,02,14,02,31,11,0115,12,07,11,224,31,21,32,01,11,045,226,31,11,046,11,01,22,31,12,02,31,25,06,12,03,11,01,31,02,13,06,11,0109,11,231,33,01,11,039,11,31,223,11,049,12,31,22,01,11,02,11,06,31,01,31,11,02,14,01,11,31,01,31,24,31,01,11,06,11,0105,236,32,039,31,221,31,053,11,03,15,04,14,08,12,01,11,31,25,31,01,12,01,11,02,11,0103,11,31,235,31,039,11,222,056,13,03,19,01,11,03,11,07,33,11,01,31,02,11,04,15,0100,31,233,042,31,221,066,12,01,12,04,13,012,13,07,12,0101,31,230,31,11,041,11,31,221,31,071,11,03,31,22,32,04,21,0119,31,228,043,31,222,31,03,11,01,31,21,31,061,11,31,21,32,25,01,11,02,11,22,31,11,017,12,08,11,089,11,01,31,225,11,041,11,220,31,01,11,03,11,24,11,059,11,31,212,33,23,31,018,11,08,11,092,224,044,11,31,217,11,06,11,23,31,055,12,02,31,221,31,01,11,012,11,0103,31,220,33,046,11,217,07,31,22,31,054,11,31,228,31,013,11,0102,31,217,31,01,11,050,31,214,31,01,11,06,11,32,11,055,231,31,11,0112,11,218,053,11,31,213,11,066,11,232,31,0113,217,055,11,31,210,31,11,068,11,231,31,0112,31,215,31,11,056,11,28,31,072,31,26,33,02,12,01,31,214,31,11,0111,11,211,34,11,060,31,04,12,074,32,01,14,010,32,29,31,11,017,11,093,11,31,212,0162,11,02,26,32,11,018,11,02,12,089,11,29,03,11,0165,12,01,11,01,12,022,21,01,11,090,31,25,31,0174,11,32,019,11,31,01,11,093,31,24,32,11,0174,11,01,11,015,11,01,32,01,11,093,25,31,0196,31,01,11,094,31,25,31,0113,11,0179,31,24,31,11,05,13,0285,11,01,33,21,01,11,05,11,0289,12,02,11,0904,15,0291,11,01,31,01,14,090,14,036,14,05,13,0147,11,01,32,01,11,087,13,03,31,25,32,08,11,07,13,02,314,24,34,23,313,26,36,02,11,02,11,02,11,0108,13,32,02,23,31,01,11,044,11,02,11,04,111,01,12,01,19,01,32,04,31,222,32,01,12,02,32,261,32,21,34,01,16,074,12,04,17,06,11,02,11,03,33,01,25,038,12,01,31,21,32,21,32,21,33,255,03,31,279,32,037,11,01,11,02,13,08,32,02,31,01,31,01,31,01,31,03,16,02,31,212,33,23,32,29,32,01,11,032,13,01,31,2148,31,02,11,029,11,03,12,02,33,257,31,01,31,03,13,015,12,09,11,03,34,2156,31,11,01,13,022,11,01,12,02,11,04,32,255,35,12,02,11,01,11,01,12,02,12,06,11,01,31,24,31,05,11,03,35,2155,31,01,14,025,12,03,12,01,33,262,33,21,34,04,11,03,12,06,13,01,36,2163,02,12,015,12,08,37,279,33,2188,35,05,2600
    """

    private static let dayIndices = decode(dayRLE)
    private static let nightIndices = decode(nightRLE)

    /// Fibonacci 球面均匀采样点；经度在采样时固定，字符随采样点携带大陆信息一起旋转。
    struct SurfaceSample {
        let x: Double
        let y: Double
        let z: Double
        let longitude: Double
    }

    static let samples: [SurfaceSample] = makeSamples(count: 900)

    static func sample(longitude: Double, sineLatitude: Double) -> (day: Double, night: Double) {
        let latitude = asin(min(1, max(-1, sineLatitude)))
        let u = (longitude / (2 * .pi) + 0.5) * Double(width) - 0.5
        let v = (0.5 - latitude / .pi) * Double(height - 1)
        return (bilinear(dayIndices, u: u, v: v), bilinear(nightIndices, u: u, v: v))
    }

    private static func bilinear(_ grid: [Double], u: Double, v: Double) -> Double {
        guard grid.count == width * height else { return 0 }
        var x = u.truncatingRemainder(dividingBy: Double(width))
        if x < 0 { x += Double(width) }
        let y = min(Double(height - 1), max(0, v))
        let x0 = Int(x.rounded(.down)) % width
        let x1 = (x0 + 1) % width
        let y0 = Int(y.rounded(.down))
        let y1 = min(height - 1, y0 + 1)
        let tx = x - x.rounded(.down)
        let ty = y - y.rounded(.down)
        let top = grid[y0 * width + x0] * (1 - tx) + grid[y0 * width + x1] * tx
        let bottom = grid[y1 * width + x0] * (1 - tx) + grid[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    private static func makeSamples(count: Int) -> [SurfaceSample] {
        let goldenAngle = Double.pi * (3 - (5.0).squareRoot())
        return (0 ..< count).map { index in
            let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let ring = (1 - y * y).squareRoot()
            let phi = Double(index) * goldenAngle
            let x = cos(phi) * ring
            let z = sin(phi) * ring
            return SurfaceSample(x: x, y: y, z: z, longitude: atan2(x, z))
        }
    }

    private static func decode(_ rle: String) -> [Double] {
        let digits = Array("0123456789ABCDEFGH")
        var lookup: [Character: Double] = [:]
        for (offset, digit) in digits.enumerated() { lookup[digit] = Double(offset) }
        var result: [Double] = []
        result.reserveCapacity(width * height)
        for run in rle.split(separator: ",") {
            guard let symbol = run.first,
                  let value = lookup[symbol],
                  let count = Int(run.dropFirst()) else { continue }
            result.append(contentsOf: repeatElement(value, count: count))
        }
        return result
    }
}
