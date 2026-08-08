import CoreGraphics
import XCTest
@testable import TravelCompanion

final class GooeyPinDemoTests: XCTestCase {
    func testNormalizedPointClampsBothAxesAndRejectsNonFiniteValues() {
        XCTAssertEqual(
            GooeyPinNormalizedPoint(x: -2, y: 3).normalized(),
            GooeyPinNormalizedPoint(x: 0, y: 1)
        )
        XCTAssertEqual(
            GooeyPinNormalizedPoint(x: .nan, y: .infinity).normalized(),
            .center
        )
    }

    func testLayoutKeepsNormalPinsFixedHeightAndInsideEffectSafeContent() {
        let stageBounds = CGRect(x: 0, y: 0, width: 361, height: 280)
        let layout = makeLayout(
            stageSize: stageBounds.size,
            aggregatePosition: GooeyPinNormalizedPoint(x: 0, y: 0),
            singlePosition: GooeyPinNormalizedPoint(x: 1, y: 1),
            aggregateWidth: 180,
            effectPadding: 44
        )

        XCTAssertEqual(layout.aggregateFrame.height, 32)
        XCTAssertEqual(layout.singleFrame.height, 32)
        XCTAssertEqual(layout.singleFrame.width, 32)
        XCTAssertEqual(layout.aggregateFrame.width, 180)
        XCTAssertTrue(layout.contentFrame.contains(layout.aggregateFrame))
        XCTAssertTrue(layout.contentFrame.contains(layout.singleFrame))
        XCTAssertTrue(stageBounds.contains(layout.contentFrame))
    }

    func testFirstPlacementObservationDoesNotCompensatePositions() {
        let layout = makeLayout()
        let result = GooeyPinBoundsReconciler.reconcile(
            previous: nil,
            current: layout.placement
        )

        XCTAssertNil(result.aggregatePosition)
        XCTAssertNil(result.singlePosition)
        XCTAssertEqual(result.rememberedPlacement, layout.placement)
    }

