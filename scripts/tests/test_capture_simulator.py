"""Recognition-gate fixtures only; no Swift, OCR, Simulator, or sensors run."""
import importlib.util
from pathlib import Path
import unittest


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


if __name__ == "__main__":
    unittest.main()
