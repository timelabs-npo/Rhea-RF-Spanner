import Foundation
import MetalKit
import RheaRFCore
import XCTest
@testable import RheaRFSpanner

@MainActor
private final class RendererTestClock {
    var now: TimeInterval

    init(now: TimeInterval) { self.now = now }
}

/// Inspect the actual uploaded shared texture, so these regressions cover
/// invalidation, row caching, temporal resampling, and upload together.
@MainActor
final class ObservatoryRendererTests: XCTestCase {
    private let hop = UInt64(RadarConfiguration.standard.frameSize)

    private func frame(slot: Int, level: Float) -> SpectrumFrame {
        SpectrumFrame(
            sampleTimestamp: UInt64(slot) * hop,
            frequenciesHz: [18_000, 20_000, 22_000],
            magnitudesDBFS: [level, level, level]
        )
    }

    private func show(
        _ history: [SpectrumFrame], current: SpectrumFrame? = nil,
        renderer: MetalPhaseRenderer, view: MTKView,
        band: SpectrumDisplayBand = .carrier
    ) {
        let timestamp = current?.sampleTimestamp ?? history.last?.sampleTimestamp ?? 0
        let slice = SpatioTemporalSlice(
            sampleTimestamp: timestamp, unwrappedPhase: 0,
            normalizedAmplitude: 0.1, coherenceSNR: 30, carrierFrequencyHz: 20_000,
            qualityScore: 1, epoch: 1, source: .simulated, validity: .valid
        )
        renderer.update(
            view: view, slice: slice, spectrum: current, history: history,
            display: DisplayParameters(spectrumBand: band), presentation: .waterfall,
            active: true, reduceMotion: true
        )
    }

    func testReplacementSpectrumWithSameTimestampUpdatesUploadedBins() throws {
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        let original = frame(slot: 0, level: -70)
        show([original], current: original, renderer: renderer, view: view)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels.first?.x, -70)

        // A replacement current frame must win over stale history even when
        // source, epoch, timestamps, count, and frequency bins are unchanged.
        let replacement = frame(slot: 0, level: -12)
        show([original], current: replacement, renderer: renderer, view: view)
        let replaced = renderer.copyWaterfallPixels()
        XCTAssertEqual(replaced.pixels.first, SIMD2<Float>(-12, 1))

