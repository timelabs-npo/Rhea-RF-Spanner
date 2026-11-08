#!/usr/bin/env python3
"""Run the built native app in iOS Simulator; never start live audio.

Screenshots are CI review evidence, not an assertion of device measurement
performance. Visible app content must appear before a bounded deadline. The
first idle launch is captured before DEMO or hosted tests can warm up the app.
"""
from __future__ import annotations

from collections.abc import Callable
import json
import math
import platform
import shutil
import subprocess
import time
import unicodedata
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/screenshots"
BUNDLE = "org.timelabs.RheaRFSpanner"
READINESS_DEADLINE_SECONDS = 45.0
READINESS_POLL_SECONDS = 0.5
DIAGNOSTIC_OUTPUT_LIMIT = 8_192
BOOT_TIMEOUT_SECONDS = 480
SETUP_HELP_TIMEOUT_SECONDS = 10
OWNED_CLEANUP_TIMEOUT_SECONDS = 10
# A source tab/button alone is not evidence of the displayed acquisition mode.
# Require the source caption and a view-specific caption for each DEMO image.
SCENARIOS = [
    ("01-idle", [], ["RHEA", "LIVE LISTEN", "Listen", "Tone experiment", "MIC OFF", "START LISTENING"]),
    ("02-demo-field", ["--observatory-demo"],
     ["RHEA", "DEMO SYNTHETIC", "SYNTHETIC FIELD", "Synthetic samples received", "STOP"]),
    ("03-demo-waterfall", ["--observatory-demo", "--observatory-waterfall"],
     ["RHEA", "DEMO SYNTHETIC", "SAMPLE SPECTRUM", "Synthetic samples received", "STOP"]),
    ("04-demo-diagnostics", ["--observatory-demo", "--observatory-waterfall", "--observatory-diagnostics"],
     ["Pipeline diagnostics", "Mode state", "demo running", "Synthetic samples received"]),
]


def run(*args: str, timeout: float = 90, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stdout}\n{result.stderr}")
    return result.stdout


def failure_details(error: BaseException) -> dict:
    """Retain bounded timeout output; it may include a PID printed before a hang."""
    details = {"type": type(error).__name__, "message": str(error)[-DIAGNOSTIC_OUTPUT_LIMIT:]}
    if isinstance(error, subprocess.TimeoutExpired):
        details["timeout_seconds"] = error.timeout
        details["output_tail_limit_characters"] = DIAGNOSTIC_OUTPUT_LIMIT
        for stream in ("stdout", "stderr"):
            value = getattr(error, stream)
            details[stream + "_truncated"] = value is not None and len(value) > DIAGNOSTIC_OUTPUT_LIMIT
            # TimeoutExpired can contain bytes even with subprocess text=True.
            # Slice before decoding, then cap the retained text to 8,192 code
            # points per stream; never decode an unbounded captured buffer here.
            if isinstance(value, bytes):
                value = value[-DIAGNOSTIC_OUTPUT_LIMIT:].decode("utf-8", errors="replace")
            details[stream + "_tail"] = value[-DIAGNOSTIC_OUTPUT_LIMIT:] if value is not None else None
    return details


def write_manifest(manifest: dict) -> None:
    temporary = OUTPUT / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(OUTPUT / "manifest.json")


def write_manifest_best_effort(manifest: dict, context: str) -> BaseException | None:
    """Evidence I/O must not block cleanup or replace an existing failure."""
    try:
        write_manifest(manifest)
    except BaseException as error:
        details = {"context": context, **failure_details(error)}
        manifest.setdefault("manifest_write_failures", []).append(details)
        print(f"Manifest write failed ({context}): {details['message']}", flush=True)
        return error
    return None


