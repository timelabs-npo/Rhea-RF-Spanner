# Observatory validation

This file concerns the Observatory feature branch, not the earlier 18-test
baseline. It must be updated with the actual commit and results before a release.

## Planned evidence

- Swift 6 portable core build and tests, including all nine carrier frequencies,
  large timestamps, synthetic noise, spectra, wire decoding, and tape wrap.
- Xcode 26.3 simulator Debug and unsigned device Release builds.
- Actual simulator launches and captures of idle, silent DEMO, and Waterfall.
- Review of mode transitions, explicit consent, and original provenance during Replay.

## Still requiring a physical iPhone and distribution credentials

- Speaker/microphone response across the selected 18–22 kHz grid, actual route
  formats, tone audibility, interruption handling, and phase stability.
- Frame pacing, thermal behavior, and accessibility on supported devices.
- Registered Apple team/bundle, signed archive, TestFlight upload/review, and
  completed support/privacy contact metadata.

An unsigned build or a simulator screenshot does not establish these outcomes.
