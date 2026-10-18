import XCTest
@testable import MacWinCore

final class CompactWindowGeometryTests: XCTestCase {
    func testScreenTransitionKeepsReachableStraddlingUserFrame() {
        let left = CGRect(x: -1280, y: 25, width: 1280, height: 775)
        let right = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = CGRect(x: -380, y: 160, width: 900, height: 620)
        XCTAssertEqual(CompactWindowGeometry.recoverDisconnectedFrame(frame, screens: [left, right], fallback: right), frame)
    }

    func testTopologyChangeRecoversWindowWhoseTitlebarIsNoLongerReachable() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = CGRect(x: 200, y: 870, width: 800, height: 600)
        let repaired = CompactWindowGeometry.recoverDisconnectedFrame(frame, screens: [screen], fallback: screen)
        XCTAssertEqual(repaired.size, frame.size)
        XCTAssertTrue(screen.insetBy(dx: 24, dy: 24).contains(repaired))
    }

    func testTopologyChangeKeepsPartiallyOffscreenWindowWithReachableTitlebar() {
        let screen = CGRect(x: -1280, y: 25, width: 1280, height: 775)
        let frame = CGRect(x: -1600, y: 150, width: 900, height: 600)
        XCTAssertEqual(CompactWindowGeometry.recoverDisconnectedFrame(frame, screens: [screen], fallback: screen), frame)
    }

    func testSavedSmallFrameAndMinimumRemainSmallOnLargeScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let saved = CGRect(x: 100, y: 100, width: 640, height: 400)
        XCTAssertEqual(CompactWindowGeometry.fittedFrame(saved, screens: [screen], fallback: screen), saved)
        XCTAssertEqual(CompactWindowGeometry.minimumContentSize(
            nominal: CGSize(width: 960, height: 620), available: screen.size, current: saved.size
        ), saved.size)
        XCTAssertEqual(CompactWindowGeometry.fittedFrame(saved, screens: [screen], fallback: screen), saved)
    }
    func testNegativeMonitorPreservesSavedFrame() {
        let primary = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let secondary = CGRect(x: -1280, y: 100, width: 1280, height: 760)
        let saved = CGRect(x: -1200, y: 130, width: 640, height: 400)
        XCTAssertEqual(CompactWindowGeometry.fittedFrame(saved, screens: [primary, secondary], fallback: primary), saved)
    }
    func testRemovedMonitorMovesWithoutDiscardingSize() {
        let primary = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let saved = CGRect(x: -1200, y: 130, width: 640, height: 400)
        let corrected = CompactWindowGeometry.fittedFrame(saved, screens: [primary], fallback: primary)
        XCTAssertEqual(corrected.size, saved.size)
        XCTAssertTrue(primary.insetBy(dx: 24, dy: 24).contains(corrected))
    }
    func testOversizedFrameAndMinimumFitSmallScreen() {
        let screen = CGRect(x: -800, y: 20, width: 800, height: 560)
        let saved = CGRect(x: -790, y: 25, width: 1500, height: 900)
        let corrected = CompactWindowGeometry.fittedFrame(saved, screens: [screen], fallback: screen)
        XCTAssertTrue(screen.insetBy(dx: 24, dy: 24).contains(corrected))
        let minimum = CompactWindowGeometry.minimumContentSize(
            nominal: CGSize(width: 960, height: 620), available: corrected.size, current: corrected.size
        )
        XCTAssertEqual(minimum, corrected.size)
    }
}
