import XCTest
@testable import MacWinCore

final class WindowGeometryRefreshTests: XCTestCase {
    func testFullScreenScreenChangeRefreshesOnceAfterExit() {
        var refresh = WindowGeometryRefresh()
        XCTAssertEqual(refresh.receive(.attachment, mode: .normal), .updateMinimum)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .fullScreen), .none)
        XCTAssertEqual(refresh.receive(.screenChanged, mode: .fullScreen), .none)
        XCTAssertEqual(refresh.receive(.screenParametersChanged, mode: .fullScreen), .none)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .recoverReachableFrame)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .none)
    }

    func testInitiallyFullScreenOrZoomedDefersUntilNormalRestoration() {
        for mode in [WindowGeometryRefresh.Mode.fullScreen, .zoomed] {
            var refresh = WindowGeometryRefresh()
            XCTAssertEqual(refresh.receive(.attachment, mode: mode), .none)
            XCTAssertEqual(refresh.receive(.stateChanged, mode: mode), .none)
            XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .recoverReachableFrame)
        }
    }

    func testZoomRestoreUpdatesMinimumWithoutRefittingUnchangedDisplays() {
        var refresh = WindowGeometryRefresh()
        _ = refresh.receive(.attachment, mode: .normal)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .zoomed), .none)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .updateMinimum)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .none)
    }

    func testNormalResizeAndCrossDisplayDragDoNotRequestFrameRecovery() {
        var refresh = WindowGeometryRefresh()
        _ = refresh.receive(.attachment, mode: .normal)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal, isLiveResizing: true), .none)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .none)
        XCTAssertEqual(refresh.receive(.screenChanged, mode: .normal), .updateMinimum)
    }

    func testTopologyRecoveryWaitsForLiveResizeToEndAndRunsOnce() {
        var refresh = WindowGeometryRefresh()
        _ = refresh.receive(.attachment, mode: .normal)
        XCTAssertEqual(refresh.receive(.screenParametersChanged, mode: .normal, isLiveResizing: true), .none)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal, isLiveResizing: true), .none)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .recoverReachableFrame)
        XCTAssertEqual(refresh.receive(.stateChanged, mode: .normal), .none)
    }
}
