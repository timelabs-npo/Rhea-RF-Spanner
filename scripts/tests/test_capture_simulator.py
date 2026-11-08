"""Recognition/lifecycle fixtures only; no Swift, OCR, Simulator, or sensors run."""
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "capture_simulator", Path(__file__).resolve().parents[1] / "capture_simulator.py"
)
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


def line(text, x=0.43, y=0.05, width=0.14, height=0.012):
    return {"text": text, "boundingBox": {"x": x, "y": y, "width": width, "height": height}}


class PrimaryActionRecognitionTests(unittest.TestCase):
    def test_exact_single_line_actions_in_dock(self):
        self.assertTrue(capture.has_primary_action([line("s t a r t  listening")], "startlistening"))
        self.assertTrue(capture.has_primary_action([line("stop")], "stop"))

    def test_centered_wrapped_action_accepts_normal_caption_leading(self):
        # Shape of the observed native wrap; coordinates here are synthetic,
        # not claimed to be Vision observations extracted from that screenshot.
        wrapped = [line("START", x=0.45, y=0.071, width=0.10),
                   line("LISTENING", x=0.41, y=0.05, width=0.18)]
        self.assertTrue(capture.has_primary_action(wrapped, "startlistening"))
        self.assertTrue(capture.has_primary_action(list(reversed(wrapped)), "startlistening"))

    def test_wrong_vertical_order_and_overlapping_lines_fail(self):
        for upper_y in (0.03, 0.055):
            with self.subTest(start_y=upper_y):
                self.assertFalse(capture.has_primary_action(
                    [line("START", y=upper_y), line("LISTENING", y=0.05)], "startlistening"))

    def test_distant_or_unaligned_words_fail(self):
        for start in (line("START", y=0.12), line("START", x=0.48, y=0.07),
                      line("START", y=0.08, height=0.025)):
            with self.subTest(start=start):
                self.assertFalse(capture.has_primary_action(
                    [start, line("LISTENING")], "startlistening"))

    def test_intervening_text_prevents_word_pairing(self):
        self.assertFalse(capture.has_primary_action(
            [line("START", y=0.071), line("LISTENING", y=0.05),
             line("another action", y=0.064, height=0.004)], "startlistening"))

    def test_instructions_stopped_data_and_partial_words_fail(self):
        for text in ("Tap Start listening", "START LISTENING when ready", "START", "LISTENING"):
            with self.subTest(text=text):
                self.assertFalse(capture.has_primary_action([line(text)], "startlistening"))
        for text in ("STOPPED DATA", "Stop experiment", "Stopping"):
            with self.subTest(text=text):
                self.assertFalse(capture.has_primary_action([line(text)], "stop"))

    def test_missing_or_malformed_bounds_fail(self):
        malformed = [None, {}, {"x": 0.43},
                     {"x": 0.43, "y": 0.05, "width": 0.14, "height": 0},
                     {"x": float("nan"), "y": 0.05, "width": 0.14, "height": 0.012},
                     {"x": 0.43, "y": float("inf"), "width": 0.14, "height": 0.012},
                     {"x": True, "y": 0.05, "width": 0.14, "height": 0.012},
                     {"x": "0.43", "y": 0.05, "width": 0.14, "height": 0.012},
                     {"x": 10 ** 400, "y": 0.05, "width": 0.14, "height": 0.012},
                     {"x": -0.1, "y": 0.05, "width": 0.14, "height": 0.012},
                     {"x": 0.43, "y": 0.05, "width": 0.8, "height": 0.012}]
        self.assertFalse(capture.has_primary_action([{"text": "STOP"}], "stop"))
        for bounds in malformed:
            with self.subTest(bounds=bounds):
                self.assertFalse(capture.has_primary_action(
                    [{"text": "START LISTENING", "boundingBox": bounds}], "startlistening"))
                self.assertFalse(capture.has_primary_action(
                    [{"text": "START", "boundingBox": bounds}, line("LISTENING")], "startlistening"))

    def test_actions_outside_bottom_center_fail(self):
        for bounds in ((0.05, 0.05, 0.14, 0.012), (0.43, 0.30, 0.14, 0.012),
                       (0.43, 0.195, 0.14, 0.012), (0.22, 0.05, 0.55, 0.012)):
            with self.subTest(bounds=bounds):
                self.assertFalse(capture.has_primary_action([line("STOP", *bounds)], "stop"))
                self.assertFalse(capture.has_primary_action([line("START LISTENING", *bounds)], "startlistening"))

    def test_source_and_selector_cannot_fake_field_caption(self):
        observed = [{"text": text} for text in ("RHEA", "DEMO SYNTHETIC", "FIELD WATERFALL",
                                                "SAMPLE SPECTRUM", "Synthetic samples received")]
        observed.append(line("STOP"))
        required = capture.SCENARIOS[1][2]
        self.assertEqual(capture.missing_labels(observed, required), ["SYNTHETIC FIELD"])

    def test_idle_requires_the_actual_action_in_addition_to_other_labels(self):
        required = capture.SCENARIOS[0][2]
        observed = [{"text": text} for text in required if text != "START LISTENING"]
        observed.append(line("Tap Start listening"))
        self.assertEqual(capture.missing_labels(observed, required), ["START LISTENING"])
        observed += [line("START", y=0.071), line("LISTENING", y=0.05)]
        self.assertEqual(capture.missing_labels(observed, required), [])


