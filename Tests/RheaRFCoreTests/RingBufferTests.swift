import Dispatch
import Foundation
import Synchronization
import XCTest
@testable import RheaRFCore

private func enqueue(
    _ samples: [Float], into ring: SPSCFloatRingBuffer, at time: UInt64,
    timestampIsValid: Bool = true
) -> Bool {
    samples.withUnsafeBufferPointer {
        ring.write(
            from: $0.baseAddress!, count: $0.count, startSampleTime: time,
            timestampIsValid: timestampIsValid
        )
    }
}

final class RingBufferTests: XCTestCase {
    func testWrappedStoragePreservesSamplesAndCaptureTime() throws {
        let ring = SPSCFloatRingBuffer(capacity: 8)
        XCTAssertTrue(enqueue([0, 1, 2, 3, 4, 5], into: ring, at: 100))
        var first = [Float](repeating: -1, count: 4)
        let firstRead = first.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: $0.count)
        }
        XCTAssertEqual(first, [0, 1, 2, 3])
        XCTAssertEqual(try XCTUnwrap(firstRead).startSampleTime, 100)
        XCTAssertTrue(enqueue([6, 7, 8, 9, 10, 11], into: ring, at: 106))

        var second = [Float](repeating: -1, count: 8)
        let secondRead = try XCTUnwrap(second.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: $0.count)
        })
        XCTAssertEqual(second, [4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(secondRead.startSampleTime, 104)
        XCTAssertEqual(secondRead.nextSampleTime, 112)
        XCTAssertTrue(secondRead.samplesAreContiguous)
        XCTAssertTrue(secondRead.timestampsAreValid)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testOverflowRejectsWholeBlockWithoutOverwritingUnreadData() throws {
        let ring = SPSCFloatRingBuffer(capacity: 8)
        XCTAssertTrue(enqueue(Array(0..<8).map(Float.init), into: ring, at: 0))
        XCTAssertFalse(enqueue([8, 9, 10], into: ring, at: 8))
        XCTAssertEqual(ring.droppedWriteBlocks, 1)
        XCTAssertEqual(ring.droppedWriteSamples, 3)
        var output = [Float](repeating: -1, count: 8)
        let read = try XCTUnwrap(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: $0.count)
        })
        XCTAssertEqual(output, Array(0..<8).map(Float.init))
        XCTAssertEqual(read.nextSampleTime, 8)
        XCTAssertTrue(enqueue([11, 12, 13, 14], into: ring, at: 11))
        let nextRead = try XCTUnwrap(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 4)
        })
        XCTAssertEqual(nextRead.startSampleTime, 11, "Lost samples must not compress capture time.")
    }

    func testGapWithinAReadIsReported() throws {
        let ring = SPSCFloatRingBuffer(capacity: 8)
        XCTAssertTrue(enqueue([1, 2, 3, 4], into: ring, at: 0))
        XCTAssertTrue(enqueue([5, 6, 7, 8], into: ring, at: 9))
        var output = [Float](repeating: 0, count: 8)
        let read = try XCTUnwrap(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 8)
        })
        XCTAssertFalse(read.samplesAreContiguous)
        XCTAssertTrue(read.timestampsAreValid)
        XCTAssertEqual(read.nextSampleTime, 13)
    }

    func testMissingTimestampCannotBecomeAValidTimeline() throws {
        let ring = SPSCFloatRingBuffer(capacity: 8)
        XCTAssertTrue(enqueue([1, 2, 3, 4], into: ring, at: 0, timestampIsValid: false))
        XCTAssertTrue(enqueue([5, 6, 7, 8], into: ring, at: 4))
        var output = [Float](repeating: 0, count: 8)
        let read = try XCTUnwrap(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 8)
        })
        XCTAssertTrue(read.samplesAreContiguous)
        XCTAssertFalse(read.timestampsAreValid)
    }

    func testEmptyPollDoesNotConsumePartialFrameOrInventDrops() throws {
        let ring = SPSCFloatRingBuffer(capacity: 8)
        XCTAssertTrue(enqueue([1, 2, 3], into: ring, at: 50))
        var output = [Float](repeating: -1, count: 4)
        let missing = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 4)
        }
        XCTAssertNil(missing)
        XCTAssertEqual(ring.availableToRead, 3)
        XCTAssertEqual(ring.droppedWriteBlocks, 0)
        XCTAssertTrue(enqueue([4], into: ring, at: 53))
        let read = try XCTUnwrap(output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 4)
        })
        XCTAssertEqual(output, [1, 2, 3, 4])
        XCTAssertEqual(read.startSampleTime, 50)
    }

    func testConcurrentProducerAndConsumerPreserveOrder() {
        final class State: @unchecked Sendable {
            let stop = Atomic<Bool>(false)
            let errors = Atomic<Int>(0)
        }
        let state = State()
        let ring = SPSCFloatRingBuffer(capacity: 1_024)
        let group = DispatchGroup()
        let total = 100_000

        DispatchQueue(label: "test.ring.producer").async(group: group) {
            var offset = 0
            while offset < total && !state.stop.load(ordering: .relaxed) {
                let count = min(257, total - offset)
                let values = (offset..<(offset + count)).map(Float.init)
                while !enqueue(values, into: ring, at: UInt64(offset)) {
                    if state.stop.load(ordering: .relaxed) { return }
                    Thread.sleep(forTimeInterval: 0.000_01)
                }
                offset += count
            }
        }
        DispatchQueue(label: "test.ring.consumer").async(group: group) {
            var offset = 0
            var values = [Float](repeating: 0, count: 193)
            while offset < total && !state.stop.load(ordering: .relaxed) {
                let count = min(values.count, total - offset)
                guard let read = values.withUnsafeMutableBufferPointer({
                    ring.read(into: $0.baseAddress!, count: count)
                }) else {
                    Thread.sleep(forTimeInterval: 0.000_01)
                    continue
                }
                if read.startSampleTime != UInt64(offset)
                    || !read.samplesAreContiguous || !read.timestampsAreValid {
                    state.errors.wrappingAdd(1, ordering: .relaxed)
                }
                for index in 0..<count where values[index] != Float(offset + index) {
                    state.errors.wrappingAdd(1, ordering: .relaxed)
                }
                offset += count
            }
        }

        let completed = group.wait(timeout: .now() + 15) == .success
        if !completed {
            state.stop.store(true, ordering: .relaxed)
            _ = group.wait(timeout: .now() + 2)
        }
        XCTAssertTrue(completed, "The producer/consumer stress run timed out.")
        XCTAssertEqual(state.errors.load(ordering: .relaxed), 0)
    }
}
