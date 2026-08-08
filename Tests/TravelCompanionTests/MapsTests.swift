import XCTest
import CoreLocation
import SwiftData
@testable import TravelCompanion

final class MapsTests: XCTestCase {
    private func edgeMember(
        _ suffix: Int,
        order: Int,
        degrees: CGFloat,
        position: CGFloat,
        edge: MapLibreEdgePinEdge = .top,
        highlighted: Bool = false
    ) -> MapLibreEdgePinGroupMember {
        MapLibreEdgePinGroupMember(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            edge: edge,
            directionAngle: degrees * .pi / 180,
            projectedPosition: position,
            isHighlighted: highlighted
        )
    }

    private func regularMember(
        _ suffix: Int,
        order: Int,
        center: CGPoint,
        highlighted: Bool = false
    ) -> MapLibreRegularPinMember {
        let labelSize = CGSize(width: 32, height: 32)
        return MapLibreRegularPinMember(
            id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            numberCenter: center,
            renderedFrame: MapLibreEdgePinGeometry.renderedOuterFrame(
                numberCenter: center,
                labelSize: labelSize,
                topExtent: highlighted ? 50 : 16,
                bottomExtent: 16
            ),
            isHighlighted: highlighted
        )
    }

    private func projectedMember(
        _ suffix: Int,
        order: Int,
        degrees: CGFloat,
        screenCenter: CGPoint,
        distance: CGFloat = 1_000,
        highlighted: Bool = false
    ) -> MapLibreProjectedEdgePinMember {
        let angle = degrees * .pi / 180
        return MapLibreProjectedEdgePinMember(
            id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            sourcePoint: CGPoint(
                x: screenCenter.x + cos(angle) * distance,
                y: screenCenter.y + sin(angle) * distance
            ),
            isHighlighted: highlighted
        )
    }

