import SwiftUI

@MainActor
struct PrivacyMethodView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Privacy", """
                    Rhea RF Spanner analyzes microphone samples on this device during an experiment you start. The microphone can also receive surrounding sounds, including speech. The app uses these samples for acoustic phase analysis; it does not transcribe speech, identify people, save audio files, or upload audio or measurement results.

                    Samples and current measurements are held in volatile memory. The app includes no account system, advertising, analytics SDK, tracking, or background recording.
                    """)
                    section("You control each experiment", """
                    The microphone and 20 kHz speaker tone operate together only after you agree, tap Start experiment, and grant iOS microphone permission. When permission is first granted, tap Start experiment again to begin. Tap Stop experiment at any time.

                    Each experiment ends after at most 60 seconds of sampled audio. Leaving the active app, an audio interruption, a route change, or an audio-service reset ends the experiment. Returning to the app does not restart it. You can revoke microphone permission in iOS Settings.
                    """)
                    section("Method and limits", """
                    This is an acoustic phase experiment using the built-in speaker and microphone at 48 kHz. The speaker emits a continuous 20 kHz tone. The app does not measure radio-frequency signals.

                    Relative phase and the phase-derived displacement model are affected by sound paths, device response, timing, and movement. The displayed displacement is not an independently measured distance. A strong tone can be direct speaker-to-microphone coupling; it does not prove that a reflected path or object has been identified.

                    The displayed quality is a fitted-tone to residual estimate, not a calibrated acoustic signal-to-noise ratio. Signal loss or a capture gap invalidates the phase reference. The next valid estimate establishes a new zero.

                    The animated wave is an abstract visualization, not an image of your surroundings. Reduce Motion in iOS accessibility settings disables continuous animation.
                    """)
                    section("Before emitting sound", """
                    Use the experiment only where everyone nearby agrees. Keep the speaker away from ears, begin with low device volume, and stop if the sound is uncomfortable. A 20 kHz tone is not guaranteed to be inaudible. Do not use headphones or external audio routes for this experiment.

                    The generated signal has a fixed peak amplitude of 0.02 in digital full-scale units with a short fade at the scheduled start and end. Stop or an interruption silences it immediately. This is not a calibrated sound-pressure level. Device volume and hardware affect the emitted sound.
                    """)
                    section("Distribution services", """
                    Apple separately operates App Store and TestFlight delivery and feedback services. Apple's handling of data is governed by Apple's policies.
                    """)
                }
                .padding(20)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }
}
