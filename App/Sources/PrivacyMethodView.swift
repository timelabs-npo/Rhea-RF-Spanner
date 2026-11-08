import SwiftUI

@MainActor
struct PrivacyMethodView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Three explicit sources", """
                    LIVE defaults to Listen: local microphone analysis with no generated tone. Tap Start listening to request iOS microphone permission. A first permission grant returns to idle; start again deliberately. Listen requires a physical device and built-in microphone input at 48 kHz. Its recording-only session may suppress other playback on this phone. Calls, alarms, and other nonmixable sessions can still interrupt it.

                    Tone experiment is a separate LIVE choice. It emits the selected speaker tone only after your explicit agreement and Start. Selecting Listen or Tone stops the current run and requires a new Start; the choice never restarts acquisition automatically.

                    DEMO is a silent, deterministic simulation. It generates synthetic samples and passes them through the same signal-processing path as LIVE. It does not request microphone permission, activate an audio session, or emit sound.

                    REPLAY reads retained Tone experiment and DEMO results from memory. Every frame retains its original LIVE or DEMO source. The microphone and speaker are off during replay. Passive Listen Replay is deferred; Listen does not append records to this tape.
                    """)
                    section("Privacy and memory", """
                    LIVE microphone samples can include surrounding sounds, including speech. Listen analyzes input levels and a spectrum without a carrier or phase result. Tone experiment also estimates acoustic phase. The app does not transcribe speech, identify people, save audio files, or automatically upload audio or results.

                    Temporary samples and bounded display history remain in volatile memory. After Stop, Listen history remains visible while that view is kept. Starting a new Listen run, changing mode or acquisition kind, or clearing Replay clears the displayed history. Up to 2,048 active Tone/DEMO result frames and bounded companion spectra are retained for Replay; the oldest result is overwritten when full. Clear replay removes those retained results after capture stops. Closing the app’s process loses the tape and display history.

                    There are no accounts, advertising, analytics SDKs, tracking, or background recording. Memory-based result recording is separate from saving a raw audio file.
                    """)
                    section("Diagnostics you can share", """
                    Open Diagnostics & copy report from the menu to inspect acquisition, processing, and Metal rendering during or after a run. A bounded history keeps up to 128 recent operational events in memory; older events are overwritten. Inspect JSON report previews the current report locally.

                    The report includes app/build and OS information, a generic device model, acquisition kind and transmission state, audio route types and format, system output volume, relative intervals and normalized sample indices, counters, aggregate input statistics, scalar analysis summaries, and sanitized error codes. Timing values include per-acquisition durations and retained event offsets measured since diagnostics initialization in the current app session. Listen normally reports zero source callbacks and transmitted samples. The report contains no raw audio samples, spectrum arrays, images, location, route names or UIDs, account or network identifiers, device identifiers, or absolute system-uptime or host-clock values.

                    Copy Diagnostic Dump places the JSON on the local device’s clipboard only when you tap it. This copy is excluded from Handoff and expires one hour after copying. It can outlive the app’s process. You choose where to paste or share it; the app does not upload it automatically. A copy you paste elsewhere is controlled by that destination.
                    """)
                    section("You control each recording", """
                    Tap Stop at any time. Each run is limited to 60 seconds of samples and a separate 60-second elapsed-time limit. Listen duration advances from captured input samples, independently of transmitted or synthetic samples. A stalled input or processing path stops the session. Changing the active tone’s carrier frequency does not extend its limit.

                    Leaving the active app stops acquisition and pauses replay. LIVE also stops on audio interruptions, route changes, audio-service changes, or unsupported formats. A playback-timing fault stops Tone. Missing Listen timestamps alone do not end the run; levels may remain available while spectra are absent. Returning to the app does not restart a capture. You can revoke microphone permission in iOS Settings.
                    """)
                    section("Acoustic method", """
                    The built-in microphone input must operate at an observed 48 kHz; the requested rate alone is not proof. Listen uses an input-only measurement session without a generated tone. Measurement mode reduces system processing; it does not calibrate microphone sensitivity or frequency response. This is acoustic analysis; the app does not measure radio-frequency signals.

                    Each analysis window contains 2,048 samples, about 42.67 ms at 48 kHz. Spectrum bin spacing is 23.4375 Hz, not a guarantee that two nearby tones are resolved. Finite input levels may be available without valid timestamps; spectra are withheld for invalid timing, internal gaps, or nonfinite samples. A subsequent valid window can recover without filling missing time with invented audio.

                    Diagnostics reports observed processing and GPU completion rates from event counts and elapsed intervals; a running session or requested refresh rate does not prove that data is advancing. The JSON contains counts and relative intervals rather than absolute system-clock values.

                    In Tone experiment, choose a carrier from 18 to 22 kHz in 500 Hz steps. The estimator fits that tone. A frequency change ends the old acquisition and constructs a new one with a fresh phase reference. Phase is not continuous across different carriers. Signal loss, invalid timing, or a capture gap invalidates the reference; recovery establishes a new zero. Listen requests no tone estimate or phase reference.

                    Relative phase and the phase-derived displacement model depend on sound paths, device response, timing, and motion. The displacement is conditional on a single reflected-path model and is not an independently measured distance. Strong direct speaker-to-microphone coupling does not identify a reflected object.

                    Tone / residual is a fitted-signal quality estimate, not calibrated acoustic SNR. Any quality score is a heuristic, not a confidence probability. Missing phase, device pose, and LiDAR depth are reported as unavailable. Unavailable phase does not mean the microphone input is empty: speech, noise, or other sound can be present without a usable carrier fit. Inspect the input level and Full audio Waterfall to distinguish those cases.
                    """)
                    section("Reading the viewport", """
                    Tone experiment Field is an abstract graphic of a single acoustic probe’s phase. DEMO Field is an explicitly synthetic illustration. Neither is an image, a spatial reconstruction, or a thermal measurement of your surroundings. Listen shows Waterfall without phase or carrier controls.

                    Waterfall shows FFT-derived frequency bins from the selected source. Full audio · 0–24 kHz is the digital analysis band, not a claim of calibrated sensitivity across that band. The narrow range is 18–22 kHz in Listen and Carrier · 18–22 kHz in Tone/DEMO. A display range never starts a tone or changes acquisition kind.

                    Frequency is horizontal; sample age is vertical, with the newest data at the top. RMS is in dBFS relative to digital full-scale amplitude 1; peak is a linear full-scale amplitude. A unit-peak sine is about −3.01 dBFS RMS and 0 dBFS bin-centered spectral amplitude. Spectrum is Hann-windowed amplitude dBFS, not calibrated sound pressure or noise power density. Zero is silence; a visible floor is a display convention. Missing intervals are hatched. Display interpolation does not add measured spectral resolution.

                    Gain, persistence, and false-color palettes affect only the display. Display gain is not microphone gain; system output volume is not input gain. These controls never change microphone samples, levels, emitted tone, synthetic sample amplitude, simulation noise, or stored measurements. Reduce Motion suppresses moving field contours, and Reduce Transparency gives instrument panels opaque backgrounds.
                    """)
                    section("DEMO model", """
                    The default simulation uses a carrier peak amplitude of 0.1, expected signal-to-noise ratio of 30 dB, and sinusoidal modeled displacement of 1 mm at 0.25 Hz. Seeded sample noise makes runs reproducible. Finite-window estimates can differ from the requested full-band SNR.

                    A synthetic field can demonstrate how the controls behave. It provides no observation of an actual object, device position, depth, or room.
                    """)
                    section("Before emitting sound", """
                    Use microphone analysis where everyone nearby agrees. Before starting Tone experiment, keep the speaker away from ears, begin with low device volume, and stop if uncomfortable. A tone in the 18–22 kHz range is not guaranteed to be inaudible. External microphones are unsupported; Tone experiment also requires the built-in speaker.

                    Tone experiment output has a fixed peak amplitude of 0.02 in digital full-scale units, with short fades at the scheduled start and end. Stop or an interruption silences it immediately. This is not a calibrated sound-pressure level; device volume and hardware affect the emitted sound. Listen constructs no transmitter. Source and graph evidence alone cannot certify physical absence of near-ultrasonic emissions; that requires an independent instrument with adequate response.
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
