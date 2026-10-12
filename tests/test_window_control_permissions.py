"""Source/packaging contracts only. Native Swift and TCC tests require a Mac."""
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'MacWinManager/Sources/MacWinCore'

class WindowControlPermissionSourceTests(unittest.TestCase):
    def test_launch_prepares_without_parent_permission_gate_or_helper_start(self):
        runner = (CORE / 'WineRunner.swift').read_text()
        launch = runner.split('private func activateWineApplicationIfNeeded', 1)[1].split('private static func runWindowControlScript', 1)[0]
        self.assertIn('WindowControlPermission.prepare', launch)
        self.assertIn('launchedProcess.isRunning', launch)
        self.assertIn('whose unix id is targetPID', launch)
        self.assertNotIn('canAttempt', launch)
        self.assertNotIn('WindowControlPermission.status()', launch)
        self.assertNotIn('activationProcess.run()', launch)

    def test_helper_preserves_actual_failure_and_never_discards_stderr(self):
        runner = (CORE / 'WineRunner.swift').read_text()
        operation = runner.split('private static func runWindowControlScript', 1)[1].split('static let wineApplicationActivationTimeout', 1)[0]
        self.assertIn('activationProcess.standardError = errorPipe', operation)
        self.assertIn('terminationStatus', operation)
        self.assertIn('WindowControlPermission.classify(stderr: stderr)', operation)
        self.assertIn('Could not start optional window control', operation)
        permission = (CORE / 'WindowControlPermission.swift').read_text()
        self.assertIn('if targetWindowFound then', permission)
        self.assertIn('optional focus/repair did not finish before the retry limit', permission)
        self.assertIn('No matching Wine window was found', permission)
        self.assertIn('set targetWindowFound to true', permission)

    def test_prompt_is_explicit_and_descriptor_storage_is_retained(self):
        permission = (CORE / 'WindowControlPermission.swift').read_text()
        status = permission.split('public static func status()', 1)[1].split('public static func requestAccessibility()', 1)[0]
        self.assertIn('automationCode(request: false)', status)
        self.assertNotIn('AXIsProcessTrustedWithOptions(options)', status)
        self.assertIn('kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true', permission)
        self.assertIn('guard let address = target.aeDesc', permission)
        self.assertIn('withExtendedLifetime(target)', permission)
        view = (ROOT / 'MacWinManager/Sources/MacWinManagerApp/WindowControlRecoveryView.swift').read_text()
        self.assertIn('Button("Run window control") { WindowControlPermission.runPending(id: requestID) }', view)
        self.assertIn('Button("Cancel queued action") { WindowControlPermission.cancelPending(id: requestID) }', view)
        self.assertIn('accessibilityRequestStarted = true', view)
        self.assertIn('status.accessibilityTrusted || accessibilityRequestStarted', view)

    def test_generated_bundle_declares_only_existing_automation_purpose(self):
        packaging = (ROOT / 'MacWinManager/Tools/package-app.sh').read_text()
        python = packaging.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        module = ast.parse(python)
        value = next(node.value for node in module.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'plist' for target in node.targets))
        plist = ast.literal_eval(value)
        self.assertEqual(plist['CFBundleIdentifier'], 'dev.local.macwin.manager')
        self.assertIn('System Events', plist['NSAppleEventsUsageDescription'])
        self.assertNotIn('NSCameraUsageDescription', plist)