def recorded_command(manifest: dict, phase: str, *args: str, timeout: float = 90,
                     check: bool = True, cleanup: bool = False,
                     on_success: Callable[[str], None] | None = None) -> str:
    """Record setup/cleanup before calling Simulator, including boot failures."""
    command = {"phase": phase, "arguments": list(args), "timeout_seconds": timeout,
               "check_return_code": check, "status": "running"}
    manifest["cleanup_steps" if cleanup else "setup_steps"].append(command)
    if not cleanup:
        manifest["phase"] = phase
    recording_failure = write_manifest_best_effort(manifest, phase + "_before") if cleanup else None
    if not cleanup:
        write_manifest(manifest)
    started = time.monotonic()
    command_failure: BaseException | None = None
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        command["return_code"] = result.returncode
        command["output_tail_limit_characters"] = DIAGNOSTIC_OUTPUT_LIMIT
        for stream in ("stdout", "stderr"):
            output = getattr(result, stream)
            command[stream + "_tail"] = output[-DIAGNOSTIC_OUTPUT_LIMIT:]
            command[stream + "_truncated"] = len(output) > DIAGNOSTIC_OUTPUT_LIMIT
        if check and result.returncode:
            raise RuntimeError(f"{phase} returned exit code {result.returncode}; see its recorded command output.")
        if result.returncode == 0 and on_success is not None:
            # Register a returned resource before the completion-evidence write
            # can throw. The callback may validate ownership; it cannot turn a
            # failed command into ownership of a preexisting or guessed device.
            on_success(result.stdout)
        command["status"] = "complete" if result.returncode == 0 else "nonzero_ignored"
        return result.stdout
    except BaseException as error:
        command_failure = error
        command["status"] = "failed"
        command["error_details"] = failure_details(error)
        raise
    finally:
        command["elapsed_seconds"] = round(time.monotonic() - started, 3)
        if cleanup or command_failure is not None:
            final_recording_failure = write_manifest_best_effort(manifest, phase + "_after")
            recording_failure = recording_failure or final_recording_failure
        else:
            write_manifest(manifest)
        # A recording failure is reported only after an owned cleanup command
        # ran. It never replaces that command's own failure.
        if command_failure is None and recording_failure is not None:
            raise recording_failure


def simulator_template(catalog: dict) -> dict:
    """Keep the existing model preference, using actual device/runtime IDs."""
    available_runtimes = {runtime["identifier"] for runtime in catalog["runtimes"]
                          if runtime.get("isAvailable") and ".iOS-" in runtime["identifier"]}
    device_types = {device_type["identifier"]: device_type for device_type in catalog["devicetypes"]}
    candidates = [(runtime, device) for runtime, devices in catalog["devices"].items()
                  if runtime in available_runtimes for device in devices
                  if device.get("isAvailable") and device["name"].startswith("iPhone")]
    if not candidates:
        raise RuntimeError("No available iPhone Simulator runtime; native visual capture is blocked.")
    runtime, device = next((candidate for candidate in candidates if candidate[1]["name"] == "iPhone 17 Pro"),
                           candidates[0])
    device_type_id = device.get("deviceTypeIdentifier")
    if device_type_id is None:
        # Older catalogs can omit this field. Resolve only an exact, unique
        # listed model name; never construct an identifier from a display name.
        matches = [identifier for identifier, value in device_types.items() if value["name"] == device["name"]]
        if len(matches) != 1:
            raise RuntimeError("Selected Simulator has no unambiguous listed device type identifier.")
        device_type_id = matches[0]
    if device_type_id not in device_types:
        raise RuntimeError("Selected Simulator device type is absent from the installed catalog.")
    return {"template_name": device["name"], "template_udid": device["udid"],
            "model_name": device_types[device_type_id]["name"],
            "device_type_identifier": device_type_id, "runtime_identifier": runtime}


def verified_created_udid(output: str, preexisting_udids: set[str]) -> str:
    """Accept only one returned canonical UUID that was not in the catalog."""
    candidate = output.strip()
    try:
        parsed = uuid.UUID(candidate)
    except (ValueError, AttributeError) as error:
        raise RuntimeError("Simulator create did not return one canonical device UUID; ownership is unverified.") from error
    if (not parsed.int or str(parsed).casefold() != candidate.casefold()
            or candidate.casefold() in {value.casefold() for value in preexisting_udids}):
        raise RuntimeError("Simulator create returned a noncanonical or preexisting UUID; ownership is unverified.")
    return str(parsed).upper()


def normalize_text(value: str) -> str:
    # Vision can vary case, spaces, and punctuation within a recognized label.
    # This does not correct/substitute letters or invent a missing caption.
    return "".join(character for character in unicodedata.normalize("NFKC", value).casefold()
                   if character.isalnum())


