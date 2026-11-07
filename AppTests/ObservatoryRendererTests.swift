import MetalKit
import RheaRFCore
import XCTest
@testable import RheaRFSpanner

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
        renderer: MetalPhaseRenderer, view: MTKView
    ) {
        let timestamp = current?.sampleTimestamp ?? history.last?.sampleTimestamp ?? 0
        let slice = SpatioTemporalSlice(
            sampleTimestamp: timestamp, unwrappedPhase: 0,
            normalizedAmplitude: 0.1, coherenceSNR: 30, carrierFrequencyHz: 20_000,
            qualityScore: 1, epoch: 1, source: .simulated, validity: .valid
        )
        renderer.update(
            view: view, slice: slice, spectrum: current, history: history,
            display: DisplayParameters(), presentation: .waterfall,
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
}
