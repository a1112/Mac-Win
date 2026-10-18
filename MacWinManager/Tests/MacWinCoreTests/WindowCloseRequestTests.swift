import XCTest
@testable import MacWinCore

final class WindowCloseRequestTests: XCTestCase {
    @MainActor
    func testNativeCloseKeepsFrameworkAndDelegateHandlingOnNativePath() {
        let target = Target(nativeButton: true)
        WindowCloseRequest.perform(on: target)
        XCTAssertEqual(target.calls, ["native"])
    }

    @MainActor
    func testModalSheetPreventsParentCloseOnBothPaths() {
        for nativeButton in [false, true] {
            let target = Target(nativeButton: nativeButton, attachedSheet: true)
            WindowCloseRequest.perform(on: target)
            XCTAssertEqual(target.calls, [])
        }
    }

    @MainActor
    func testMissingButtonHonorsDelegateVeto() {
        let target = Target(nativeButton: false, allowsClose: false)
        WindowCloseRequest.perform(on: target)
        XCTAssertEqual(target.calls, ["delegate"])
    }

    @MainActor
    func testMissingButtonClosesOnlyAfterDelegateApproval() {
        let target = Target(nativeButton: false, allowsClose: true)
        WindowCloseRequest.perform(on: target)
        XCTAssertEqual(target.calls, ["delegate", "close"])
    }

    @MainActor
    private final class Target: WindowCloseTarget {
        var hasAttachedSheet: Bool
        var hasNativeCloseButton: Bool
        let allowsClose: Bool
        var calls: [String] = []

        init(nativeButton: Bool, attachedSheet: Bool = false, allowsClose: Bool = true) {
            hasNativeCloseButton = nativeButton
            hasAttachedSheet = attachedSheet
            self.allowsClose = allowsClose
        }
        func requestNativeClose() { calls.append("native") }
        func delegateAllowsClosing() -> Bool { calls.append("delegate"); return allowsClose }
        func closeWithoutButton() { calls.append("close") }
    }
}