def observation_bounds(line: dict) -> tuple[float, float, float, float] | None:
    """Validate Vision's normalized lower-left-origin observation rectangle."""
    bounds = line.get("boundingBox")
    if not isinstance(bounds, dict):
        return None
    values = tuple(bounds.get(key) for key in ("x", "y", "width", "height"))
    if any(type(value) not in (int, float) or not 0 <= value <= 1 or not math.isfinite(value)
           for value in values):
        return None
    x, y, width, height = values
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1 or y + height > 1:
        return None
    return x, y, width, height


def in_primary_dock(bounds: tuple[float, float, float, float]) -> bool:
    # Portrait native capture: the complete label must be in the lower 20% of
    # the image and middle half of its width, centered in the middle fifth.
    # Coordinates come from the actual screenshot, not the expected app state.
    x, y, width, height = bounds
    return 0.25 <= x and x + width <= 0.75 and y + height <= 0.20 and 0.40 <= x + width / 2 <= 0.60


def has_primary_action(lines: list[dict], action: str) -> bool:
    observations = [(normalize_text(line["text"]), observation_bounds(line)) for line in lines]
    dock_lines = [(text, bounds) for text, bounds in observations
                  if bounds is not None and in_primary_dock(bounds)]
    if any(text == action for text, _ in dock_lines):
        return True
    if action != "startlistening":
        return False  # STOP must be one exact visible label in the dock.

    # SwiftUI can wrap the centered action title into START / LISTENING. Accept
    # only that physical top-to-bottom order, with centers within 2.5% of image
    # width, similar glyph heights (ratio <= 1.5), nonoverlapping boxes, and a
    # gap <= one larger glyph height. Array order is irrelevant to image order.
    for first_text, first in dock_lines:
        if first_text != "start":
            continue
        for second_text, second in dock_lines:
            if second_text != "listening":
                continue
            x1, y1, width1, height1 = first
            x2, y2, width2, height2 = second
            gap = y1 - (y2 + height2)
            if (abs((x1 + width1 / 2) - (x2 + width2 / 2)) > 0.025
                    or max(height1, height2) > 1.5 * min(height1, height2)
                    or not 0 <= gap <= max(height1, height2)):
                continue
            # A third line in the gap makes these separate labels, not a
            # wrapped action. Unrelated controls outside this column are fine.
            left, right = min(x1, x2), max(x1 + width1, x2 + width2)
            interrupted = any(
                text and bounds is not None and bounds not in (first, second)
                and bounds[0] < right and bounds[0] + bounds[2] > left
                and bounds[1] < y1 and bounds[1] + bounds[3] > y2 + height2
                for text, bounds in observations
            )
            if not interrupted:
                return True
    return False


def missing_labels(lines: list[dict], required: list[str]) -> list[str]:
    normalized_lines = {normalize_text(line["text"]) for line in lines}
    # Primary actions need exact text and position evidence. Instructional text
    # containing "Tap Start listening" or "stopped" is not evidence of a button.
    primary_actions = {"startlistening", "stop"}
    # Never join unrelated lines: the source caption "DEMO SYNTHETIC" followed
    # by a FIELD selector is not the view-specific caption "SYNTHETIC FIELD".
    return [label for label in required
            if (not has_primary_action(lines, normalize_text(label))
                if normalize_text(label) in primary_actions
                else not any(normalize_text(label) in line for line in normalized_lines))]


def remaining_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"Visible app content did not pass within {READINESS_DEADLINE_SECONDS:g} seconds.")
    return remaining


def compile_text_reader() -> Path:
    helper = ROOT / "build/tools/capture-screen-text"
    helper.parent.mkdir(parents=True, exist_ok=True)
    # Compilation happens before the first app launch, not by running a warmup
    # app/test. The helper reads only the PNG supplied to it.
    run("xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
        str(ROOT / "scripts/capture_screen_text.swift"), "-o", str(helper), timeout=120)
    return helper


