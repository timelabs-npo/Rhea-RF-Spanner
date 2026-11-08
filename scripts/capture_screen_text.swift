// Native CI helper: recognize visible text in an actual Simulator screenshot.
// Compile on macOS with the installed Xcode SDK; no network or extra packages.
// Apple APIs: https://developer.apple.com/documentation/vision/recognizing-text-in-images
// https://developer.apple.com/documentation/vision/vnimagerequesthandler
import Darwin
import Foundation
import Vision

private struct RecognizedLine: Encodable {
    let text: String
    let confidence: Float
}

private struct ScreenText: Encodable {
    let engine: String
    let revision: Int
    let lines: [RecognizedLine]
}

@main
private enum CaptureScreenText {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fail("Usage: capture-screen-text <screenshot.png>")
        }
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(text: candidate.string, confidence: candidate.confidence)
            }
            let output = ScreenText(engine: "Apple Vision VNRecognizeTextRequest",
                                    revision: Int(request.revision), lines: lines)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fail("Screenshot text recognition failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