    func testAggregateWidthChangePreservesOldPhysicalCenterWhenStillLegal() throws {
        let oldLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0.2, y: 0.35),
            aggregateWidth: 48,
            effectPadding: 24
        )
        let remappedLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0.2, y: 0.35),
            aggregateWidth: 180,
            effectPadding: 24
        )
        XCTAssertNotEqual(oldLayout.aggregateFrame.midX, remappedLayout.aggregateFrame.midX)
        XCTAssertTrue(
            remappedLayout.aggregateCenterBounds.contains(
                CGPoint(x: oldLayout.aggregateFrame.midX, y: oldLayout.aggregateFrame.midY)
            )
        )

        let reconciliation = GooeyPinBoundsReconciler.reconcile(
            previous: oldLayout.placement,
            current: remappedLayout.placement
        )
        let correctedLayout = makeLayout(
            aggregatePosition: try XCTUnwrap(reconciliation.aggregatePosition),
            singlePosition: GooeyPinDemoState.standard.singlePosition,
            aggregateWidth: 180,
            effectPadding: 24
        )

        XCTAssertEqual(correctedLayout.aggregateFrame.midX, oldLayout.aggregateFrame.midX, accuracy: 0.001)
        XCTAssertEqual(correctedLayout.aggregateFrame.midY, oldLayout.aggregateFrame.midY, accuracy: 0.001)
        XCTAssertNil(reconciliation.singlePosition)
    }

    func testBlurPaddingChangePreservesBothOldCentersWhenStillLegal() throws {
        let aggregatePosition = GooeyPinNormalizedPoint(x: 0.32, y: 0.4)
        let singlePosition = GooeyPinNormalizedPoint(x: 0.68, y: 0.6)
        let oldLayout = makeLayout(
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition,
            effectPadding: 24
        )
        let remappedLayout = makeLayout(
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition,
            effectPadding: 64
        )
        let reconciliation = GooeyPinBoundsReconciler.reconcile(
            previous: oldLayout.placement,
            current: remappedLayout.placement
        )
        let correctedLayout = makeLayout(
            aggregatePosition: try XCTUnwrap(reconciliation.aggregatePosition),
            singlePosition: try XCTUnwrap(reconciliation.singlePosition),
            effectPadding: 64
        )

        XCTAssertEqual(correctedLayout.aggregateFrame.midX, oldLayout.aggregateFrame.midX, accuracy: 0.001)
        XCTAssertEqual(correctedLayout.aggregateFrame.midY, oldLayout.aggregateFrame.midY, accuracy: 0.001)
        XCTAssertEqual(correctedLayout.singleFrame.midX, oldLayout.singleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(correctedLayout.singleFrame.midY, oldLayout.singleFrame.midY, accuracy: 0.001)
    }

    func testBoundsShrinkClampsOnlyToNearestLegalEdges() throws {
        let oldLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0, y: 0),
            singlePosition: GooeyPinNormalizedPoint(x: 1, y: 1),
            aggregateWidth: 48,
            effectPadding: 12
        )
        let remappedLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0, y: 0),
            singlePosition: GooeyPinNormalizedPoint(x: 1, y: 1),
            aggregateWidth: 180,
            effectPadding: 64
        )
        let reconciliation = GooeyPinBoundsReconciler.reconcile(
            previous: oldLayout.placement,
            current: remappedLayout.placement
        )
        let correctedLayout = makeLayout(
            aggregatePosition: try XCTUnwrap(reconciliation.aggregatePosition),
            singlePosition: try XCTUnwrap(reconciliation.singlePosition),
            aggregateWidth: 180,
            effectPadding: 64
        )

        XCTAssertEqual(
            correctedLayout.aggregateFrame.midX,
            correctedLayout.aggregateCenterBounds.minX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            correctedLayout.aggregateFrame.midY,
            correctedLayout.aggregateCenterBounds.minY,
            accuracy: 0.001
        )
        XCTAssertEqual(
            correctedLayout.singleFrame.midX,
            correctedLayout.singleCenterBounds.maxX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            correctedLayout.singleFrame.midY,
            correctedLayout.singleCenterBounds.maxY,
            accuracy: 0.001
        )
    }

    func testConcentricMinimumWidthHitGeometryKeepsBothPinsDirectlyDraggable() {
        let layout = makeLayout(
            aggregatePosition: .center,
            singlePosition: .center,
            aggregateWidth: 48,
            effectPadding: 24
        )
        let hits = GooeyPinHitGeometry(layout: layout)
        let center = CGPoint(x: layout.aggregateFrame.midX, y: layout.aggregateFrame.midY)
        let leftVisibleEnd = CGPoint(x: layout.aggregateFrame.minX + 2, y: center.y)
        let rightVisibleEnd = CGPoint(x: layout.aggregateFrame.maxX - 2, y: center.y)

        XCTAssertEqual(hits.hitTarget(at: center), .single)
        XCTAssertEqual(hits.hitTarget(at: leftVisibleEnd), .aggregate)
        XCTAssertEqual(hits.hitTarget(at: rightVisibleEnd), .aggregate)
        XCTAssertEqual(hits.aggregateEndHandleFrames.count, 2)
        XCTAssertFalse(hits.aggregateEndHandleFrames[0].contains(center))
        XCTAssertFalse(hits.aggregateEndHandleFrames[1].contains(center))
    }

    func testLeftEndFusionPrioritizesSingleCenterAndKeepsOppositeAggregateEndDraggable() {
        let base = makeLayout(
            aggregatePosition: .center,
            singlePosition: .center,
            aggregateWidth: 112,
            effectPadding: 24
        )
        let singleCenter = CGPoint(x: base.aggregateFrame.minX, y: base.aggregateFrame.midY)
        let layout = layout(from: base, movingSingleCenterTo: singleCenter)
        let hits = GooeyPinHitGeometry(layout: layout)
        let exposedAggregateEnd = CGPoint(x: layout.aggregateFrame.maxX - 2, y: layout.aggregateFrame.midY)

        XCTAssertLessThan(layout.metrics.surfaceGap, 0)
        XCTAssertEqual(hits.hitTarget(at: singleCenter), .single)
        XCTAssertEqual(hits.hitTarget(at: exposedAggregateEnd), .aggregate)
    }

    func testRightEndFusionPrioritizesSingleCenterAndKeepsOppositeAggregateEndDraggable() {
        let base = makeLayout(
            aggregatePosition: .center,
            singlePosition: .center,
            aggregateWidth: 112,
            effectPadding: 24
        )
        let singleCenter = CGPoint(x: base.aggregateFrame.maxX, y: base.aggregateFrame.midY)
        let layout = layout(from: base, movingSingleCenterTo: singleCenter)
        let hits = GooeyPinHitGeometry(layout: layout)
        let exposedAggregateEnd = CGPoint(x: layout.aggregateFrame.minX + 2, y: layout.aggregateFrame.midY)

        XCTAssertLessThan(layout.metrics.surfaceGap, 0)
        XCTAssertEqual(hits.hitTarget(at: singleCenter), .single)
        XCTAssertEqual(hits.hitTarget(at: exposedAggregateEnd), .aggregate)
    }

    func testDiagonalFusionPrioritizesSingleCircleAndKeepsOppositeAggregateEndDraggable() {
        let base = makeLayout(
            aggregatePosition: .center,
            singlePosition: .center,
            aggregateWidth: 112,
            effectPadding: 24
        )
        let singleCenter = CGPoint(
            x: base.aggregateFrame.maxX - 8,
            y: base.aggregateFrame.midY - 14
        )
        let layout = layout(from: base, movingSingleCenterTo: singleCenter)
        let hits = GooeyPinHitGeometry(layout: layout)
        let exposedAggregateEnd = CGPoint(x: layout.aggregateFrame.minX + 2, y: layout.aggregateFrame.midY)

        XCTAssertLessThan(layout.metrics.surfaceGap, 0)
        XCTAssertEqual(hits.hitTarget(at: singleCenter), .single)
        XCTAssertEqual(hits.hitTarget(at: exposedAggregateEnd), .aggregate)
    }

    func testMaximumBlurAndShadowUseFullEffectSafePaddingWithoutLegacyCap() {
        var parameters = GooeyPinDemoParameters.standard
        parameters.blurRadius = 24
        parameters.shadowRadius = 24
        parameters.strokeWidth = 6
        let requestedPadding = GooeyPinEffectGeometry.safePadding(for: parameters)
        let stageBounds = CGRect(x: 0, y: 0, width: 361, height: 280)
        let layout = makeLayout(
            stageSize: stageBounds.size,
            aggregatePosition: GooeyPinNormalizedPoint(x: 0, y: 0),
            singlePosition: GooeyPinNormalizedPoint(x: 1, y: 1),
            aggregateWidth: 180,
            effectPadding: requestedPadding
        )

        XCTAssertEqual(GooeyPinEffectGeometry.shadowOffset(for: 24), 8)
        XCTAssertEqual(requestedPadding, 64)
        XCTAssertEqual(layout.effectPadding, 64)
        XCTAssertGreaterThan(layout.effectPadding, 44)
        XCTAssertGreaterThanOrEqual(layout.aggregateFrame.minX, requestedPadding)
        XCTAssertGreaterThanOrEqual(layout.aggregateFrame.minY, requestedPadding)
        XCTAssertLessThanOrEqual(layout.singleFrame.maxX, stageBounds.maxX - requestedPadding)
        XCTAssertLessThanOrEqual(layout.singleFrame.maxY, stageBounds.maxY - requestedPadding)
    }

    func testTinyStageCapsRequestedEffectPaddingOnlyAtGeometricLimit() {
        let layout = makeLayout(
            stageSize: CGSize(width: 50, height: 50),
            aggregatePosition: .center,
            singlePosition: .center,
            aggregateWidth: 180,
            effectPadding: 64
        )

        XCTAssertEqual(layout.effectPadding, 9)
        XCTAssertEqual(layout.aggregateFrame.height, 32)
        XCTAssertTrue(layout.contentFrame.contains(layout.aggregateFrame))
        XCTAssertTrue(layout.contentFrame.contains(layout.singleFrame))
    }

    func testRepresentativeEightAnglesAreCorrect() {
        for angle in stride(from: 0, to: 360, by: 45) {
            let metrics = metrics(atDegrees: CGFloat(angle))
            XCTAssertEqual(metrics.angleDegrees, CGFloat(angle), accuracy: 0.0001)
            XCTAssertTrue(metrics.hasDistinctCenters)
        }
    }

    func testEveryWholeDegreeFromZeroThrough359IsFiniteAndNormalized() {
        for angle in 0...359 {
            let metrics = metrics(atDegrees: CGFloat(angle))
            XCTAssertTrue(metrics.angleDegrees.isFinite, "Non-finite angle at \(angle)°")
            XCTAssertGreaterThanOrEqual(metrics.angleDegrees, 0)
            XCTAssertLessThan(metrics.angleDegrees, 360)
            XCTAssertEqual(metrics.angleDegrees, CGFloat(angle), accuracy: 0.0001)
            XCTAssertTrue(metrics.surfaceGap.isFinite)
        }
    }

    func testAngleCrossesZeroWithoutChangingDirectionQuadrant() {
        let before = metrics(atDegrees: 359).direction
        let after = metrics(atDegrees: 1).direction

        XCTAssertGreaterThan(before.dx, 0)
        XCTAssertLessThan(before.dy, 0)
        XCTAssertGreaterThan(after.dx, 0)
        XCTAssertGreaterThan(after.dy, 0)
        XCTAssertEqual(hypot(before.dx, before.dy), 1, accuracy: 0.0001)
        XCTAssertEqual(hypot(after.dx, after.dy), 1, accuracy: 0.0001)
    }

    func testCoincidentCentersUseFiniteLastDirectionFallback() {
        let aggregate = CGRect(x: 44, y: 84, width: 112, height: 32)
        let single = CGRect(x: 84, y: 84, width: 32, height: 32)
        let metrics = GooeyPinDemoGeometry.spatialMetrics(
            aggregateFrame: aggregate,
            singleFrame: single,
            fallbackDirection: CGVector(dx: 0, dy: -7)
        )

        XCTAssertFalse(metrics.hasDistinctCenters)
        XCTAssertEqual(metrics.angleDegrees, 270, accuracy: 0.0001)
        XCTAssertEqual(metrics.direction.dx, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.direction.dy, -1, accuracy: 0.0001)
        XCTAssertTrue(metrics.surfaceGap.isFinite)
    }

    func testInvalidCoincidentFallbackDefaultsToRight() {
        let aggregate = CGRect(x: 44, y: 84, width: 112, height: 32)
        let single = CGRect(x: 84, y: 84, width: 32, height: 32)
        let metrics = GooeyPinDemoGeometry.spatialMetrics(
            aggregateFrame: aggregate,
            singleFrame: single,
            fallbackDirection: CGVector(dx: CGFloat.nan, dy: CGFloat.infinity)
        )

        XCTAssertEqual(metrics.angleDegrees, 0)
        XCTAssertEqual(metrics.direction.dx, 1)
        XCTAssertEqual(metrics.direction.dy, 0)
    }

    func testSignedSurfaceGapUsesNearestPointOnHorizontalCapsuleCenterLine() {
        let aggregate = CGRect(x: 0, y: 0, width: 112, height: 32)

        XCTAssertEqual(
            surfaceGap(aggregate: aggregate, singleCenter: CGPoint(x: 128 + 20, y: 16)),
            20,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            surfaceGap(aggregate: aggregate, singleCenter: CGPoint(x: 56, y: 16 + 32 + 20)),
            20,
            accuracy: 0.0001
        )

        let diagonalCenter = CGPoint(x: 120, y: 52)
        let expected = hypot(diagonalCenter.x - 96, diagonalCenter.y - 16) - 32
        XCTAssertEqual(
            surfaceGap(aggregate: aggregate, singleCenter: diagonalCenter),
            expected,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            surfaceGap(aggregate: aggregate, singleCenter: CGPoint(x: 56, y: 16)),
            -32,
            accuracy: 0.0001
        )
    }

    func testDraggingAggregateChangesBothAxesWithoutMovingSingle() {
        let layout = makeLayout()
        let state = GooeyPinDemoState.standard
        let moved = GooeyPinInteraction.dragging(
            state: state,
            pin: .aggregate,
            startPosition: state.aggregatePosition,
            translation: CGSize(width: 27, height: -19),
            layout: layout
        )

        XCTAssertGreaterThan(moved.aggregatePosition.x, state.aggregatePosition.x)
        XCTAssertLessThan(moved.aggregatePosition.y, state.aggregatePosition.y)
        XCTAssertEqual(moved.singlePosition, state.singlePosition)
        XCTAssertEqual(moved.lastActivePin, .aggregate)
    }

    func testDraggingSingleChangesBothAxesWithoutMovingAggregate() {
        let layout = makeLayout()
        let state = GooeyPinDemoState.standard
        let moved = GooeyPinInteraction.dragging(
            state: state,
            pin: .single,
            startPosition: state.singlePosition,
            translation: CGSize(width: -31, height: 22),
            layout: layout
        )

        XCTAssertLessThan(moved.singlePosition.x, state.singlePosition.x)
        XCTAssertGreaterThan(moved.singlePosition.y, state.singlePosition.y)
        XCTAssertEqual(moved.aggregatePosition, state.aggregatePosition)
        XCTAssertEqual(moved.lastActivePin, .single)
    }

    func testDragUsesGestureStartInsteadOfAccumulatingTranslations() {
        let layout = makeLayout()
        let state = GooeyPinDemoState.standard
        let first = GooeyPinInteraction.dragging(
            state: state,
            pin: .single,
            startPosition: state.singlePosition,
            translation: CGSize(width: -10, height: 5),
            layout: layout
        )
        let second = GooeyPinInteraction.dragging(
            state: first,
            pin: .single,
            startPosition: state.singlePosition,
            translation: CGSize(width: -20, height: 10),
            layout: layout
        )
        let direct = GooeyPinInteraction.dragging(
            state: state,
            pin: .single,
            startPosition: state.singlePosition,
            translation: CGSize(width: -20, height: 10),
            layout: layout
        )

        XCTAssertEqual(second.singlePosition.x, direct.singlePosition.x, accuracy: 0.0001)
        XCTAssertEqual(second.singlePosition.y, direct.singlePosition.y, accuracy: 0.0001)
    }

    func testPhysicalDragAnchorDoesNotMoveWhenAggregateBoundsChange() {
        let initialLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0.2, y: 0.5),
            aggregateWidth: 48,
            effectPadding: 24
        )
        let changedLayout = makeLayout(
            aggregatePosition: GooeyPinNormalizedPoint(x: 0.2, y: 0.5),
            aggregateWidth: 180,
            effectPadding: 24
        )
        let startCenter = CGPoint(
            x: initialLayout.aggregateFrame.midX,
            y: initialLayout.aggregateFrame.midY
        )
        let translation = CGSize(width: 24, height: -12)

        let position = GooeyPinDemoGeometry.draggedPosition(
            startCenter: startCenter,
            translation: translation,
            pin: .aggregate,
            layout: changedLayout
        )
        let resultingCenter = GooeyPinDemoGeometry.center(
            for: position,
            in: changedLayout.aggregateCenterBounds
        )

        XCTAssertEqual(resultingCenter.x, startCenter.x + translation.width, accuracy: 0.0001)
        XCTAssertEqual(resultingCenter.y, startCenter.y + translation.height, accuracy: 0.0001)
    }

    func testNumberOrderUnlocksAfterAFormerlyFusedPinFullySeparates() {
        XCTAssertTrue(
            GooeyPinNumberOrderLock.updated(
                currentlyLocked: true,
                surfaceGap: 27.99,
                splitThreshold: 28
            )
        )
        XCTAssertFalse(
            GooeyPinNumberOrderLock.updated(
                currentlyLocked: true,
                surfaceGap: 28,
                splitThreshold: 28
            )
        )
        XCTAssertFalse(
            GooeyPinNumberOrderLock.updated(
                currentlyLocked: false,
                surfaceGap: 0,
                splitThreshold: 28
            )
        )
    }

    func testNormalDragEndKeepsExactLandingPositionsWithoutSnap() {
        let layout = makeLayout()
        let state = GooeyPinInteraction.dragging(
            state: .standard,
            pin: .single,
            startPosition: GooeyPinDemoState.standard.singlePosition,
            translation: CGSize(width: -37, height: 41),
            layout: layout
        )
        let ended = GooeyPinInteraction.endingDrag(state: state)

        XCTAssertEqual(ended.aggregatePosition, state.aggregatePosition)
        XCTAssertEqual(ended.singlePosition, state.singlePosition)
        XCTAssertEqual(ended.snapState, state.snapState)
    }

    func testDraggingEachPinClampsToItsOwnFourCorners() {
        let layout = makeLayout(aggregateWidth: 180, effectPadding: 44)
        for pin in [GooeyPinID.aggregate, .single] {
            let lower = GooeyPinDemoGeometry.draggedPosition(
                start: .center,
                translation: CGSize(width: -10_000, height: -10_000),
                pin: pin,
                layout: layout
            )
            let upper = GooeyPinDemoGeometry.draggedPosition(
                start: .center,
                translation: CGSize(width: 10_000, height: 10_000),
                pin: pin,
                layout: layout
            )
            XCTAssertEqual(lower, GooeyPinNormalizedPoint(x: 0, y: 0))
            XCTAssertEqual(upper, GooeyPinNormalizedPoint(x: 1, y: 1))
        }
    }

    func testExtremeWidthAndPaddingRemapBothPinsInsideStage() {
        let stageBounds = CGRect(x: 0, y: 0, width: 361, height: 280)
        let layout = makeLayout(
            stageSize: stageBounds.size,
            aggregatePosition: GooeyPinNormalizedPoint(x: 1, y: 1),
            singlePosition: GooeyPinNormalizedPoint(x: 0, y: 0),
            aggregateWidth: 180,
            effectPadding: 44
        )

        XCTAssertTrue(stageBounds.contains(layout.aggregateFrame))
        XCTAssertTrue(stageBounds.contains(layout.singleFrame))
        XCTAssertGreaterThanOrEqual(layout.aggregateFrame.minX, layout.effectPadding)
        XCTAssertGreaterThanOrEqual(layout.singleFrame.minY, layout.effectPadding)
        XCTAssertLessThanOrEqual(layout.aggregateFrame.maxY, stageBounds.maxY - layout.effectPadding)
        XCTAssertLessThanOrEqual(layout.singleFrame.maxX, stageBounds.maxX - layout.effectPadding)
    }

    func testTinyAndInvalidStagesProduceFiniteStableFrames() {
        for size in [
            CGSize(width: 8, height: 6),
            CGSize(width: 1, height: 100),
            CGSize(width: CGFloat.nan, height: CGFloat.infinity)
        ] {
            let layout = makeLayout(
                stageSize: size,
                aggregatePosition: GooeyPinNormalizedPoint(x: .nan, y: -.infinity),
                singlePosition: GooeyPinNormalizedPoint(x: .infinity, y: .nan),
                aggregateWidth: .infinity,
                effectPadding: .nan
            )
            XCTAssertTrue(layout.aggregateFrame.isFinite)
            XCTAssertTrue(layout.singleFrame.isFinite)
            XCTAssertTrue(layout.metrics.surfaceGap.isFinite)
            XCTAssertTrue(layout.metrics.angleDegrees.isFinite)
        }
    }

    func testAssistedSeparationPreservesAngleAndTargetsTrueSurfaceGapWhenUnclamped() {
        let initial = makeLayout(
            stageSize: CGSize(width: 700, height: 500),
            aggregatePosition: GooeyPinNormalizedPoint(x: 0.45, y: 0.45),
            singlePosition: GooeyPinNormalizedPoint(x: 0.58, y: 0.62),
            aggregateWidth: 112,
            effectPadding: 24
        )
        let target = GooeyPinDemoGeometry.assistedPosition(
            moving: .single,
            to: .separated,
            layout: initial,
            separationDistance: 84,
            fallbackDirection: CGVector(dx: 1, dy: 0)
        )
        let result = makeLayout(
            stageSize: initial.stageSize,
            aggregatePosition: GooeyPinDemoGeometry.normalizedPosition(
                for: CGPoint(x: initial.aggregateFrame.midX, y: initial.aggregateFrame.midY),
                in: initial.aggregateCenterBounds
            ),
            singlePosition: target,
            aggregateWidth: initial.aggregateFrame.width,
            effectPadding: initial.effectPadding,
            fallbackDirection: initial.metrics.direction
        )

        XCTAssertEqual(result.metrics.surfaceGap, 84, accuracy: 0.001)
        XCTAssertEqual(result.metrics.direction.dx, initial.metrics.direction.dx, accuracy: 0.001)
        XCTAssertEqual(result.metrics.direction.dy, initial.metrics.direction.dy, accuracy: 0.001)
    }

    func testSnapResolverUsesTrueSurfaceGapAndHysteresisBand() {
        XCTAssertEqual(
            GooeyPinSnapResolver.resolvedState(
                surfaceGap: 10,
                previous: .separated,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            .fused
        )
        XCTAssertEqual(
            GooeyPinSnapResolver.resolvedState(
                surfaceGap: 30,
                previous: .fused,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            .separated
        )
        XCTAssertEqual(
            GooeyPinSnapResolver.resolvedState(
                surfaceGap: 20,
                previous: .fused,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            .fused
        )
        XCTAssertEqual(
            GooeyPinSnapResolver.resolvedState(
                surfaceGap: 20,
                previous: .separated,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            .separated
        )
    }

    func testParametersNormalizeRangesAndMaintainThresholdBand() {
        let invalid = GooeyPinDemoParameters(
            aggregateWidth: 1_000,
            blurRadius: .nan,
            alphaThreshold: -1,
            sourceOpacity: 4,
            strokeWidth: -5,
            shadowRadius: .infinity,
            separationDistance: 500,
            mergeThreshold: 40,
            splitThreshold: 4,
            springResponse: 0,
            springDamping: 8
        ).normalized()

        XCTAssertEqual(invalid.aggregateWidth, 180)
        XCTAssertEqual(invalid.blurRadius, 10)
        XCTAssertEqual(invalid.alphaThreshold, 0.05)
        XCTAssertEqual(invalid.sourceOpacity, 1)
        XCTAssertEqual(invalid.strokeWidth, 0)
        XCTAssertEqual(invalid.shadowRadius, 10)
        XCTAssertEqual(invalid.separationDistance, 120)
        XCTAssertGreaterThanOrEqual(invalid.splitThreshold - invalid.mergeThreshold, 4)
        XCTAssertEqual(invalid.springResponse, 0.1)
        XCTAssertEqual(invalid.springDamping, 1)
    }

    func testRightEdgeNumberScenarioUsesSpatialOrderAndExtractsFour() {
        let scenario = GooeyPinNumberScenario.rightEdge

        XCTAssertEqual(scenario.orderedMembers.map(\.value), ["2", "3", "7", "5", "4"])
        XCTAssertEqual(scenario.remainingMembers.map(\.value), ["2", "3", "7", "5"])
        XCTAssertEqual(scenario.fusedText, "2.3.7.5.4")
        XCTAssertEqual(scenario.separatedAggregateText, "2.3.7.5")
        XCTAssertEqual(scenario.extractedMember.value, "4")
        XCTAssertGreaterThan(scenario.separationDirection.dx, 0)
        XCTAssertEqual(scenario.separationDirection.dy, 0, accuracy: 0.0001)
    }

    func testUpperLeftNumberScenarioUsesSpatialOrderAndExtractsThree() {
        let scenario = GooeyPinNumberScenario.upperLeft

        XCTAssertEqual(scenario.orderedMembers.map(\.value), ["7", "3", "8", "12"])
        XCTAssertEqual(scenario.remainingMembers.map(\.value), ["7", "8", "12"])
        XCTAssertEqual(scenario.fusedText, "7.3.8.12")
        XCTAssertEqual(scenario.separatedAggregateText, "7.8.12")
        XCTAssertEqual(scenario.extractedMember.value, "3")
        XCTAssertLessThan(scenario.separationDirection.dx, 0)
        XCTAssertLessThan(scenario.separationDirection.dy, 0)
    }

    func testNumberOrderingIsStableWhenInputMembersArriveInAnotherOrder() {
        let scenario = GooeyPinNumberScenario.upperLeft

        XCTAssertEqual(
            GooeyPinNumberOrdering.ordered(Array(scenario.members.reversed())).map(\.id),
            scenario.orderedMembers.map(\.id)
        )
    }

    func testFourMergingFromLeftBecomesFirstWithoutReorderingRemainingMembers() {
        var state = GooeyPinDemoState.standard

        state.updateNumberOrderForMerge(direction: CGVector(dx: -1, dy: 0))

        XCTAssertEqual(state.numberScenario.fusedText, "4.2.3.7.5")
        XCTAssertEqual(state.numberScenario.separatedAggregateText, "2.3.7.5")
        XCTAssertEqual(
            state.numberScenario.remainingMembers.map(\.id),
            GooeyPinNumberScenario.rightEdge.remainingMembers.map(\.id)
        )
    }

    func testFourMergingFromRightRemainsLast() {
        var state = GooeyPinDemoState.standard

        state.updateNumberOrderForMerge(direction: CGVector(dx: 1, dy: 0))

        XCTAssertEqual(state.numberScenario.fusedText, "2.3.7.5.4")
    }

    func testUpperLeftMergeDirectionKeepsThreeInItsSecondRelativeSlot() {
        var state = GooeyPinDemoState.standard
        state.applyNumberScenario(.upperLeft)

        state.updateNumberOrderForMerge(
            direction: GooeyPinNumberScenario.upperLeft.separationDirection
        )

        XCTAssertEqual(state.numberScenario.fusedText, "7.3.8.12")
        XCTAssertEqual(state.numberScenario.separatedAggregateText, "7.8.12")
    }

    func testNumberExtractionProgressIsContinuousAndClamped() {
        XCTAssertEqual(
            GooeyPinNumberLayout.extractionProgress(
                surfaceGap: 12,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            0
        )
        XCTAssertEqual(
            GooeyPinNumberLayout.extractionProgress(
                surfaceGap: 28,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            1
        )
        let before = GooeyPinNumberLayout.extractionProgress(
            surfaceGap: 19.99,
            mergeThreshold: 12,
            splitThreshold: 28
        )
        let after = GooeyPinNumberLayout.extractionProgress(
            surfaceGap: 20.01,
            mergeThreshold: 12,
            splitThreshold: 28
        )
        XCTAssertLessThan(abs(after - before), 0.01)
        XCTAssertEqual(
            GooeyPinNumberLayout.extractionProgress(
                surfaceGap: -1_000,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            0
        )
        XCTAssertEqual(
            GooeyPinNumberLayout.extractionProgress(
                surfaceGap: 1_000,
                mergeThreshold: 12,
                splitThreshold: 28
            ),
            1
        )
    }

    func testVisualNumberTransitionWaitsUntilTheGooeyBridgeIsCloseToVisible() {
        let parameters = GooeyPinDemoParameters.standard

        XCTAssertEqual(
            GooeyPinNumberLayout.visualExtractionProgress(
                surfaceGap: parameters.mergeThreshold,
                parameters: parameters
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GooeyPinNumberLayout.visualExtractionProgress(
                surfaceGap: 7.2,
                parameters: parameters
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GooeyPinNumberLayout.visualExtractionProgress(
                surfaceGap: 4.2,
                parameters: parameters
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GooeyPinNumberLayout.visualExtractionProgress(
                surfaceGap: 1.2,
                parameters: parameters
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testRightEdgeFourMovesFromLastAggregateSlotToSingleCenter() throws {
        let scenario = GooeyPinNumberScenario.rightEdge
        let layout = makeLayout()
        let fused = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 0
        )
        let separated = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 1
        )
        let fusedFour = try XCTUnwrap(fused.placement(for: scenario.extractedMemberID))
        let separatedFour = try XCTUnwrap(separated.placement(for: scenario.extractedMemberID))
        let otherFusedPositions = fused.memberPlacements
            .filter { $0.id != scenario.extractedMemberID }
            .map(\.position.x)

        XCTAssertGreaterThan(fusedFour.position.x, try XCTUnwrap(otherFusedPositions.max()))
        XCTAssertEqual(separatedFour.position.x, layout.singleFrame.midX, accuracy: 0.0001)
        XCTAssertEqual(separatedFour.position.y, layout.singleFrame.midY, accuracy: 0.0001)
        XCTAssertEqual(
            separated.memberPlacements.filter { $0.id != scenario.extractedMemberID }.map(\.value),
            ["2", "3", "7", "5"]
        )
    }

    func testUpperLeftThreeLeavesItsSecondSlotWithoutRemainingNumberJump() throws {
        let scenario = GooeyPinNumberScenario.upperLeft
        let layout = makeLayout(
            aggregatePosition: scenario.aggregatePosition,
            singlePosition: scenario.singlePosition
        )
        let fused = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 0
        )
        let justBefore = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 0.499
        )
        let justAfter = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 0.501
        )
        let separated = GooeyPinNumberLayout.presentation(
            scenario: scenario,
            layout: layout,
            extractionProgress: 1
        )
        let fusedValues = fused.memberPlacements.map(\.value)
        let fusedThree = try XCTUnwrap(fused.placement(for: scenario.extractedMemberID))

        XCTAssertEqual(fusedValues, ["7", "3", "8", "12"])
        XCTAssertGreaterThan(fusedThree.position.x, fused.memberPlacements[0].position.x)
        XCTAssertLessThan(fusedThree.position.x, fused.memberPlacements[2].position.x)
        XCTAssertEqual(
            separated.memberPlacements.filter { $0.id != scenario.extractedMemberID }.map(\.value),
            ["7", "8", "12"]
        )
        for member in scenario.remainingMembers {
            let before = try XCTUnwrap(justBefore.placement(for: member.id)).position
            let after = try XCTUnwrap(justAfter.placement(for: member.id)).position
            XCTAssertLessThan(hypot(after.x - before.x, after.y - before.y), 1)
        }
        let separatedThree = try XCTUnwrap(separated.placement(for: scenario.extractedMemberID))
        XCTAssertEqual(separatedThree.position.x, layout.singleFrame.midX, accuracy: 0.0001)
        XCTAssertEqual(separatedThree.position.y, layout.singleFrame.midY, accuracy: 0.0001)
    }

    func testApplyingNumberScenarioPreservesParametersAndUsesScenarioDirection() {
        var state = GooeyPinDemoState.standard
        state.parameters.aggregateWidth = 180

        state.applyNumberScenario(.upperLeft)

        XCTAssertEqual(state.numberScenarioID, .upperLeft)
        XCTAssertEqual(state.parameters.aggregateWidth, 180)
        XCTAssertEqual(state.aggregatePosition, GooeyPinNumberScenario.upperLeft.aggregatePosition)
        XCTAssertEqual(state.singlePosition, GooeyPinNumberScenario.upperLeft.singlePosition)
        XCTAssertEqual(state.lastDirection, GooeyPinNumberScenario.upperLeft.separationDirection)
        XCTAssertEqual(state.snapState, .separated)
    }

    func testDemoStateResetRestoresParametersPositionsDirectionAndState() {
        var state = GooeyPinDemoState.standard
        state.parameters.aggregateWidth = 180
        state.applyNumberScenario(.upperLeft)
        state.aggregatePosition = GooeyPinNormalizedPoint(x: 1, y: 0)
        state.singlePosition = GooeyPinNormalizedPoint(x: 0, y: 1)
        state.snapState = .fused
        state.lastDirection = CGVector(dx: 0, dy: -1)
        state.lastActivePin = .aggregate

        state.reset()

        XCTAssertEqual(state, .standard)
        XCTAssertEqual(state.parameters, .standard)
        XCTAssertEqual(state.numberScenarioID, .rightEdge)
        XCTAssertEqual(state.aggregatePosition, GooeyPinNormalizedPoint(x: 0.18, y: 0.5))
        XCTAssertEqual(state.singlePosition, GooeyPinNormalizedPoint(x: 0.82, y: 0.5))
        XCTAssertEqual(state.snapState, .separated)
        XCTAssertEqual(state.lastDirection, CGVector(dx: 1, dy: 0))
        XCTAssertEqual(state.lastActivePin, .single)
    }

    private func makeLayout(
        stageSize: CGSize = CGSize(width: 520, height: 280),
        aggregatePosition: GooeyPinNormalizedPoint = GooeyPinDemoState.standard.aggregatePosition,
        singlePosition: GooeyPinNormalizedPoint = GooeyPinDemoState.standard.singlePosition,
        aggregateWidth: CGFloat = GooeyPinDemoParameters.standard.aggregateWidth,
        effectPadding: CGFloat = 24,
        fallbackDirection: CGVector = CGVector(dx: 1, dy: 0)
    ) -> GooeyPinDemoLayout {
        GooeyPinDemoGeometry.layout(
            stageSize: stageSize,
            aggregatePosition: aggregatePosition,
            singlePosition: singlePosition,
            aggregateWidth: aggregateWidth,
            effectPadding: effectPadding,
            fallbackDirection: fallbackDirection
        )
    }

    private func metrics(atDegrees degrees: CGFloat) -> GooeyPinSpatialMetrics {
        let radians = degrees * .pi / 180
        let aggregate = CGRect(x: 44, y: 84, width: 112, height: 32)
        let center = CGPoint(x: aggregate.midX, y: aggregate.midY)
        let singleCenter = CGPoint(
            x: center.x + cos(radians) * 220,
            y: center.y + sin(radians) * 220
        )
        let single = CGRect(
            x: singleCenter.x - 16,
            y: singleCenter.y - 16,
            width: 32,
            height: 32
        )
        return GooeyPinDemoGeometry.spatialMetrics(
            aggregateFrame: aggregate,
            singleFrame: single,
            fallbackDirection: CGVector(dx: 1, dy: 0)
        )
    }

    private func layout(
        from base: GooeyPinDemoLayout,
        movingSingleCenterTo center: CGPoint
    ) -> GooeyPinDemoLayout {
        makeLayout(
            stageSize: base.stageSize,
            aggregatePosition: GooeyPinDemoGeometry.normalizedPosition(
                for: CGPoint(x: base.aggregateFrame.midX, y: base.aggregateFrame.midY),
                in: base.aggregateCenterBounds
            ),
            singlePosition: GooeyPinDemoGeometry.normalizedPosition(
                for: center,
                in: base.singleCenterBounds
            ),
            aggregateWidth: base.aggregateFrame.width,
            effectPadding: base.effectPadding,
            fallbackDirection: base.metrics.direction
        )
    }

    private func surfaceGap(aggregate: CGRect, singleCenter: CGPoint) -> CGFloat {
        let single = CGRect(
            x: singleCenter.x - 16,
            y: singleCenter.y - 16,
            width: 32,
            height: 32
        )
        return GooeyPinDemoGeometry.spatialMetrics(
            aggregateFrame: aggregate,
            singleFrame: single,
            fallbackDirection: CGVector(dx: 1, dy: 0)
        ).surfaceGap
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
    }
}
