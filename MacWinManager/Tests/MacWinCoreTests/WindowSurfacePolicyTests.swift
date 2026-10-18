import XCTest
@testable import MacWinCore

final class WindowSurfacePolicyTests: XCTestCase {
    func testAccessibilityOverridesOptInWithoutChangingPreference() {
        for enabled in [false, true] {
            for reduce in [false, true] {
                for contrast in [false, true] {
                    let policy = WindowSurfacePolicy(effectsEnabled: enabled, reduceTransparency: reduce, increaseContrast: contrast)
                    XCTAssertEqual(policy.usesMaterial, enabled && !reduce && !contrast)
                }
            }
        }
        XCTAssertFalse(policy(enabled: false).usesMaterial)
        XCTAssertTrue(policy(enabled: true).usesMaterial)
    }

    func testFullScreenAndZoomRemoveCornersAndShadow() {
        for fullScreen in [false, true] {
            for zoomed in [false, true] {
                let actual = policy(enabled: true, fullScreen: fullScreen, zoomed: zoomed)
                XCTAssertEqual(actual.cornerRadius, fullScreen || zoomed ? 0 : 12)
                XCTAssertEqual(actual.hasShadow, !fullScreen && !zoomed)
            }
        }
    }

    func testSolidFallbackStillHasClippedNormalWindowCorners() {
        let solid = policy(enabled: false)
        XCTAssertFalse(solid.usesMaterial)
        XCTAssertEqual(solid.cornerRadius, 12)
        XCTAssertTrue(solid.hasShadow)
    }

    private func policy(enabled: Bool, fullScreen: Bool = false, zoomed: Bool = false) -> WindowSurfacePolicy {
        WindowSurfacePolicy(effectsEnabled: enabled, reduceTransparency: false, increaseContrast: false,
                            fullScreen: fullScreen, zoomed: zoomed)
    }
}