    private func gooeyID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", suffix))!
    }

    private func gooeySnapshot(
        _ members: [Int],
        frame: CGRect,
        label: String? = nil,
        highlighted: Bool = false,
        pointingCorner: MapLibreEdgePinPointingCorner? = nil
    ) -> MapLibrePinVisualSnapshot {
        let ids = members.map(gooeyID)
        return MapLibrePinVisualSnapshot(
            representativeID: ids[0],
            orderedMemberIDs: ids,
            numberFrame: frame,
            labelText: label ?? members.map(String.init).joined(separator: "."),
            isHighlighted: highlighted,
            showsCategoryBubble: highlighted,
            pointingCorner: pointingCorner
        )
    }

    private func partition(
        generation: Int,
        _ placements: [MapLibrePinVisualSnapshot]
    ) -> MapLibrePinPartitionSnapshot {
        MapLibrePinPartitionSnapshot(
            updateGeneration: generation,
            placements: placements
        )
    }

    private func pathElementCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }

    private func pointedRadius(
        _ radii: MapLibrePinCornerRadii,
        at corner: MapLibreEdgePinPointingCorner
    ) -> CGFloat {
        switch corner {
        case .topLeft: radii.topLeft
        case .topRight: radii.topRight
        case .bottomLeft: radii.bottomLeft
        case .bottomRight: radii.bottomRight
        }
    }

    func testEdgePinSafeRectUsesCompleteFrameMarginsAndMeasuredTimeline() {
        let rect = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 822
        )

        XCTAssertEqual(rect.minX, 20, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 410, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 160, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 802, accuracy: 0.001)
    }

    func testCollapsedOverlayUsesTabBarTopAsBottomBoundary() {
        let screenBounds = CGRect(x: 0, y: 0, width: 430, height: 932)
        let rect = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: screenBounds,
            timelineTop: nil
        )

        XCTAssertEqual(
            screenBounds.maxY - rect.maxY,
            MapLibreEdgePinGeometry.bottomTabBarTopInset
                + MapLibreEdgePinGeometry.timelineGap,
            accuracy: 0.001
        )
        XCTAssertEqual(rect.maxY, 820, accuracy: 0.001)
    }

    func testSafeAreaPinTransitionStartsAtPreviousScreenPosition() {
        let oldCenter = CGPoint(x: 394, y: 600)
        let newCenter = CGPoint(x: 394, y: 786)
        let translation = MapLibrePinTransitionGeometry.translation(
            from: oldCenter,
            to: newCenter
        )

        XCTAssertEqual(newCenter.x + translation.tx, oldCenter.x, accuracy: 0.001)
        XCTAssertEqual(newCenter.y + translation.ty, oldCenter.y, accuracy: 0.001)
        XCTAssertEqual(MapLibrePinTransitionGeometry.duration, 0.28, accuracy: 0.001)
        XCTAssertTrue(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: false,
            isEdgePinned: true
        ))
        XCTAssertTrue(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: true,
            isEdgePinned: false
        ))
        XCTAssertFalse(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: false,
            isEdgePinned: false
        ))
    }

    func testGooeyTransitionReasonAndPartitionGates() {
        let old = partition(generation: 1, [
            gooeySnapshot([1], frame: CGRect(x: 0, y: 0, width: 32, height: 32)),
            gooeySnapshot([2], frame: CGRect(x: 40, y: 0, width: 32, height: 32))
        ])
        let merged = partition(generation: 2, [
            gooeySnapshot([1, 2], frame: CGRect(x: 12, y: 0, width: 48, height: 32))
        ])

        for reason in [
            MapLibrePinPlacementUpdateReason.initial,
            .dataMutation,
            .selection
        ] {
            XCTAssertTrue(MapLibrePinGooeyTransitionResolver.transitions(
                previous: old,
                current: merged,
                reason: reason,
                hasPresentedInitialState: true
            ).isEmpty)
        }
        XCTAssertTrue(MapLibrePinGooeyTransitionResolver.transitions(
            previous: old,
            current: merged,
            reason: .viewport,
            hasPresentedInitialState: false
        ).isEmpty)

        let movedSamePartition = partition(generation: 3, [
            gooeySnapshot([1], frame: CGRect(x: 10, y: 10, width: 32, height: 32)),
            gooeySnapshot([2], frame: CGRect(x: 50, y: 10, width: 32, height: 32))
        ])
        XCTAssertTrue(MapLibrePinGooeyTransitionResolver.transitions(
            previous: old,
            current: movedSamePartition,
            reason: .safeArea,
            hasPresentedInitialState: true
        ).isEmpty)
    }

    func testGooeyResolverProducesStableNMemberMergeAndSplit() throws {
        let singles = partition(generation: 1, [
            gooeySnapshot([1], frame: CGRect(x: 0, y: 20, width: 32, height: 32)),
            gooeySnapshot([2], frame: CGRect(x: 38, y: 20, width: 32, height: 32)),
            gooeySnapshot([3], frame: CGRect(x: 76, y: 20, width: 32, height: 32))
        ])
        let group = partition(generation: 2, [
            gooeySnapshot([1, 2, 3], frame: CGRect(x: 28, y: 20, width: 68, height: 32))
        ])

        let merge = try XCTUnwrap(MapLibrePinGooeyTransitionResolver.transitions(
            previous: singles,
            current: group,
            reason: .viewport,
            hasPresentedInitialState: true
        ).first)
        XCTAssertEqual(merge.kind, .merge)
        XCTAssertEqual(merge.branches.count, 3)
        XCTAssertEqual(merge.key.orderedMemberIDs, [1, 2, 3].map(gooeyID))

        let split = try XCTUnwrap(MapLibrePinGooeyTransitionResolver.transitions(
            previous: group,
            current: singles,
            reason: .autoFocus,
            hasPresentedInitialState: true
        ).first)
        XCTAssertEqual(split.kind, .split)
        XCTAssertEqual(split.branches.count, 3)
        XCTAssertEqual(split.key, merge.key)
    }

    func testGooeyAccentRoleAndDescriptorHighlightPropagation() throws {
        let plainSingles = partition(generation: 1, [
            gooeySnapshot([1], frame: CGRect(x: 0, y: 0, width: 32, height: 32)),
            gooeySnapshot([2], frame: CGRect(x: 40, y: 0, width: 32, height: 32))
        ])
        let plainGroup = partition(generation: 2, [
            gooeySnapshot([1, 2], frame: CGRect(x: 20, y: 0, width: 56, height: 32))
        ])
        let plain = try XCTUnwrap(MapLibrePinGooeyTransitionResolver.transitions(
            previous: plainSingles,
            current: plainGroup,
            reason: .viewport,
            hasPresentedInitialState: true
        ).first)
        XCTAssertFalse(plain.showsAccent)
        XCTAssertEqual(MapLibrePinGooeyStyle.outerFillRole(showsAccent: plain.showsAccent), .white)

        let highlightedSingles = partition(generation: 3, [
            gooeySnapshot(
                [1],
                frame: CGRect(x: 0, y: 0, width: 32, height: 32),
                highlighted: true
            ),
            gooeySnapshot([2], frame: CGRect(x: 40, y: 0, width: 32, height: 32))
        ])
        let highlighted = try XCTUnwrap(MapLibrePinGooeyTransitionResolver.transitions(
            previous: highlightedSingles,
            current: plainGroup,
            reason: .viewport,
            hasPresentedInitialState: true
        ).first)
        XCTAssertTrue(highlighted.showsAccent)
        XCTAssertEqual(MapLibrePinGooeyStyle.outerFillRole(showsAccent: highlighted.showsAccent), .accent)
    }

    func testGooeyUpdateReasonPrioritizesSafeAreaOverSelection() {
        XCTAssertEqual(MapLibrePinPlacementUpdateReason.resolve(
            hasPresentedInitialState: false,
            pointsChanged: true,
            safeAreaChanged: true,
            selectionChanged: true
        ), .initial)
        XCTAssertEqual(MapLibrePinPlacementUpdateReason.resolve(
            hasPresentedInitialState: true,
            pointsChanged: true,
            safeAreaChanged: true,
            selectionChanged: true
        ), .dataMutation)

        let safeAreaAndSelection = MapLibrePinPlacementUpdateReason.resolve(
            hasPresentedInitialState: true,
            pointsChanged: false,
            safeAreaChanged: true,
            selectionChanged: true
        )
        XCTAssertEqual(safeAreaAndSelection, .safeArea)
        XCTAssertTrue(safeAreaAndSelection.allowsGooeyTransition)

        let selectionOnly = MapLibrePinPlacementUpdateReason.resolve(
            hasPresentedInitialState: true,
            pointsChanged: false,
            safeAreaChanged: false,
            selectionChanged: true
        )
        XCTAssertEqual(selectionOnly, .selection)
        XCTAssertFalse(selectionOnly.allowsGooeyTransition)
    }

    func testGooeyResolverRejectsCRUDAndManyToManyRepartition() {
        let old = partition(generation: 1, [
            gooeySnapshot([1, 2], frame: CGRect(x: 0, y: 0, width: 48, height: 32)),
            gooeySnapshot([3, 4], frame: CGRect(x: 50, y: 0, width: 48, height: 32))
        ])
        let manyToMany = partition(generation: 2, [
            gooeySnapshot([1, 3], frame: CGRect(x: 10, y: 0, width: 48, height: 32)),
            gooeySnapshot([2, 4], frame: CGRect(x: 60, y: 0, width: 48, height: 32))
        ])
        XCTAssertTrue(MapLibrePinGooeyTransitionResolver.transitions(
            previous: old,
            current: manyToMany,
            reason: .viewport,
            hasPresentedInitialState: true
        ).isEmpty)

        let inserted = partition(generation: 3, [
            gooeySnapshot([1, 2], frame: CGRect(x: 0, y: 0, width: 48, height: 32)),
            gooeySnapshot([3, 4], frame: CGRect(x: 50, y: 0, width: 48, height: 32)),
            gooeySnapshot([5], frame: CGRect(x: 110, y: 0, width: 32, height: 32))
        ])
        XCTAssertTrue(MapLibrePinGooeyTransitionResolver.transitions(
            previous: old,
            current: inserted,
            reason: .viewport,
            hasPresentedInitialState: true
        ).isEmpty)
    }

    func testGooeyMetaballIsFiniteAcrossEveryDirection() throws {
        let source = CGRect(x: 100, y: 100, width: 32, height: 32)
        for degrees in 0..<360 {
            let radians = CGFloat(degrees) * .pi / 180
            let target = CGRect(
                x: source.midX + cos(radians) * 80 - 24,
                y: source.midY + sin(radians) * 80 - 16,
                width: 48,
                height: 32
            )
            let descriptor = MapLibrePinGooeyTransitionDescriptor(
                key: MapLibrePinGooeyTransitionKey(orderedMemberIDs: [gooeyID(1), gooeyID(2)]),
                kind: .merge,
                branches: [MapLibrePinGooeyBranch(
                    orderedMemberIDs: [gooeyID(1)],
                    sourceFrame: source,
                    targetFrame: target,
                    sourcePointingCorner: nil,
                    targetPointingCorner: nil
                )],
                localBounds: source.union(target).insetBy(dx: -20, dy: -20),
                showsAccent: false
            )
            let sample = try XCTUnwrap(MapLibrePinMetaballPath.sample(
                descriptor: descriptor,
                progress: 0.5
            ))
            for bounds in [sample.outerPath.boundingBoxOfPath, sample.innerPath.boundingBoxOfPath] {
                XCTAssertTrue(MapLibrePinGooeyGeometry.isFinite(bounds), "failed at \(degrees)°")
                XCTAssertGreaterThan(bounds.width, 0)
                XCTAssertGreaterThan(bounds.height, 0)
            }
        }
    }

    func testGooeyMetaballEnforcesMaximumBridgeAndStableTopology() throws {
        let source = CGRect(x: 0, y: 0, width: 32, height: 32)
        let nearby = CGRect(x: 70, y: 20, width: 56, height: 32)
        let descriptor = MapLibrePinGooeyTransitionDescriptor(
            key: MapLibrePinGooeyTransitionKey(orderedMemberIDs: [gooeyID(1), gooeyID(2)]),
            kind: .merge,
            branches: [MapLibrePinGooeyBranch(
                orderedMemberIDs: [gooeyID(1)],
                sourceFrame: source,
                targetFrame: nearby,
                sourcePointingCorner: nil,
                targetPointingCorner: nil
            )],
            localBounds: source.union(nearby).insetBy(dx: -20, dy: -20),
            showsAccent: false
        )
        let start = try XCTUnwrap(MapLibrePinMetaballPath.sample(
            descriptor: descriptor,
            progress: 0
        ))
        let middle = try XCTUnwrap(MapLibrePinMetaballPath.sample(
            descriptor: descriptor,
            progress: 0.5
        ))
        XCTAssertEqual(pathElementCount(start.outerPath), pathElementCount(middle.outerPath))
        XCTAssertEqual(pathElementCount(start.innerPath), pathElementCount(middle.innerPath))
        XCTAssertNotEqual(start.outerPath, middle.outerPath)
        XCTAssertNotEqual(start.innerPath, middle.innerPath)

        let distant = CGRect(x: 200, y: 0, width: 32, height: 32)
        let tooLong = MapLibrePinGooeyTransitionDescriptor(
            key: descriptor.key,
            kind: .merge,
            branches: [MapLibrePinGooeyBranch(
                orderedMemberIDs: [gooeyID(1)],
                sourceFrame: source,
                targetFrame: distant,
                sourcePointingCorner: nil,
                targetPointingCorner: nil
            )],
            localBounds: source.union(distant).insetBy(dx: -20, dy: -20),
            showsAccent: false
        )
        XCTAssertGreaterThan(
            MapLibrePinGooeyGeometry.surfaceGap(from: source, to: distant),
            MapLibrePinGooeyGeometry.maximumBridgeLength
        )
        XCTAssertNil(MapLibrePinMetaballPath.sample(descriptor: tooLong, progress: 0.5))
    }

    func testGooeySurfaceGapUsesTwoDimensionalCapsuleCenterSegments() {
        let source = CGRect(x: 0, y: 0, width: 180, height: 32)
        let target = source.offsetBy(dx: 100, dy: 150)
        XCTAssertEqual(
            MapLibrePinGooeyGeometry.surfaceGap(from: source, to: target),
            118,
            accuracy: 0.001
        )

        let descriptor = MapLibrePinGooeyTransitionDescriptor(
            key: MapLibrePinGooeyTransitionKey(orderedMemberIDs: [gooeyID(1), gooeyID(2)]),
            kind: .merge,
            branches: [MapLibrePinGooeyBranch(
                orderedMemberIDs: [gooeyID(1)],
                sourceFrame: source,
                targetFrame: target,
                sourcePointingCorner: nil,
                targetPointingCorner: nil
            )],
            localBounds: source.union(target).insetBy(dx: -40, dy: -40),
            showsAccent: false
        )
        XCTAssertFalse(MapLibrePinGooeyGeometry.isRenderable(descriptor))
        XCTAssertNil(MapLibrePinMetaballPath.sample(descriptor: descriptor, progress: 0.5))
    }

    func testGooeyRetargetPolicyTranslatesRigidGeometryAndCancelsLayoutChanges() {
        let reference = [
            gooeySnapshot([1], frame: CGRect(x: 10, y: 20, width: 32, height: 32)),
            gooeySnapshot([2], frame: CGRect(x: 50, y: 20, width: 32, height: 32))
        ]
        XCTAssertEqual(
            MapLibrePinGooeyRetargetPolicy.decision(reference: reference, current: reference),
            .unchanged
        )

        let translated = reference.map { placement in
            MapLibrePinVisualSnapshot(
                representativeID: placement.representativeID,
                orderedMemberIDs: placement.orderedMemberIDs,
                numberFrame: placement.numberFrame.offsetBy(dx: 12, dy: -7),
                labelText: placement.labelText,
                isHighlighted: placement.isHighlighted,
                showsCategoryBubble: placement.showsCategoryBubble,
                pointingCorner: placement.pointingCorner
            )
        }
        XCTAssertEqual(
            MapLibrePinGooeyRetargetPolicy.decision(reference: reference, current: translated),
            .translate(MapLibrePinGooeyTranslation(dx: 12, dy: -7))
        )

        var differentialMove = translated
        differentialMove[1] = gooeySnapshot(
            [2],
            frame: reference[1].numberFrame.offsetBy(dx: 15, dy: -7)
        )
        XCTAssertEqual(
            MapLibrePinGooeyRetargetPolicy.decision(reference: reference, current: differentialMove),
            .cancel
        )

        var resized = translated
        resized[0] = gooeySnapshot(
            [1],
            frame: CGRect(x: 22, y: 13, width: 40, height: 32)
        )
        XCTAssertEqual(
            MapLibrePinGooeyRetargetPolicy.decision(reference: reference, current: resized),
            .cancel
        )
    }

    func testGooeyBoundsClipsToTimelineSafeRect() throws {
        let mapBounds = CGRect(x: 0, y: 0, width: 430, height: 932)
        let safeBounds = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: mapBounds,
            timelineTop: 700
        )
        let clipped = try XCTUnwrap(MapLibrePinGooeyBounds.clippedLocalBounds(
            CGRect(x: 10, y: 620, width: 420, height: 160),
            mapBounds: mapBounds,
            safeBounds: safeBounds
        ))
        XCTAssertEqual(clipped, CGRect(x: 20, y: 620, width: 390, height: 60))
        XCTAssertLessThanOrEqual(clipped.maxY, safeBounds.maxY)
        XCTAssertTrue(mapBounds.contains(clipped))
        XCTAssertTrue(safeBounds.contains(clipped))
    }

    func testGooeyFourPointingCornersRemainPresentAcrossMergeAndSplit() throws {
        let corners: [MapLibreEdgePinPointingCorner] = [
            .topLeft,
            .topRight,
            .bottomLeft,
            .bottomRight
        ]
        let progressValues: [CGFloat] = [0, 0.5, 1]
        let source = CGRect(x: 30, y: 30, width: 32, height: 32)
        let target = CGRect(x: 82, y: 54, width: 64, height: 32)

        for corner in corners {
            for kind in [MapLibrePinGooeyTransitionKind.merge, .split] {
                let branch = MapLibrePinGooeyBranch(
                    orderedMemberIDs: [gooeyID(1)],
                    sourceFrame: source,
                    targetFrame: target,
                    sourcePointingCorner: kind == .split ? corner : nil,
                    targetPointingCorner: kind == .merge ? corner : nil
                )
                let descriptor = MapLibrePinGooeyTransitionDescriptor(
                    key: MapLibrePinGooeyTransitionKey(
                        orderedMemberIDs: [gooeyID(1), gooeyID(2)]
                    ),
                    kind: kind,
                    branches: [branch],
                    localBounds: source.union(target).insetBy(dx: -40, dy: -40),
                    showsAccent: false
                )
                let samples = try progressValues.map { progress in
                    let radii = MapLibrePinMetaballPath.endpointCornerRadii(
                        branch: branch,
                        progress: progress
                    )
                    let pointedEndpoint = kind == .merge ? radii.target : radii.source
                    XCTAssertEqual(
                        pointedRadius(pointedEndpoint, at: corner),
                        0,
                        accuracy: 0.0001,
                        "\(kind) \(corner) lost its point at progress \(progress)"
                    )
                    return try XCTUnwrap(MapLibrePinMetaballPath.sample(
                        descriptor: descriptor,
                        progress: progress
                    ))
                }
                XCTAssertEqual(
                    Set(samples.map { pathElementCount($0.outerPath) }).count,
                    1,
                    "outer topology changed for \(kind) \(corner)"
                )
                XCTAssertEqual(
                    Set(samples.map { pathElementCount($0.innerPath) }).count,
                    1,
                    "inner topology changed for \(kind) \(corner)"
                )
            }
        }
    }

    func testGooeyCategoryIconSourcesAreSharedAndDeterministic() {
        XCTAssertEqual(MapLibrePinCategoryIcon.sources(symbolName: "fork.knife"), [
            .asset("icon-camera-outline"),
            .asset("icon-camera"),
            .asset("icon-landscape-outline"),
            .system("fork.knife")
        ])
    }

    func testGooeyLifecycleIgnoresStaleCompletionAndCapsConcurrency() throws {
        var state = MapLibrePinGooeyLifecycleState()
        let firstKey = MapLibrePinGooeyTransitionKey(orderedMemberIDs: [gooeyID(1)])
        let firstGeneration = try XCTUnwrap(state.begin(firstKey))
        let replacementGeneration = try XCTUnwrap(state.begin(firstKey))
        state.finish(firstKey, generation: firstGeneration)
        XCTAssertTrue(state.isCurrent(firstKey, generation: replacementGeneration))

        for suffix in 2...4 {
            XCTAssertNotNil(state.begin(MapLibrePinGooeyTransitionKey(
                orderedMemberIDs: [gooeyID(suffix)]
            )))
        }
        XCTAssertEqual(
            state.activeGenerations.count,
            MapLibrePinGooeyLifecycleState.maximumActiveComponents
        )
        XCTAssertNil(state.begin(MapLibrePinGooeyTransitionKey(
            orderedMemberIDs: [gooeyID(5)]
        )))
        state.cancel(firstKey)
        XCTAssertFalse(state.isCurrent(firstKey, generation: replacementGeneration))
        XCTAssertNotNil(state.begin(MapLibrePinGooeyTransitionKey(
            orderedMemberIDs: [gooeyID(5)]
        )))
        state.cancelAll()
        XCTAssertTrue(state.activeGenerations.isEmpty)
    }

    func testPointingCornerTransitionOnlySquaresTheDirectedCorner() {
        let rounded = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: nil,
            radius: 16
        )
        XCTAssertEqual(
            rounded,
            MapLibrePinCornerRadii(
                topLeft: 16,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 16
            )
        )

        let topLeft = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: .topLeft,
            radius: 16
        )
        XCTAssertEqual(
            topLeft,
            MapLibrePinCornerRadii(
                topLeft: 0,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 16
            )
        )

        let bottomRight = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: .bottomRight,
            radius: 16
        )
        XCTAssertEqual(
            bottomRight,
            MapLibrePinCornerRadii(
                topLeft: 16,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 0
            )
        )
    }

    func testAutoFocusZoomContinuesUntilMaximumZoom() {
        XCTAssertEqual(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 13.8,
                maximumZoom: 20
            )!,
            14.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 19.7,
                maximumZoom: 20
            )!,
            20,
            accuracy: 0.001
        )
        XCTAssertNil(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 20,
                maximumZoom: 20
            )
        )
    }

    func testEdgePinSafeRectRejectsInvalidHeightAndRespondsToResize() {
        let invalid = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 200
        )
        XCTAssertTrue(invalid.isNull)

        let portrait = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 822
        )
        let resized = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            timelineTop: 734
        )
        XCTAssertEqual(portrait.width, 390, accuracy: 0.001)
        XCTAssertEqual(resized.width, 350, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, 714, accuracy: 0.001)

        XCTAssertNotEqual(
            MapLibreEdgePinViewportGeometry(
                mapBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
                windowBounds: CGRect(x: 0, y: 0, width: 430, height: 932)
            ),
            MapLibreEdgePinViewportGeometry(
                mapBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                windowBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testEdgePinOuterFrameContainsLongLabelAndHighlightedPair() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        XCTAssertTrue(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 185, y: safeRect.minY + 16),
            labelSize: CGSize(width: 370, height: 32),
            topExtent: 16,
            bottomExtent: 16
        ))
        XCTAssertTrue(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 16, y: safeRect.minY + 50),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
        XCTAssertFalse(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 16, y: safeRect.minY + 49),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
    }

    func testEdgePinAttractionStartsOnlyAfterAnchorLeavesPhysicalScreen() {
        let screenBounds = CGRect(x: 0, y: 0, width: 430, height: 932)

        // These points have crossed the landing insets, but are still on the
        // physical screen and therefore must remain at their true positions.
        let insideLandingInsets = [
            CGPoint(x: 10, y: 466),
            CGPoint(x: 420, y: 466),
            CGPoint(x: 215, y: 150),
            CGPoint(x: 215, y: 850),
            CGPoint(x: 0, y: 466),
            CGPoint(x: 430, y: 466)
        ]
        for point in insideLandingInsets {
            XCTAssertFalse(MapLibreEdgePinTrigger.isOutsideScreen(
                point,
                screenBounds: screenBounds
            ))
        }

        let outsideScreen = [
            CGPoint(x: -0.1, y: 466),
            CGPoint(x: 430.1, y: 466),
            CGPoint(x: 215, y: -0.1),
            CGPoint(x: 215, y: 932.1)
        ]
        for point in outsideScreen {
            XCTAssertTrue(MapLibreEdgePinTrigger.isOutsideScreen(
                point,
                screenBounds: screenBounds
            ))
        }
    }

    func testOverflowProjectionIsNilWhileCompleteFrameFits() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let labelSize = CGSize(width: 32, height: 32)
        let fittingCenters = [
            CGPoint(x: 36, y: 496),
            CGPoint(x: 394, y: 496),
            CGPoint(x: 215, y: 206),
            CGPoint(x: 215, y: 786),
            CGPoint(x: safeRect.midX, y: safeRect.midY)
        ]

        for center in fittingCenters {
            XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
                safeRect: safeRect,
                numberCenter: center,
                labelSize: labelSize,
                topExtent: 16,
                bottomExtent: 16
            ))
        }
    }

    func testOverflowProjectionUsesSelectedAndLongLabelOuterExtents() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let selected = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.midX, y: 239),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
        XCTAssertEqual(selected.edge, .top)
        XCTAssertEqual(selected.point.y, 240, accuracy: 0.001)
        XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.midX, y: 240),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))

        let longLabelSize = CGSize(width: 200, height: 32)
        let longLabel = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 119, y: safeRect.midY),
            labelSize: longLabelSize,
            topExtent: 16,
            bottomExtent: 16
        ))
        XCTAssertEqual(longLabel.edge, .left)
        XCTAssertEqual(longLabel.point.x, 120, accuracy: 0.001)
        XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 120, y: safeRect.midY),
            labelSize: longLabelSize,
            topExtent: 16,
            bottomExtent: 16
        ))
    }

    func testEdgePinAttractionCornerChoiceIsStableAlongCenterRay() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        for center in [CGPoint(x: 35, y: 205), CGPoint(x: 35.1, y: 205.1)] {
            let projection = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
                safeRect: safeRect,
                numberCenter: center,
                labelSize: CGSize(width: 32, height: 32),
                topExtent: 16,
                bottomExtent: 16
            ))
            XCTAssertEqual(projection.edge, .left)
        }
    }

    func testRegularPinsMergeOnRenderedOverlapButNotExactTouch() {
        let first = regularMember(1, order: 0, center: CGPoint(x: 100, y: 300))
        let touching = regularMember(2, order: 1, center: CGPoint(x: 132, y: 300))
        let overlapping = regularMember(3, order: 1, center: CGPoint(x: 131, y: 300))

        XCTAssertEqual(
            MapLibreRegularPinGrouping.clusters(members: [first, touching]).count,
            2
        )
        let merged = MapLibreRegularPinGrouping.clusters(members: [first, overlapping])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].members.map(\.id), [first.id, overlapping.id])
        XCTAssertEqual(merged[0].labelText, "1.2")
    }

    func testRegularPinOverlapClosureIsTransitiveOrderedAndDeduplicated() {
        let first = regularMember(1, order: 0, center: CGPoint(x: 100, y: 300))
        let second = regularMember(2, order: 1, center: CGPoint(x: 131, y: 300))
        let third = regularMember(3, order: 2, center: CGPoint(x: 162, y: 300))

        let clusters = MapLibreRegularPinGrouping.clusters(
            members: [third, first, second, first]
        )

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].members.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(clusters[0].representativeID, first.id)
        XCTAssertEqual(clusters[0].labelText, "1.2.3")
    }

    func testWidenedRegularPillCreatesSecondaryCollisionClosure() {
        let first = regularMember(1, order: 9_999, center: CGPoint(x: 100, y: 300))
        let second = regularMember(2, order: 10_000, center: CGPoint(x: 131, y: 300))
        // This pin does not overlap either original 32-point circle, but it is
        // absorbed after the long merged number label widens the first group.
        let third = regularMember(3, order: 10_001, center: CGPoint(x: 164, y: 300))

        let clusters = MapLibreRegularPinGrouping.clusters(
            members: [first, second, third]
        )

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].members.map(\.id), [first.id, second.id, third.id])
    }

    func testHighlightedRegularPinMergesOnlyOnActualRenderedCollision() {
        let selected = regularMember(
            1,
            order: 0,
            center: CGPoint(x: 100, y: 300),
            highlighted: true
        )
        let overlapping = regularMember(2, order: 1, center: CGPoint(x: 131, y: 300))
        let separate = regularMember(3, order: 2, center: CGPoint(x: 220, y: 300))

        let collision = MapLibreRegularPinGrouping.clusters(members: [selected, overlapping])
        XCTAssertEqual(collision.count, 1)
        XCTAssertTrue(collision[0].isHighlighted)
        XCTAssertEqual(Set(collision[0].members.map(\.id)), Set([selected.id, overlapping.id]))
        XCTAssertEqual(collision[0].renderedFrame.height, 32, accuracy: 0.001)

        XCTAssertEqual(
            MapLibreRegularPinGrouping.clusters(members: [selected, separate]).count,
            2
        )
    }

    func testHighlightedRegularSingletonKeepsTrueNumericLabelSize() throws {
        let highlighted = regularMember(
            1,
            order: 0,
            center: CGPoint(x: 100, y: 300),
            highlighted: true
        )
        let cluster = try XCTUnwrap(
            MapLibreRegularPinGrouping.clusters(members: [highlighted]).first
        )

        XCTAssertEqual(cluster.labelSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(cluster.renderedFrame.height, 66, accuracy: 0.001)
    }

    func testBoundaryProjectionUsesPhysicalScreenCenterWhenSafeRectCenterDiffers() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 185, y: 460)
        XCTAssertNotEqual(screenCenter, CGPoint(x: safeRect.midX, y: safeRect.midY))
        let source = CGPoint(x: -200, y: 40)

        let projection = try XCTUnwrap(MapLibreEdgePinGeometry.boundaryProjection(
            safeRect: safeRect,
            numberCenter: source,
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))

        let sourceVector = CGPoint(x: source.x - screenCenter.x, y: source.y - screenCenter.y)
        let landingVector = CGPoint(
            x: projection.point.x - screenCenter.x,
            y: projection.point.y - screenCenter.y
        )
        XCTAssertEqual(
            sourceVector.x * landingVector.y - sourceVector.y * landingVector.x,
            0,
            accuracy: 0.001
        )
    }

    func testBoundaryProjectionUsesFarEdgeWhenScreenCenterIsBelowSafeRect() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 390, height: 100)
        let screenCenter = CGPoint(x: 215, y: 466)
        let labelSize = CGSize(width: 32, height: 32)

        let upward = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        XCTAssertEqual(upward.edge, .top)
        XCTAssertEqual(upward.point, CGPoint(x: 394, y: 176))

        let downward = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        XCTAssertEqual(downward.edge, .bottom)
        XCTAssertEqual(downward.point, CGPoint(x: 394, y: 244))
    }

    func testHorizontalEdgeLandingUsesOnlyEndpointSlotsAndSwitchesAtScreenCenter() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let labelSize = CGSize(width: 32, height: 32)
        let topLeft = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 214, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let topRight = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let bottomLeft = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 214, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let bottomRight = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))

        XCTAssertEqual(topLeft, .init(point: CGPoint(x: 36, y: 206), edge: .top))
        XCTAssertEqual(topRight, .init(point: CGPoint(x: 394, y: 206), edge: .top))
        XCTAssertEqual(bottomLeft, .init(point: CGPoint(x: 36, y: 786), edge: .bottom))
        XCTAssertEqual(bottomRight, .init(point: CGPoint(x: 394, y: 786), edge: .bottom))
        XCTAssertEqual(
            MapLibreEdgePinGeometry.pointingCorner(for: topLeft, safeRect: safeRect),
            .topLeft
        )
        XCTAssertEqual(
            MapLibreEdgePinGeometry.pointingCorner(for: bottomRight, safeRect: safeRect),
            .bottomRight
        )
    }

    func testTopPinJumpsBetweenSlotsAndMergesAtDestination() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let movingLeft = projectedMember(1, order: 0, degrees: -100, screenCenter: screenCenter)
        let existingRight = projectedMember(2, order: 1, degrees: -80, screenCenter: screenCenter)
        let before = MapLibreProjectedEdgePinGrouping.clusters(
            members: [movingLeft, existingRight],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before.compactMap(\.pointingCorner)), Set([.topLeft, .topRight]))

        let movingRight = projectedMember(1, order: 0, degrees: -79, screenCenter: screenCenter)
        let after = MapLibreProjectedEdgePinGrouping.clusters(
            members: [movingRight, existingRight],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: before.map { $0.members.map(\.id) }
        )

        let merged = try XCTUnwrap(after.first)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(Set(merged.members.map(\.id)), Set([movingRight.id, existingRight.id]))
        XCTAssertEqual(merged.pointingCorner, .topRight)
        XCTAssertEqual(merged.renderedFrame.maxX, safeRect.maxX, accuracy: 0.001)
    }

    func testProjectedEdgePositionDoesNotMoveWhenNonCollidingNeighborAppears() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let primary = projectedMember(1, order: 0, degrees: -90, screenCenter: screenCenter)
        let neighbor = projectedMember(2, order: 1, degrees: 0, screenCenter: screenCenter)

        let alone = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: [primary],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first)
        let withNeighbor = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: [primary, neighbor],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first(where: { $0.members.contains(where: { $0.id == primary.id }) }))

        XCTAssertEqual(alone.numberCenter.x, withNeighbor.numberCenter.x, accuracy: 0.001)
        XCTAssertEqual(alone.numberCenter.y, withNeighbor.numberCenter.y, accuracy: 0.001)
    }

    func testAnglePastSplitThresholdStillMergesWhenProjectedRectsOverlap() {
        let safeRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screenCenter = CGPoint(x: 100, y: 20)
        let first = projectedMember(1, order: 0, degrees: -135, screenCenter: screenCenter)
        let second = projectedMember(2, order: 1, degrees: -100, screenCenter: screenCenter)

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [first, second],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: [[first.id, second.id]]
        )

        XCTAssertGreaterThan(
            MapLibreEdgePinGrouping.circularAngularDistance(-135 * .pi / 180, -100 * .pi / 180),
            MapLibreEdgePinGrouping.splitAngle
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].members.map(\.id)), Set([first.id, second.id]))
    }

    func testEdgeSplitOutputRectsDoNotOverlap() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 496)
        let first = projectedMember(1, order: 0, degrees: -110, screenCenter: screenCenter)
        let second = projectedMember(2, order: 1, degrees: -70, screenCenter: screenCenter)

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [first, second],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: [[first.id, second.id]]
        )

        XCTAssertEqual(clusters.count, 2)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testMergedEdgeAnchorUsesCircularMeanRayAndOwnLabelBoundary() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 230)
        let members = [
            projectedMember(1, order: 0, degrees: -120, screenCenter: screenCenter),
            projectedMember(2, order: 1, degrees: -110, screenCenter: screenCenter),
            projectedMember(3, order: 2, degrees: -100, screenCenter: screenCenter)
        ]

        let cluster = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first)

        XCTAssertEqual(cluster.members.count, 3)
        XCTAssertEqual(cluster.pointingCorner, .topLeft)
        XCTAssertEqual(cluster.renderedFrame.minX, safeRect.minX, accuracy: 0.001)
        XCTAssertEqual(cluster.renderedFrame.minY, safeRect.minY, accuracy: 0.001)
    }

    func testProjectedEdgeCollisionClosurePreservesEveryMemberAndNoFramesOverlap() {
        let safeRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screenCenter = CGPoint(x: 100, y: 20)
        let members = [-140, -110, -90, -70, -40].enumerated().map {
            projectedMember($0.offset + 1, order: $0.offset, degrees: CGFloat($0.element), screenCenter: screenCenter)
        }

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        XCTAssertEqual(Set(clusters.flatMap { $0.members.map(\.id) }), Set(members.map(\.id)))
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testOversizedEndpointGroupCompactsLabelWithoutLosingMembers() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 100, height: 300)
        let screenCenter = CGPoint(x: 70, y: 300)
        let members = (0..<30).map { offset in
            projectedMember(
                offset + 1,
                order: 100_000 + offset,
                degrees: -110,
                screenCenter: screenCenter
            )
        }

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(cluster.members.map(\.id)), Set(members.map(\.id)))
        XCTAssertLessThanOrEqual(cluster.labelSize.width, safeRect.width)
        XCTAssertEqual(cluster.renderedFrame.minX, safeRect.minX, accuracy: 0.001)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testHighlightedEdgePinCollisionMergesButNoncollisionStaysIndependent() {
        let compactRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        // Keep the physical center inside the highlighted pin's taller
        // center-safe rect while remaining close enough to the top boundary
        // that these angularly separate rays still render on top of each other.
        let compactCenter = CGPoint(x: 100, y: 55)
        let selected = projectedMember(
            1,
            order: 0,
            degrees: -135,
            screenCenter: compactCenter,
            highlighted: true
        )
        let overlapping = projectedMember(2, order: 1, degrees: -100, screenCenter: compactCenter)
        let collision = MapLibreProjectedEdgePinGrouping.clusters(
            members: [selected, overlapping],
            safeRect: compactRect,
            screenCenter: compactCenter,
            previousGroups: []
        )
        XCTAssertEqual(collision.count, 1)
        XCTAssertEqual(Set(collision[0].members.map(\.id)), Set([selected.id, overlapping.id]))
        XCTAssertTrue(collision[0].containsHighlighted)
        XCTAssertFalse(collision[0].rendersHighlighted)
        XCTAssertEqual(collision[0].renderedFrame.height, 32, accuracy: 0.001)

        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let separatedSelected = projectedMember(
            3,
            order: 0,
            degrees: -90,
            screenCenter: screenCenter,
            highlighted: true
        )
        let separatedRegular = projectedMember(4, order: 1, degrees: 0, screenCenter: screenCenter)
        XCTAssertEqual(MapLibreProjectedEdgePinGrouping.clusters(
            members: [separatedSelected, separatedRegular],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).count, 2)
    }

    func testHighlightedEdgePinDegradesToCompactWithoutLosingMemberWhenHeightIsTight() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 390, height: 50)
        let screenCenter = CGPoint(x: 215, y: 466)
        let highlighted = projectedMember(
            1,
            order: 0,
            degrees: -90,
            screenCenter: screenCenter,
            highlighted: true
        )

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [highlighted],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(cluster.members.map(\.id), [highlighted.id])
        XCTAssertTrue(cluster.containsHighlighted)
        XCTAssertFalse(cluster.rendersHighlighted)
        XCTAssertEqual(cluster.renderedFrame.height, 32, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(cluster.renderedFrame.minY, safeRect.minY - 0.001)
        XCTAssertLessThanOrEqual(cluster.renderedFrame.maxY, safeRect.maxY + 0.001)
    }

    func testRegularEdgeSeamPromotesToFixedPointWithoutFinalOverlap() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let seamRegular = regularMember(1, order: 0, center: CGPoint(x: 379, y: 221))
        let farRegular = regularMember(3, order: 2, center: CGPoint(x: 320, y: 500))
        let initialEdge = projectedMember(2, order: 1, degrees: -90, screenCenter: screenCenter)
        let allMembers = [
            MapLibreProjectedEdgePinMember(
                id: seamRegular.id,
                displayOrder: seamRegular.displayOrder,
                sourcePoint: seamRegular.numberCenter,
                isHighlighted: false
            ),
            initialEdge,
            MapLibreProjectedEdgePinMember(
                id: farRegular.id,
                displayOrder: farRegular.displayOrder,
                sourcePoint: farRegular.numberCenter,
                isHighlighted: false
            )
        ]

        let resolved = MapLibreFinalPinGrouping.resolve(
            regularClusters: MapLibreRegularPinGrouping.clusters(
                members: [seamRegular, farRegular]
            ),
            initialEdgeMemberIDs: [initialEdge.id],
            allEdgeMembers: allMembers,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousEdgeGroups: []
        )

        XCTAssertEqual(resolved.regular.map(\.representativeID), [farRegular.id])
        XCTAssertEqual(resolved.edge.count, 1)
        XCTAssertEqual(
            Set(resolved.edge[0].members.map(\.id)),
            Set([seamRegular.id, initialEdge.id])
        )
        let finalFrames = resolved.regular.map(\.renderedFrame) + resolved.edge.map(\.renderedFrame)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(finalFrames))
        XCTAssertEqual(
            Set(resolved.regular.flatMap { $0.members.map(\.id) }
                + resolved.edge.flatMap { $0.members.map(\.id) }),
            Set([seamRegular.id, initialEdge.id, farRegular.id])
        )
    }

    func testEdgePinGroupingUsesWrapSafeAngularDistance() {
        let members = [
            edgeMember(1, order: 0, degrees: 179, position: 20),
            edgeMember(2, order: 1, degrees: -179, position: 30)
        ]

        let groups = MapLibreEdgePinGrouping.groups(members: members, previousGroups: [])

        XCTAssertEqual(groups.map(\.mapID), [[members[0].id, members[1].id]])
        XCTAssertEqual(
            MapLibreEdgePinGrouping.circularAngularDistance(
                members[0].directionAngle,
                members[1].directionAngle
            ),
            2 * .pi / 180,
            accuracy: 0.0001
        )
    }

    func testEdgePinGroupingUsesCompleteLinkInsteadOfNeighborChain() {
        let members = [
            edgeMember(1, order: 0, degrees: 0, position: 0),
            edgeMember(2, order: 1, degrees: 20, position: 20),
            edgeMember(3, order: 2, degrees: 40, position: 40)
        ]

        let groups = MapLibreEdgePinGrouping.groups(members: members, previousGroups: [])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.flatMap(\.mapID)), Set(members.map(\.id)))
    }

    func testEdgePinGroupingAppliesMergeAndSplitHysteresis() {
        let members = [
            edgeMember(1, order: 0, degrees: 0, position: 0),
            edgeMember(2, order: 1, degrees: 27, position: 50)
        ]

        XCTAssertEqual(
            MapLibreEdgePinGrouping.groups(members: members, previousGroups: []).count,
            2
        )
        XCTAssertEqual(
            MapLibreEdgePinGrouping.groups(
                members: members,
                previousGroups: [members.map(\.id)]
            ).count,
            1
        )
    }

    func testEdgePinGroupingDetachesFortyFiveDegreeOutlierWithoutLosingOrder() {
        let members = [
            edgeMember(2, order: 0, degrees: -136, position: 10),
            edgeMember(3, order: 1, degrees: -135, position: 16),
            edgeMember(6, order: 2, degrees: -134, position: 22),
            edgeMember(4, order: 3, degrees: -90, position: 25),
            edgeMember(1, order: 4, degrees: -133, position: 30)
        ]
        let previous = [members.map(\.id)]

        let groups = MapLibreEdgePinGrouping.groups(
            members: members,
            previousGroups: previous
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0.mapID == [members[0].id, members[1].id, members[2].id, members[4].id] })
        XCTAssertTrue(groups.contains { $0.mapID == [members[3].id] })
        XCTAssertEqual(Set(groups.flatMap(\.mapID)), Set(members.map(\.id)))
    }

    func testHighlightedEdgePinAndDifferentEdgesStaySeparate() {
        let members = [
            edgeMember(1, order: 0, degrees: 1, position: 10),
            edgeMember(2, order: 1, degrees: 2, position: 12, highlighted: true),
            edgeMember(3, order: 2, degrees: 3, position: 14, edge: .left)
        ]

        let groups = MapLibreEdgePinGrouping.groups(
            members: members,
            previousGroups: [members.map(\.id)]
        )

        XCTAssertEqual(groups.count, 3)
    }

    func testMainlandAppleCoordinateIsNormalizedForMapLibre() {
        let appleCoordinate = CLLocationCoordinate2D(
            latitude: 27.8250397,
            longitude: 99.7036914
        )

        let displayCoordinate = MapLibreCoordinateTransform.displayCoordinate(for: appleCoordinate)

        XCTAssertEqual(displayCoordinate.latitude, 27.8285362177, accuracy: 0.0000001)
        XCTAssertEqual(displayCoordinate.longitude, 99.7025975337, accuracy: 0.0000001)
    }

    func testCoordinatesOutsideMainlandChinaAreNotChangedForMapLibre() {
        let overseasCoordinates = [
            CLLocationCoordinate2D(latitude: -7.25747, longitude: 112.75209),
            CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
            CLLocationCoordinate2D(latitude: 34.6937, longitude: 135.5023),
            CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        ]

        for coordinate in overseasCoordinates {
            let displayCoordinate = MapLibreCoordinateTransform.displayCoordinate(for: coordinate)

            XCTAssertEqual(displayCoordinate.latitude, coordinate.latitude, accuracy: 0.0000001)
            XCTAssertEqual(displayCoordinate.longitude, coordinate.longitude, accuracy: 0.0000001)
        }
    }

    func testRouteCacheEntryExpiresAfterFifteenMinutes() {
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let entry = CachedRouteEstimate(estimate: estimate, cachedAt: cachedAt)

        XCTAssertTrue(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge - 1)))
        XCTAssertFalse(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge)))
    }

    func testRouteModeUsesAppleMapsDirectionValues() {
        XCTAssertEqual(RouteMode.driving.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeDriving")
        XCTAssertEqual(RouteMode.walking.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeWalking")
        XCTAssertEqual(RouteMode.transit.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeTransit")
    }

    @MainActor
    func testExpiredCacheCanBeReadOnlyAsNetworkFallback() throws {
        let container = try ModelContainer(for: Schema([RouteCacheRecord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cache = RouteCache(modelContext: container.mainContext)
        let origin = RoutePoint(latitude: 39.9, longitude: 116.3)
        let destination = RoutePoint(latitude: 39.8, longitude: 116.4)
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let staleAt = Date.now.addingTimeInterval(-RouteCache.maxAge)

        try cache.store(estimate, origin: origin, destination: destination, mode: .walking, cachedAt: staleAt)

        XCTAssertNil(cache.cached(origin: origin, destination: destination, mode: .walking))
        let fallback = try XCTUnwrap(cache.cached(origin: origin, destination: destination, mode: .walking, includeExpired: true)?.estimate)
        XCTAssertEqual(fallback.distanceMeters, estimate.distanceMeters)
        XCTAssertEqual(fallback.durationSeconds, estimate.durationSeconds)
        XCTAssertEqual(fallback.mode, estimate.mode)
        XCTAssertEqual(fallback.source, estimate.source)
    }

    @MainActor
    func testCardLegPreferenceDefaultsToDrivingAndPersistsAcrossLegs() throws {
        let container = try ModelContainer(for: Schema([CardLegPreference.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CardLegStore(modelContext: container.mainContext)
        let origin = TravelCardSnapshot(dayID: 1, kind: .activity, title: "故宫", startAt: .now)
        let destination = TravelCardSnapshot(dayID: 1, kind: .activity, title: "天坛", startAt: .now)
        let key = CardLegStore.legKey(origin: origin, destination: destination)

        XCTAssertEqual(store.mode(for: key), .driving)

        store.setMode(.transit, for: key)
        XCTAssertEqual(store.mode(for: key), .transit)

        store.setMode(.walking, for: key)
        XCTAssertEqual(store.mode(for: key), .walking)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CardLegPreference>()).count, 1)
    }
}

private extension Array where Element == MapLibreEdgePinGroupMember {
    var mapID: [UUID] { map(\.id) }
}