def capture_when_visible(udid: str, helper: Path, name: str, args: list[str],
                         required: list[str], manifest: dict) -> None:
    path = OUTPUT / f"{name}.png"
    first_path = OUTPUT / f"{name}-first-attempt.png"
    # A repeated local capture must never accept an image from an older run.
    path.unlink(missing_ok=True)
    first_path.unlink(missing_ok=True)
    first_launch = not manifest["screenshots"]
    owned = manifest.get("owned_simulator", {})
    skip_pretermination = (first_launch and name == "01-idle" and not args
                           and owned.get("ownership_verified") is True and owned.get("udid") == udid)
    scenario = {
        "name": path.name, "launch_arguments": args, "required_visible_labels": required,
        "first_launch_in_capture_run": first_launch,
        "prelaunch_termination": "skipped_fresh_owned_first_launch" if skip_pretermination else "required",
        "status": "preparing", "phase": "first_launch_preparation" if skip_pretermination else "prelaunch_termination",
        "attempts": [],
    }
    manifest["screenshots"].append(scenario)
    write_manifest(manifest)
    scenario_started = time.monotonic()
    started: float | None = None
    try:
        if not skip_pretermination:
            run("xcrun", "simctl", "terminate", udid, BUNDLE, timeout=10, check=False)
            scenario["prelaunch_termination_seconds"] = round(time.monotonic() - scenario_started, 3)
        scenario["status"] = "launching"
        scenario["phase"] = "launch"
        started = time.monotonic()
        deadline = started + READINESS_DEADLINE_SECONDS
        write_manifest(manifest)
        result = run("xcrun", "simctl", "launch", udid, BUNDLE, *args,
                     timeout=remaining_timeout(deadline))
        scenario["launch_returned_seconds"] = round(time.monotonic() - started, 3)
        print(result.strip(), flush=True)
        while True:
            remaining_timeout(deadline)
            attempt = {"number": len(scenario["attempts"]) + 1,
                       "capture_started_seconds": round(time.monotonic() - started, 3),
                       "status": "capturing"}
            scenario["attempts"].append(attempt)
            scenario["phase"] = "screenshot"
            write_manifest(manifest)
            run("xcrun", "simctl", "io", udid, "screenshot", str(path),
                timeout=remaining_timeout(deadline))
            attempt["captured_seconds"] = round(time.monotonic() - started, 3)
            attempt["image_bytes"] = path.stat().st_size  # Evidence only, never a readiness gate.
            scenario["last_screenshot"] = path.name
            if not first_path.exists():
                shutil.copyfile(path, first_path)
                scenario["first_screenshot"] = first_path.name
            attempt["status"] = "recognizing"
            scenario["phase"] = "text_recognition"
            write_manifest(manifest)
            recognized = json.loads(run(str(helper), str(path), timeout=remaining_timeout(deadline)))
            lines = recognized["lines"]
            if not isinstance(lines, list) or any(not isinstance(line.get("text"), str) for line in lines):
                raise RuntimeError("Screenshot text reader returned an invalid result.")
            attempt["recognizer"] = {key: recognized[key] for key in ("engine", "revision")}
            attempt["observed_lines"] = lines
            attempt["missing_labels"] = missing_labels(lines, required)
            attempt["checked_seconds"] = round(time.monotonic() - started, 3)
            attempt["status"] = "waiting" if attempt["missing_labels"] else "visible"
            scenario["phase"] = "visible_content_check"
            write_manifest(manifest)
            # Recognition itself must complete within the same deadline. A late
            # result cannot silently turn a timed-out cold launch into a pass.
            remaining_timeout(deadline)
            if not attempt["missing_labels"]:
                scenario["status"] = "visible_content_ready"
                scenario["visible_content_ready_seconds"] = attempt["checked_seconds"]
                write_manifest(manifest)
                print(f"Visible {name} after {attempt['checked_seconds']:.3f}s "
                      f"({len(scenario['attempts'])} attempt(s)); captured {path.name}", flush=True)
                return
            print(f"Waiting for {name} at {attempt['checked_seconds']:.3f}s: "
                  + ", ".join(attempt["missing_labels"]), flush=True)
            time.sleep(min(READINESS_POLL_SECONDS, remaining_timeout(deadline)))
    except Exception as error:
        scenario["status"] = "failed"
        scenario["scenario_elapsed_seconds"] = round(time.monotonic() - scenario_started, 3)
        if started is not None:
            scenario["elapsed_seconds"] = round(time.monotonic() - started, 3)
        scenario["error_details"] = failure_details(error)
        scenario["error"] = scenario["error_details"]["message"]
        if scenario["attempts"] and scenario["attempts"][-1]["status"] in {"capturing", "recognizing"}:
            scenario["attempts"][-1]["status"] = "failed"
            scenario["attempts"][-1]["error"] = scenario["error"]
        write_manifest_best_effort(manifest, "capture_" + name + "_failure")
        raise RuntimeError(f"{name} failed during {scenario['phase']}. "
                           f"Inspect {OUTPUT / 'manifest.json'} and the retained screenshot(s).") from error