        // The content check must also refresh the per-timestamp row cache when
        // the replacement arrives through history, without an explicit current.
        let revisedHistory = frame(slot: 0, level: -33)
        show([revisedHistory], renderer: renderer, view: view)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels.first, SIMD2<Float>(-33, 1))
    }

    func testSingleMissingFrameRemainsUnavailableWhenHistoryIsCompressed() throws {
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        // 256 retained frames span 257 analysis slots. Point-only nearest-row
        // sampling used to fill every output row, hiding missing slot 128.
        let history = (0...256).filter { $0 != 128 }.map { frame(slot: $0, level: -30) }
        show(history, renderer: renderer, view: view)
        let image = renderer.copyWaterfallPixels()
        XCTAssertEqual(image.height, 256)
        let missingRows = (0..<image.height).filter { row in
            image.pixels[row * image.width].y == 0
        }
        XCTAssertFalse(missingRows.isEmpty, "Compression must not erase a capture gap")
        XCTAssertTrue(missingRows.allSatisfy { (126...129).contains($0) })
        XCTAssertEqual(image.pixels.first?.y, 1)
        XCTAssertEqual(image.pixels.last?.y, 1)
        for row in missingRows {
            let range = (row * image.width)..<((row + 1) * image.width)
            XCTAssertTrue(image.pixels[range].allSatisfy { $0.y == 0 })
        }
    }

    func testContiguousHistoryStaysAvailableAndNewestIsAtTop() throws {
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        let history = (0..<256).map { frame(slot: $0, level: -100 + Float($0) / 4) }
        show(history, renderer: renderer, view: view)
        let image = renderer.copyWaterfallPixels()
        XCTAssertEqual(image.height, 256)
        XCTAssertTrue(image.pixels.allSatisfy { $0.y == 1 })
        XCTAssertEqual(image.pixels.first?.x, history.last?.magnitudesDBFS.first)
        XCTAssertEqual(image.pixels.last?.x, history.first?.magnitudesDBFS.first)
    }

    func testChangingDisplayBandInvalidatesSameTimestampSpectrumRows() throws {
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        let spectrum = SpectrumFrame(
            sampleTimestamp: 0,
            frequenciesHz: [0, 1_000, 18_000, 20_000, 22_000, 24_000],
            magnitudesDBFS: [-80, -10, -60, -20, -40, -90]
        )
        show([spectrum], renderer: renderer, view: view, band: .carrier)
        let carrier = renderer.copyWaterfallPixels()
        XCTAssertEqual(carrier.pixels.first, SIMD2<Float>(-60, 1))
        XCTAssertEqual(carrier.pixels.last, SIMD2<Float>(-40, 1))

        // No new samples, timestamps, epochs, or source identities arrive.
        // Changing the frequency axis must still replace the uploaded bins.
        show([spectrum], renderer: renderer, view: view, band: .fullBand)
        let full = renderer.copyWaterfallPixels()
        XCTAssertEqual(full.pixels.first, SIMD2<Float>(-80, 1))
        XCTAssertEqual(full.pixels.last, SIMD2<Float>(-90, 1))
        XCTAssertEqual(full.pixels.map(\.x).max(), -10)
        XCTAssertEqual(view.accessibilityLabel, "Spectrum waterfall, 0 to 24 kilohertz")

        show([spectrum], renderer: renderer, view: view, band: .carrier)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels, carrier.pixels)
    }

    func testFullBandDownsamplingPreservesNarrowMeasuredPeakAndUnavailableCell() throws {
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        let frequencies = (0...1_024).map { Float($0) * 23.4375 }
        var levels = Array(repeating: Float(-100), count: frequencies.count)
        // The old nearest-only reduction selected bin 0, then bin 2, silently
        // dropping this measured peak when 1,025 bins became 512 columns.
        levels[1] = -6
        let spectrum = SpectrumFrame(sampleTimestamp: 0, frequenciesHz: frequencies, magnitudesDBFS: levels)
        show([spectrum], renderer: renderer, view: view, band: .fullBand)
        let image = renderer.copyWaterfallPixels()
        XCTAssertEqual(image.pixels.first, SIMD2<Float>(-6, 1))
        XCTAssertEqual(image.pixels.map(\.x).max(), -6)

        // An unknown bin must not be hidden by a valid neighbour in its cell.
        levels[1] = .nan
        let unavailable = SpectrumFrame(sampleTimestamp: 0, frequenciesHz: frequencies, magnitudesDBFS: levels)
        show([unavailable], renderer: renderer, view: view, band: .fullBand)
        let missing = renderer.copyWaterfallPixels()
        XCTAssertEqual(missing.pixels.first?.y, 0)
        XCTAssertTrue(missing.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testMissingDrawableDoesNotClaimSubmittedOrCompletedFrame() throws {
        let diagnostics = RendererDiagnostics()
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view, diagnostics: diagnostics)
        XCTAssertEqual(diagnostics.snapshot().setupStatus, "ready")
        XCTAssertEqual(diagnostics.snapshot().submittedFrames, 0)
        // A missing drawable can occur while hidden or resizing. Deliberately
        // remove the view's device to make this boundary deterministic.
        view.device = nil
        renderer.draw(in: view)
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.drawRequests, 1)
        XCTAssertEqual(snapshot.noDrawableCount, 1)
        XCTAssertEqual(snapshot.submittedFrames, 0)
        XCTAssertEqual(snapshot.completedFrames, 0)
        XCTAssertEqual(snapshot.measuredCompletedFramesPerSecond, 0)
        XCTAssertEqual(snapshot.errorStage, "draw.drawable")
    }

    func testCompletionRateExcludesFailuresAndExportsOnlyElapsedInterval() throws {
        let clock = RendererTestClock(now: 500)
        let diagnostics = RendererDiagnostics(clock: { clock.now })
        diagnostics.recordSubmittedFrame(sampleTimestamp: 0)
        diagnostics.recordCompletion(succeeded: true)
        clock.now = 500.5
        diagnostics.recordSubmittedFrame(sampleTimestamp: hop)
        diagnostics.recordCompletion(succeeded: false, errorDomain: "private/path/example", errorCode: 7)
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 2)
        XCTAssertEqual(snapshot.completedFrames, 1)
        XCTAssertEqual(snapshot.failedFrames, 1)
        XCTAssertEqual(snapshot.completedFramesInWindow, 1)
        XCTAssertEqual(snapshot.frameRateWindowSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.measuredCompletedFramesPerSecond, 2, accuracy: 1e-9)
        XCTAssertEqual(snapshot.errorDomain, "OtherSystemError")
        XCTAssertEqual(snapshot.errorCode, 7)

        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["measuredCompletedFramesPerSecond"])
        XCTAssertEqual(json["frameRateWindowSeconds"] as? Double, 0.5)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private/path"))

        clock.now = 502.25
        let expired = diagnostics.snapshot()
        XCTAssertEqual(expired.completedFrames, 1)
        XCTAssertEqual(expired.completedFramesInWindow, 0)
        XCTAssertEqual(expired.measuredCompletedFramesPerSecond, 0)
        // Clock faults must not poison JSON with a nonfinite elapsed interval.
        clock.now = .infinity
        XCTAssertNoThrow(try JSONEncoder().encode(diagnostics.snapshot()))
    }

    func testDelayedActorDeliveryDoesNotMakeAnExpiredCompletionRecent() throws {
        let clock = RendererTestClock(now: 500)
        let diagnostics = RendererDiagnostics(clock: { clock.now })
        // Metal completed at t=500; MainActor could only handle it at t=503.
        clock.now = 503
        diagnostics.recordCompletion(succeeded: true, completedAt: 500)
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.completedFrames, 1)
        XCTAssertEqual(snapshot.completedFramesInWindow, 0)
        XCTAssertEqual(snapshot.measuredCompletedFramesPerSecond, 0)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["completedAt"])
        XCTAssertNil(json["origin"])
        XCTAssertNil(json["systemUptime"])
    }

    func testOutOfOrderCompletionCannotOverwriteANewerCircularBucket() {
        let clock = RendererTestClock(now: 500)
        let diagnostics = RendererDiagnostics(clock: { clock.now })
        clock.now = 503
        diagnostics.recordCompletion(succeeded: true, completedAt: 502.5)
        // t=500.5 and t=502.5 map to the same slot, two seconds apart. An
        // expired callback delivered later must preserve the recent count.
        diagnostics.recordCompletion(succeeded: true, completedAt: 500.5)
        diagnostics.recordCompletion(succeeded: true, completedAt: 502)
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.completedFrames, 3)
        XCTAssertEqual(snapshot.completedFramesInWindow, 2)
        XCTAssertEqual(snapshot.measuredCompletedFramesPerSecond,
                       2 / snapshot.frameRateWindowSeconds, accuracy: 1e-9)
        // Both actual completions have expired even though their main-actor
        // delivery at t=503 would still be within the current rolling window.
        clock.now = 504.5
        XCTAssertEqual(diagnostics.snapshot().completedFramesInWindow, 0)
        XCTAssertEqual(diagnostics.snapshot().completedFrames, 3)
    }

    func testInvalidCompletionTimesAffectLifetimeOnly() throws {
        let clock = RendererTestClock(now: 500)
        let diagnostics = RendererDiagnostics(clock: { clock.now })
        clock.now = 503
        let invalidTimes: [TimeInterval] = [.nan, .infinity, -.infinity, 499, 504]
        for completionTime in invalidTimes {
            diagnostics.recordCompletion(succeeded: true, completedAt: completionTime)
        }
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.completedFrames, 5)
        XCTAssertEqual(snapshot.completedFramesInWindow, 0)
        XCTAssertEqual(snapshot.measuredCompletedFramesPerSecond, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }
}
