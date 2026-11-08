import SwiftUI

@MainActor
struct PrivacyMethodView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Three explicit sources", """
                    LIVE analyzes microphone samples and emits a speaker tone only after you agree, tap Record, and grant iOS microphone permission. Granting permission does not start the tone: tap Record again when ready. LIVE requires a physical device and its built-in microphone and speaker.

                    DEMO is a silent, deterministic simulation. It generates synthetic samples and passes them through the same signal-processing path as LIVE. It does not request microphone permission, activate an audio session, or emit sound.

                    REPLAY reads previously captured results from memory. Every frame retains its original LIVE or DEMO source. The microphone and speaker are off during replay.
                    """)
                    section("Privacy and memory", """
                    LIVE microphone samples can include surrounding sounds, including speech. The app analyzes acoustic phase and a spectrum; it does not transcribe speech, identify people, save audio files, or automatically upload audio or results.

                    Temporary samples, up to 2,048 result frames, and bounded companion spectra remain in volatile memory. The oldest result is overwritten when the replay is full. The menu’s Clear replay action removes retained results after a capture stops. Closing the app’s process also loses the in-memory replay.

                    There are no accounts, advertising, analytics SDKs, tracking, or background recording. Memory-based result recording is separate from saving a raw audio file.
                    """)
                    section("Diagnostics you can share", """
                    Open Diagnostics & copy report from the menu to inspect acquisition, processing, and Metal rendering during or after a run. A bounded history keeps up to 128 recent operational events in memory; older events are overwritten. Inspect JSON report previews the current report locally.

                    The report includes app/build and OS information, a generic device model, audio route types and format, system output volume, relative intervals and normalized sample indices, counters, aggregate input statistics, scalar analysis summaries, and sanitized error codes. Timing values include per-acquisition durations and retained event offsets measured since diagnostics initialization in the current app session. It contains no raw audio samples, spectrum arrays, images, location, route names, account or network identifiers, device identifiers, or absolute system-uptime or host-clock values.

                    Copy Diagnostic Dump places the JSON on the local device’s clipboard only when you tap it. This copy is excluded from Handoff and expires one hour after copying. It can outlive the app’s process. You choose where to paste or share it; the app does not upload it automatically. A copy you paste elsewhere is controlled by that destination.
                    """)
                    section("You control each recording", """
                    Tap Stop at any time. Each recording is limited to 60 seconds of samples and a separate 60-second elapsed-time limit. Changing the carrier frequency does not extend either limit.

                    Leaving the active app stops acquisition and pauses replay. LIVE also stops on audio interruptions, route changes, audio-service changes, or unsupported audio timing or formats. Returning to the app does not restart a capture. You can revoke microphone permission in iOS Settings.
                    """)
                    section("Acoustic method", """
                    The built-in audio route must operate at 48 kHz. Choose a carrier from 18 to 22 kHz in 500 Hz steps. This is an acoustic experiment; the app does not measure radio-frequency signals.

                    The estimator fits a tone to each 2,048-sample window. At 48 kHz this represents about 42.67 ms of samples. Diagnostics reports observed processing and GPU completion rates from event counts and elapsed intervals; a running session or a requested refresh rate does not prove that data is advancing. The JSON contains those counts and relative intervals rather than absolute system-clock values.

                    A frequency change ends the old acquisition and constructs a new one with a fresh phase reference. Phase is not continuous across different carriers. Signal loss, invalid timing, or a capture gap invalidates the reference; recovery establishes a new zero.

                    Relative phase and the phase-derived displacement model depend on sound paths, device response, timing, and motion. The displacement is conditional on a single reflected-path model and is not an independently measured distance. Strong direct speaker-to-microphone coupling does not identify a reflected object.

                    Tone / residual is a fitted-signal quality estimate, not calibrated acoustic SNR. Any quality score is a heuristic, not a confidence probability. Missing phase, device pose, and LiDAR depth are reported as unavailable. Unavailable phase does not mean the microphone input is empty: speech, noise, or other sound can be present without a usable carrier fit. Inspect the input level and Full audio Waterfall to distinguish those cases.
                    """)
                    section("Reading the viewport", """
                    LIVE Field is an abstract graphic of a single acoustic probe’s phase. DEMO Field is an explicitly synthetic illustration. Neither is an image, a spatial reconstruction, or a thermal measurement of your surroundings.

                    Waterfall shows FFT-derived frequency bins from the selected source. Spectrum range selects Full audio · 0–24 kHz or Carrier · 18–22 kHz. Full audio is a display range, not a passive acquisition mode: LIVE still emits the selected carrier. Changing the range does not change the microphone capture or phase estimator.

                    Frequency is horizontal; sample age is vertical, with the newest data at the top. Levels are in digital dBFS, not calibrated sound pressure. Missing intervals are hatched. Display interpolation does not add measured spectral resolution.

                    Gain, persistence, and false-color palettes affect only the display. They never change the microphone signal, emitted tone, synthetic sample amplitude, simulation noise, or stored measurements. Reduce Motion suppresses moving field contours, and Reduce Transparency gives instrument panels opaque backgrounds.
                    """)
                    section("DEMO model", """
                    The default simulation uses a carrier peak amplitude of 0.1, expected signal-to-noise ratio of 30 dB, and sinusoidal modeled displacement of 1 mm at 0.25 Hz. Seeded sample noise makes runs reproducible. Finite-window estimates can differ from the requested full-band SNR.

                    A synthetic field can demonstrate how the controls behave. It provides no observation of an actual object, device position, depth, or room.
                    """)
                    section("Before emitting sound", """
                    Use LIVE only where everyone nearby agrees. Keep the speaker away from ears, begin with low device volume, and stop if uncomfortable. A tone in the 18–22 kHz range is not guaranteed to be inaudible. Headphones and external audio routes are unsupported.

                    LIVE output has a fixed peak amplitude of 0.02 in digital full-scale units, with short fades at the scheduled start and end. Stop or an interruption silences it immediately. This is not a calibrated sound-pressure level; device volume and hardware affect the emitted sound.
                    """)
                    section("Distribution services", "Apple separately operates App Store and TestFlight delivery and feedback services. Apple’s handling of that data is governed by Apple’s policies.")
                }
                .padding(20)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .navigationTitle("Privacy & method")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }
}