class OwnedSimulatorLifecycleTests(unittest.TestCase):
    """The actual coordinator runs against a wholly synthetic command backend."""

    EXISTING_OTHER = "11111111-1111-4111-8111-111111111111"
    EXISTING_PREFERRED = "22222222-2222-4222-8222-222222222222"
    CREATED = "33333333-3333-4333-8333-333333333333"
    RUNTIME_OTHER = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
    RUNTIME_PREFERRED = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    TYPE_OTHER = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
    TYPE_PREFERRED = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.output = self.root / "build/screenshots"
        self.output.mkdir(parents=True)
        (self.root / "build/DerivedData-simulator/Build/Products/Debug-iphonesimulator/RheaRFSpanner.app").mkdir(parents=True)
        self.stack.enter_context(mock.patch.object(capture, "ROOT", self.root))
        self.stack.enter_context(mock.patch.object(capture, "OUTPUT", self.output))
        self.stack.enter_context(mock.patch.object(capture.platform, "machine", return_value="arm64"))
        self.stack.enter_context(mock.patch.object(capture.subprocess, "run", side_effect=self.command))
        self.stack.enter_context(redirect_stdout(io.StringIO()))
        self.calls = []
        self.failures = {}
        self.return_codes = {}
        self.outputs = {}
        self.create_output = self.CREATED + "\n"
        self.active_arguments = []
        self.catalog = {
            "devicetypes": [
                {"identifier": self.TYPE_OTHER, "name": "iPhone 16 Pro"},
                {"identifier": self.TYPE_PREFERRED, "name": "iPhone 17 Pro"},
            ],
            "runtimes": [
                {"identifier": self.RUNTIME_OTHER, "isAvailable": True},
                {"identifier": self.RUNTIME_PREFERRED, "isAvailable": True},
            ],
            "devices": {
                self.RUNTIME_OTHER: [{"udid": self.EXISTING_OTHER, "name": "iPhone 16 Pro",
                                      "isAvailable": True, "deviceTypeIdentifier": self.TYPE_OTHER}],
                self.RUNTIME_PREFERRED: [{"udid": self.EXISTING_PREFERRED, "name": "iPhone 17 Pro",
                                          "isAvailable": True, "deviceTypeIdentifier": self.TYPE_PREFERRED}],
            },
        }

    def command(self, arguments, **kwargs):
        arguments = tuple(arguments)
        if arguments[0] == "git":
            key = "source"
            output = "a" * 40 + "\n"
        elif arguments[:2] == ("xcrun", "simctl"):
            key = arguments[2]
            output = ""
            if key == "help":
                key += "_" + arguments[3]
                output = "Synthetic help fixture for " + arguments[3]
            elif key == "list":
                output = json.dumps(self.catalog)
            elif key == "create":
                output = self.create_output
            elif key == "launch":
                self.active_arguments = list(arguments[5:])
                output = capture.BUNDLE + ": 12345\n"
            elif key == "io":
                # No image/OCR proof is claimed by this fixture. The real gate
                # consumes the synthetic recognizer output below.
                Path(arguments[-1]).write_bytes(b"synthetic screenshot fixture")
        elif arguments[0] == "xcodebuild":
            key = "hosted_tests"
            output = "Synthetic hosted-test result\n"
        elif arguments[:4] == ("xcrun", "--sdk", "macosx", "swiftc"):
            key = "compile_reader"
            output = ""
        elif Path(arguments[0]).name == "capture-screen-text":
            key = "recognize"
            required = next(required for _, launch_args, required in capture.SCENARIOS
                            if launch_args == self.active_arguments)
            output = json.dumps({"engine": "fixture", "revision": 0,
                                 "lines": [line(label) for label in required]})
        else:
            self.fail("Unexpected external command: " + repr(arguments))
        # This assertion runs even for git and failing setup commands: evidence
        # must already exist before the first external process is requested.
        self.assertTrue((self.output / "manifest.json").is_file())
        self.calls.append((key, arguments, kwargs))
        if key in self.failures:
            raise self.failures[key]
        stdout, stderr = self.outputs.get(key, (output, ""))
        return subprocess.CompletedProcess(arguments, self.return_codes.get(key, 0), stdout, stderr)

    def manifest(self):
        return json.loads((self.output / "manifest.json").read_text())

    def commands(self, key):
        return [(args, kwargs) for found, args, kwargs in self.calls if found == key]

    def test_fresh_instance_preserves_catalog_model_and_cold_launch_order_until_tests_finish(self):
        capture.main()
        manifest = self.manifest()
        self.assertEqual(manifest["source_commit"], "a" * 40)
        self.assertEqual(manifest["run_status"], "complete")
        self.assertEqual(manifest["hosted_tests_status"], "passed")
        self.assertEqual(manifest["cleanup_status"], "complete")
        self.assertEqual(manifest["owned_simulator"]["udid"], self.CREATED)
        create_args, _ = self.commands("create")[0]
        self.assertTrue(create_args[3].startswith("Rhea-Capture-"))
        self.assertEqual(create_args[4:], (self.TYPE_PREFERRED, self.RUNTIME_PREFERRED))
        for command in ("create", "shutdown", "delete"):
            help_args, help_options = self.commands("help_" + command)[0]
            self.assertEqual(help_args, ("xcrun", "simctl", "help", command))
            self.assertEqual(help_options["timeout"], 10)
            evidence = next(step for step in manifest["setup_steps"] if step["phase"] == "help_" + command)
            self.assertIn("Synthetic help fixture", evidence["stdout_tail"])
        keys = [key for key, _, _ in self.calls]
        self.assertLess(keys.index("help_delete"), keys.index("create"))
        self.assertLess(keys.index("install"), keys.index("compile_reader"))
        self.assertLess(keys.index("compile_reader"), keys.index("launch"))
        self.assertLess(keys.index("launch"), keys.index("terminate"))
        launches = self.commands("launch")
        self.assertEqual(len(launches), len(capture.SCENARIOS))
        self.assertEqual(launches[0][0], ("xcrun", "simctl", "launch", self.CREATED, capture.BUNDLE))
        self.assertEqual(manifest["readiness_deadline_seconds"], 45)
        self.assertGreater(launches[0][1]["timeout"], 0)
        self.assertLessEqual(launches[0][1]["timeout"], 45)
        self.assertEqual(self.commands("bootstatus")[0][1]["timeout"], 480)
        self.assertEqual(manifest["screenshots"][0]["prelaunch_termination"], "skipped_fresh_owned_first_launch")
        self.assertTrue(all(item["prelaunch_termination"] == "required" for item in manifest["screenshots"][1:]))
        self.assertEqual(len(self.commands("terminate")), len(capture.SCENARIOS))
        self.assertGreater(keys.index("hosted_tests"), max(index for index, key in enumerate(keys) if key == "recognize"))
        self.assertLess(keys.index("hosted_tests"), keys.index("shutdown"))
        self.assertLess(keys.index("shutdown"), keys.index("delete"))
        self.assertIn("id=" + self.CREATED, " ".join(self.commands("hosted_tests")[0][0]))
        for command in ("boot", "bootstatus", "ui", "status_bar", "install", "terminate", "launch", "shutdown", "delete"):
            for args, _ in self.commands(command):
                self.assertEqual(args[3], self.CREATED)
        for command in ("shutdown", "delete"):
            self.assertEqual(self.commands(command)[0][1]["timeout"], 10)

    def test_boot_timeout_is_preserved_even_when_both_owned_cleanup_commands_time_out(self):
        boot_error = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", self.CREATED, "-b"], 480,
                                                output=b"Boot remained incomplete", stderr=b"Fixture boot failure")
        self.failures = {"bootstatus": boot_error,
                         "shutdown": subprocess.TimeoutExpired(["shutdown", self.CREATED], 10),
                         "delete": subprocess.TimeoutExpired(["delete", self.CREATED], 10)}
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            capture.main()
        self.assertIs(raised.exception, boot_error)
        manifest = self.manifest()
        self.assertEqual(manifest["phase"], "wait_for_boot")
        self.assertEqual(manifest["capture_status"], "failed")
        self.assertEqual(manifest["error_details"]["timeout_seconds"], 480)
        self.assertEqual(manifest["error_details"]["stdout_tail"], "Boot remained incomplete")
        self.assertEqual(manifest["cleanup_status"], "failed")
        self.assertEqual([step["phase"] for step in manifest["cleanup_steps"]], ["cleanup_shutdown", "cleanup_delete"])
        self.assertEqual(len(self.commands("bootstatus")), 1)
        self.assertEqual(len(self.commands("create")), 1)
        self.assertFalse(self.commands("launch"))
        self.assertFalse(self.commands("hosted_tests"))

    def test_cleanup_manifest_failure_cannot_block_cleanup_or_replace_primary_error(self):
        original_write = capture.write_manifest
        for boot_fails in (True, False):
            with self.subTest(boot_fails=boot_fails):
                self.calls.clear()
                self.failures.clear()
                write_error = OSError("Synthetic cleanup evidence storage failure")
                boot_error = subprocess.TimeoutExpired(["bootstatus", self.CREATED], 480,
                                                        output=b"Original boot failure")
                if boot_fails:
                    self.failures["bootstatus"] = boot_error

                def failing_cleanup_write(manifest):
                    if manifest.get("cleanup_steps"):
                        raise write_error
                    original_write(manifest)

                expected = boot_error if boot_fails else write_error
                with mock.patch.object(capture, "write_manifest", side_effect=failing_cleanup_write):
                    with self.assertRaises(type(expected)) as raised:
                        capture.main()
                self.assertIs(raised.exception, expected)
                self.assertEqual(len(self.commands("shutdown")), 1)
                self.assertEqual(len(self.commands("delete")), 1)
                for command in ("shutdown", "delete"):
                    arguments, options = self.commands(command)[0]
                    self.assertEqual(arguments[3], self.CREATED)
                    self.assertEqual(options["timeout"], 10)
                if boot_fails:
                    # The last writable manifest retains the original cause;
                    # additional failed writes cannot retroactively replace it.
                    self.assertEqual(self.manifest()["error_details"]["stdout_tail"], "Original boot failure")
                    self.assertFalse(self.commands("hosted_tests"))
                else:
                    self.assertEqual(len(self.commands("hosted_tests")), 1)

    def test_invalid_or_preexisting_create_output_never_grants_mutation_or_cleanup_ownership(self):
        for output in (self.EXISTING_PREFERRED, "all", "booted", self.CREATED.replace("-", ""),
                       self.CREATED + "\n" + self.EXISTING_OTHER, "{" + self.CREATED + "}"):
            with self.subTest(output=output):
                self.calls.clear()
                self.create_output = output
                with self.assertRaisesRegex(RuntimeError, "ownership is unverified"):
                    capture.main()
                manifest = self.manifest()
                self.assertEqual(manifest["cleanup_status"], "no_owned_device")
                self.assertNotIn("owned_simulator", manifest)
                for command in ("boot", "bootstatus", "install", "launch", "shutdown", "delete"):
                    self.assertFalse(self.commands(command))

    def test_setup_help_failure_keeps_initial_manifest_and_bounded_output_without_creating_device(self):
        self.return_codes["help_create"] = 2
        self.outputs["help_create"] = ("H" * 10_000, "E" * 10_000)
        with self.assertRaisesRegex(RuntimeError, "help_create returned exit code 2"):
            capture.main()
        manifest = self.manifest()
        self.assertEqual(manifest["phase"], "help_create")
        self.assertEqual(manifest["run_status"], "failed")
        self.assertEqual(manifest["cleanup_status"], "no_owned_device")
        help_evidence = manifest["setup_steps"][-1]
        self.assertEqual(len(help_evidence["stdout_tail"]), capture.DIAGNOSTIC_OUTPUT_LIMIT)
        self.assertEqual(len(help_evidence["stderr_tail"]), capture.DIAGNOSTIC_OUTPUT_LIMIT)
        self.assertTrue(help_evidence["stdout_truncated"])
        self.assertTrue(help_evidence["stderr_truncated"])
        self.assertFalse(self.commands("create"))
        self.assertFalse(self.commands("delete"))

    def test_create_completion_write_failure_still_cleans_only_a_successfully_created_uuid(self):
        original_write = capture.write_manifest
        for return_code in (0, 1):
            with self.subTest(create_return_code=return_code):
                self.calls.clear()
                self.return_codes["create"] = return_code
                write_error = OSError("Synthetic create-completion evidence storage failure")
                completion_writes = []

                def failing_create_completion(manifest):
                    last_step = manifest["setup_steps"][-1] if manifest["setup_steps"] else {}
                    if (last_step.get("phase") == "create_simulator" and last_step.get("status") == "complete"
                            and not completion_writes):
                        # Ownership must already be registered at the exact
                        # point where completion evidence storage can fail.
                        completion_writes.append(manifest["owned_simulator"]["udid"])
                        raise write_error
                    original_write(manifest)

                with mock.patch.object(capture, "write_manifest", side_effect=failing_create_completion):
                    if return_code == 0:
                        with self.assertRaises(OSError) as raised:
                            capture.main()
                        self.assertIs(raised.exception, write_error)
                    else:
                        with self.assertRaisesRegex(RuntimeError, "create_simulator returned exit code 1"):
                            capture.main()
                self.assertEqual(len(self.commands("create")), 1)
                self.assertFalse(self.commands("boot"))
                if return_code == 0:
                    self.assertEqual(completion_writes, [self.CREATED])
                    for command in ("shutdown", "delete"):
                        self.assertEqual(len(self.commands(command)), 1)
                        self.assertEqual(self.commands(command)[0][0][3], self.CREATED)
                    self.assertEqual(self.manifest()["owned_simulator"]["udid"], self.CREATED)
                else:
                    # A UUID printed by a failed create is not ownership.
                    self.assertFalse(completion_writes)
                    self.assertFalse(self.commands("shutdown"))
                    self.assertFalse(self.commands("delete"))
                    self.assertNotIn("owned_simulator", self.manifest())

    def test_hosted_test_failure_still_cleans_owned_device_after_preserving_test_result(self):
        self.return_codes["hosted_tests"] = 1
        with self.assertRaisesRegex(RuntimeError, "Session tests failed"):
            capture.main()
        manifest = self.manifest()
        self.assertEqual(manifest["phase"], "hosted_tests")
        self.assertEqual(manifest["capture_status"], "complete")
        self.assertEqual(manifest["hosted_tests_status"], "failed")
        self.assertEqual(manifest["run_status"], "failed")
        self.assertEqual(manifest["cleanup_status"], "complete")
        self.assertTrue((self.root / "build/logs/xcode-session-tests.log").is_file())
        self.assertIn("hosted_test_result_bundle", manifest)
        keys = [key for key, _, _ in self.calls]
        self.assertLess(keys.index("hosted_tests"), keys.index("shutdown"))
        self.assertEqual(len(self.commands("hosted_tests")), 1)

    def test_cleanup_only_failure_fails_run_without_erasing_successful_captures_or_tests(self):
        failure = subprocess.TimeoutExpired(["shutdown", self.CREATED], 10)
        self.failures["shutdown"] = failure
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            capture.main()
        self.assertIs(raised.exception, failure)
        manifest = self.manifest()
        self.assertEqual(manifest["phase"], "cleanup")
        self.assertEqual(manifest["run_status"], "failed")
        self.assertEqual(manifest["capture_status"], "complete")
        self.assertEqual(manifest["hosted_tests_status"], "passed")
        self.assertEqual(manifest["cleanup_status"], "failed")
        self.assertEqual(len(self.commands("delete")), 1)

    def test_launch_timeout_retains_partial_output_and_never_retries_or_runs_hosted_tests(self):
        failure = subprocess.TimeoutExpired(["launch", self.CREATED], 45, output=b"App PID: 12345")
        self.failures["launch"] = failure
        with self.assertRaisesRegex(RuntimeError, "failed during launch") as raised:
            capture.main()
        self.assertIs(raised.exception.__cause__, failure)
        manifest = self.manifest()
        self.assertEqual(manifest["screenshots"][0]["phase"], "launch")
        self.assertEqual(manifest["screenshots"][0]["error_details"]["stdout_tail"], "App PID: 12345")
        self.assertEqual(manifest["cleanup_status"], "complete")
        self.assertEqual(len(self.commands("launch")), 1)
        self.assertFalse(self.commands("terminate"), "First fresh launch has no prior Rhea process")
        self.assertFalse(self.commands("hosted_tests"))

    def test_launch_failure_report_write_keeps_original_exception_chain_and_owned_cleanup(self):
        original_write = capture.write_manifest
        launch_error = subprocess.TimeoutExpired(["launch", self.CREATED], 45, output=b"Original launch failure")
        self.failures["launch"] = launch_error

        def failing_capture_error_write(manifest):
            if any(item["status"] == "failed" for item in manifest["screenshots"]):
                raise OSError("Synthetic capture-error evidence storage failure")
            original_write(manifest)

        with mock.patch.object(capture, "write_manifest", side_effect=failing_capture_error_write):
            with self.assertRaisesRegex(RuntimeError, "failed during launch") as raised:
                capture.main()
        self.assertIs(raised.exception.__cause__, launch_error)
        self.assertEqual(len(self.commands("launch")), 1)
        self.assertFalse(self.commands("hosted_tests"))
        for command in ("shutdown", "delete"):
            self.assertEqual(len(self.commands(command)), 1)
            self.assertEqual(self.commands(command)[0][0][3], self.CREATED)

    def test_first_capture_on_unowned_device_does_not_skip_pretermination(self):
        manifest = {"screenshots": []}
        capture.capture_when_visible(self.EXISTING_PREFERRED, self.root / "capture-screen-text",
                                     *capture.SCENARIOS[0], manifest)
        self.assertEqual(self.calls[0][0], "terminate")
        self.assertEqual(self.calls[0][1][3], self.EXISTING_PREFERRED)
        self.assertEqual(manifest["screenshots"][0]["prelaunch_termination"], "required")

    def test_unlisted_type_is_rejected_instead_of_guessing_or_changing_models(self):
        self.catalog["devices"][self.RUNTIME_PREFERRED][0]["deviceTypeIdentifier"] = "unlisted-device-type"
        with self.assertRaisesRegex(RuntimeError, "absent from the installed catalog"):
            capture.main()
        self.assertFalse(self.commands("create"))
        self.assertFalse(self.commands("delete"))
        self.assertEqual(self.manifest()["cleanup_status"], "no_owned_device")


if __name__ == "__main__":
    unittest.main()
