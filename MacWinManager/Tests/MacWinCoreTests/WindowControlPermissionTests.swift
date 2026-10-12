import Foundation
import Testing
@testable import MacWinCore

@Suite("Window control permission recovery")
struct WindowControlPermissionTests {
    @Test("Native codes retain consent-needed, authorization failure and unknown")
    func nativeStatus() {
        #expect(WindowControlPermission.automationState(code: 0) == .granted)
        #expect(WindowControlPermission.automationState(code: -1744) == .needsUserConsent)
        #expect(WindowControlPermission.automationState(code: -1743) == .notAuthorized)
        #expect(WindowControlPermission.automationState(code: -600) == .unknown(-600))
    }
    @Test("Caller status is informational and retains unknown codes")
    func informationalStatus() {
        let status = WindowControlPermission.Status(accessibilityTrusted: false, automation: .unknown(-600))
        #expect(!status.accessibilityTrusted)
        #expect(status.automation == .unknown(-600))
    }
    @Test("Script failures distinguish Automation, assistive access and ordinary errors")
    func errorMapping() {
        #expect(WindowControlPermission.classify(stderr: "Not authorized (-1743)") == .automation)
        #expect(WindowControlPermission.classify(stderr: "osascript is not allowed assistive access. (-1719)") == .accessibility)
        #expect(WindowControlPermission.classify(stderr: "AX failure (-25211)") == .accessibility)
        #expect(WindowControlPermission.classify(stderr: "Invalid index (-1719)") == .operation)
        #expect(WindowControlPermission.classify(stderr: "timeout (-1712)") == .operation)
    }
    @Test("Tolerant script catches preserve permission errors and no-target failure")
    func scriptErrorPropagation() {
        let script = WindowControlPermission.preservingPermissionErrors(in: "try\ntry\nget name\nend try\nend try")
        #expect(script.components(separatedBy: "my propagatePermissionError(errorMessage, errorNumber)").count == 3)
        #expect(script.contains("error errorMessage number errorNumber"))
        #expect(script.contains("No matching Wine window was found"))
        #expect(script.contains("if targetWindowFound then"))
        #expect(script.contains("optional focus/repair did not finish before the retry limit"))
        let matched = WindowControlPermission.preservingPermissionErrors(in: "if windowMatches is true then\nreturn\nend if")
        #expect(matched.contains("set targetWindowFound to true"))
    }
    private final class Count: @unchecked Sendable { var value = 0 }

    @Test("Preparing does not execute and one user action consumes once")
    func consumeOnce() {
        let queue = PendingWindowControl()
        let count = Count()
        let id = queue.prepare(isCurrent: { true }, operation: { count.value += 1 })
        #expect(count.value == 0)
        #expect(queue.requestID == id)
        #expect(queue.run(id: id) == .started)
        #expect(queue.run(id: id) == .superseded)
        #expect(count.value == 1)
    }

    @Test("A late action cannot execute a replaced launch or clear its request")
    func supersededAction() {
        let queue = PendingWindowControl()
        let count = Count()
        let old = queue.prepare(isCurrent: { true }, operation: { count.value += 1 })
        let latest = queue.prepare(isCurrent: { true }, operation: { count.value += 1 })
        #expect(queue.run(id: old) == .superseded)
        #expect(queue.requestID == latest)
        #expect(count.value == 0)
        let changedDuringCheck = queue.prepare(isCurrent: {
            _ = queue.prepare(isCurrent: { true }, operation: {})
            return true
        }, operation: { count.value += 1 })
        #expect(queue.run(id: changedDuringCheck) == .superseded)
        #expect(count.value == 0)
    }

    @Test("An exited original process prevents helper execution")
    func expiredTarget() {
        let queue = PendingWindowControl()
        let count = Count()
        let id = queue.prepare(isCurrent: { false }, operation: { count.value += 1 })
        #expect(queue.run(id: id) == .expired)
        #expect(count.value == 0)
        #expect(queue.requestID == nil)
    }

    @Test("Cancellation never executes and cannot cancel a newer action")
    func cancel() {
        let queue = PendingWindowControl()
        let count = Count()
        let old = queue.prepare(isCurrent: { true }, operation: { count.value += 1 })
        queue.cancel(id: old)
        #expect(queue.run(id: old) == .superseded)
        let latest = queue.prepare(isCurrent: { true }, operation: { count.value += 1 })
        queue.cancel(id: old)
        #expect(queue.requestID == latest)
        #expect(count.value == 0)
        queue.cancel(id: latest)
        #expect(queue.requestID == nil)
    }

}