def run_hosted_tests(udid: str, manifest: dict) -> None:
    test_output = ROOT / "build/test-results"
    test_output.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"Unsupported Simulator host architecture: {architecture}")
    # xcodebuild refuses an existing result bundle. Preserve earlier evidence
    # while allowing repeated captures in the same checkout.
    result_bundle = test_output / f"ObservatorySession-{uuid.uuid4().hex}.xcresult"
    manifest["hosted_test_result_bundle"] = str(result_bundle.relative_to(ROOT))
    write_manifest(manifest)
    command = [
        "xcodebuild", "-project", "RheaRFSpanner.xcodeproj", "-scheme", "RheaRFSpanner",
        "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={udid},arch={architecture}",
        "-derivedDataPath", "build/DerivedData-simulator",
        "-resultBundlePath", str(result_bundle),
        "-only-testing:RheaRFSpannerTests", "CODE_SIGNING_ALLOWED=NO", "test",
    ]
    print("Running simulator-hosted session integration tests", flush=True)
    print(f"Result bundle: {result_bundle.relative_to(ROOT)}", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=600)
    (ROOT / "build/logs/xcode-session-tests.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Session tests failed. See xcode-session-tests.log.\n" + (result.stdout + result.stderr)[-5_000:])
    print("Simulator-hosted session integration tests passed", flush=True)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (ROOT / "build/logs").mkdir(parents=True, exist_ok=True)
    capture_id = uuid.uuid4().hex
    manifest = {
        "capture_id": capture_id, "bundle": BUNDLE, "screenshots": [],
        "run_status": "preparing", "phase": "initialization", "capture_status": "preparing",
        "readiness_deadline_seconds": READINESS_DEADLINE_SECONDS,
        "boot_timeout_seconds": BOOT_TIMEOUT_SECONDS, "setup_steps": [], "cleanup_steps": [],
        "readiness_meaning": "Visible app content only; not a measurement or hardware validation.",
        "launch_order": "Idle first on a fresh owned Simulator, then DEMO scenarios, then hosted tests. No app warmup or retry.",
    }
    # Write evidence before any git/simctl/setup command can fail or hang.
    write_manifest(manifest)
    owned_udid: str | None = None
    primary_failure: BaseException | None = None
    try:
        manifest["source_commit"] = recorded_command(
            manifest, "identify_source", "git", "-C", str(ROOT), "rev-parse", "HEAD", timeout=10
        ).strip()
        for command in ("create", "shutdown", "delete"):
            # Retain this installed Xcode's actual CLI reference before using
            # the lifecycle commands. Help is bounded and never launches Rhea.
            recorded_command(manifest, "help_" + command, "xcrun", "simctl", "help", command,
                             timeout=SETUP_HELP_TIMEOUT_SECONDS)
        catalog = json.loads(recorded_command(
            manifest, "list_simulators", "xcrun", "simctl", "list", "--json", timeout=30
        ))
        template = simulator_template(catalog)
        manifest["simulator"] = template["model_name"]
        manifest["simulator_template"] = template
        preexisting_udids = {device["udid"] for devices in catalog["devices"].values() for device in devices}
        owned_name = "Rhea-Capture-" + capture_id
        manifest["requested_simulator_name"] = owned_name

        def register_created_simulator(output: str) -> None:
            nonlocal owned_udid
            # Authority comes only from a successful create and a new canonical
            # returned UUID. Register it before any completion evidence I/O.
            manifest["phase"] = "verify_created_ownership"
            owned_udid = verified_created_udid(output, preexisting_udids)
            manifest["owned_simulator"] = {"name": owned_name, "udid": owned_udid,
                                           "ownership_verified": True,
                                           "device_type_identifier": template["device_type_identifier"],
                                           "runtime_identifier": template["runtime_identifier"]}
            manifest["phase"] = "create_simulator"

        recorded_command(
            manifest, "create_simulator", "xcrun", "simctl", "create", owned_name,
            template["device_type_identifier"], template["runtime_identifier"], timeout=60,
            on_success=register_created_simulator
        )
        if owned_udid is None:
            raise RuntimeError("Simulator create did not establish verified ownership.")
        print(f"Fresh Simulator: {template['model_name']} ({owned_udid})", flush=True)
        recorded_command(manifest, "boot_simulator", "xcrun", "simctl", "boot", owned_udid)
        recorded_command(manifest, "wait_for_boot", "xcrun", "simctl", "bootstatus", owned_udid, "-b",
                         timeout=BOOT_TIMEOUT_SECONDS)
        recorded_command(manifest, "set_appearance", "xcrun", "simctl", "ui", owned_udid, "appearance", "dark")
        recorded_command(manifest, "set_status_bar", "xcrun", "simctl", "status_bar", owned_udid,
                         "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
                         "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
        manifest["phase"] = "locate_app"
        write_manifest(manifest)
        app = ROOT / "build/DerivedData-simulator/Build/Products/Debug-iphonesimulator/RheaRFSpanner.app"
        if not app.is_dir():
            raise RuntimeError(f"Simulator build missing: {app}")
        recorded_command(manifest, "install_app", "xcrun", "simctl", "install", owned_udid, str(app))
        manifest["phase"] = "compile_text_reader"
        write_manifest(manifest)
        helper = compile_text_reader()
        manifest["capture_status"] = "capturing"
        manifest["run_status"] = "capturing"
        for name, args, required in SCENARIOS:
            manifest["phase"] = "capture_" + name
            write_manifest(manifest)
            capture_when_visible(owned_udid, helper, name, args, required, manifest)
        manifest["capture_status"] = "complete"
        write_manifest(manifest)
        recorded_command(manifest, "pretest_termination", "xcrun", "simctl", "terminate", owned_udid,
                         BUNDLE, timeout=10, check=False)
        manifest["phase"] = "hosted_tests"
        manifest["hosted_tests_status"] = "running"
        write_manifest(manifest)
        run_hosted_tests(owned_udid, manifest)
        manifest["hosted_tests_status"] = "passed"
        manifest["run_status"] = "complete"
        manifest["phase"] = "complete"
        write_manifest(manifest)
    except BaseException as error:
        primary_failure = error
        manifest["run_status"] = "failed"
        if manifest["capture_status"] != "complete":
            manifest["capture_status"] = "failed"
        if manifest.get("hosted_tests_status") == "running":
            manifest["hosted_tests_status"] = "failed"
        manifest["error_details"] = failure_details(error)
        manifest["error"] = manifest["error_details"]["message"]
        write_manifest_best_effort(manifest, "primary_failure")
        raise
    finally:
        # This lifetime includes hosted tests, not just screenshots. Never
        # target a preprovisioned device, the 'all' alias, or an unverified ID.
        cleanup_failure: BaseException | None = None
        if owned_udid is not None:
            for command in ("shutdown", "delete"):
                try:
                    recorded_command(manifest, "cleanup_" + command, "xcrun", "simctl", command,
                                     owned_udid, timeout=OWNED_CLEANUP_TIMEOUT_SECONDS, cleanup=True)
                except BaseException as error:
                    if cleanup_failure is None:
                        cleanup_failure = error
                    print("Cleanup failed: " + failure_details(error)["message"], flush=True)
        manifest["cleanup_status"] = ("failed" if cleanup_failure is not None
                                       else "complete" if owned_udid is not None else "no_owned_device")
        if cleanup_failure is not None:
            manifest["run_status"] = "failed"
            if primary_failure is None:
                manifest["phase"] = "cleanup"
                manifest["error_details"] = failure_details(cleanup_failure)
                manifest["error"] = manifest["error_details"]["message"]
        final_recording_failure = write_manifest_best_effort(manifest, "cleanup_summary")
        # Cleanup evidence is additional; it cannot replace a boot, launch,
        # recognition, or test failure. A cleanup-only failure still fails CI.
        if cleanup_failure is not None and primary_failure is None:
            raise cleanup_failure
        if final_recording_failure is not None and primary_failure is None:
            raise final_recording_failure


if __name__ == "__main__":
    main()
