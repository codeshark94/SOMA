@preconcurrency import AVFoundation
import Foundation
import SOMACore

private enum EvaluationError: LocalizedError {
    case invalidArgument(String)
    case invalidManifest(String)
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message), .invalidManifest(let message), .unreadableAudio(let message):
            return message
        }
    }
}

private struct Options {
    let manifestURL: URL

    static func parse(_ arguments: [String]) throws -> Options {
        guard arguments.count == 2, arguments[0] == "--manifest" else {
            throw EvaluationError.invalidArgument("Usage: soma-vad-eval --manifest <labelled-audio.json>")
        }
        return Options(manifestURL: URL(fileURLWithPath: arguments[1]))
    }
}

private enum Label: String, Codable {
    case speech
    case noise
}

private struct LabelledClip: Decodable {
    let id: String
    let path: String
    let label: Label
}

private struct ClipReport: Encodable {
    let id: String
    let label: Label
    let sampleRateHz: Double
    let blocks: Int
    let activeBlocks: Int
    let onsetMS: Double?
}

private struct Counts: Encodable {
    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    var trueNegative = 0

    var precision: Double { ratio(truePositive, truePositive + falsePositive) }
    var recall: Double { ratio(truePositive, truePositive + falseNegative) }
    var f1: Double {
        let sum = precision + recall
        return sum == 0 ? 0 : 2 * precision * recall / sum
    }
    var accuracy: Double { ratio(truePositive + trueNegative, truePositive + falsePositive + falseNegative + trueNegative) }

    private enum CodingKeys: String, CodingKey {
        case truePositive = "true_positive"
        case falsePositive = "false_positive"
        case falseNegative = "false_negative"
        case trueNegative = "true_negative"
        case precision
        case recall
        case f1
        case accuracy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(truePositive, forKey: .truePositive)
        try container.encode(falsePositive, forKey: .falsePositive)
        try container.encode(falseNegative, forKey: .falseNegative)
        try container.encode(trueNegative, forKey: .trueNegative)
        try container.encode(precision, forKey: .precision)
        try container.encode(recall, forKey: .recall)
        try container.encode(f1, forKey: .f1)
        try container.encode(accuracy, forKey: .accuracy)
    }

    private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}

private struct EvaluationReport: Encodable {
    let schemaVersion = 1
    let blockMilliseconds = 16
    let clips: [ClipReport]
    let counts: Counts
}

private func evaluate(_ clip: LabelledClip, baseURL: URL) throws -> (ClipReport, Counts) {
    let url = URL(fileURLWithPath: clip.path, relativeTo: baseURL).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw EvaluationError.invalidManifest("Missing labelled clip: \(url.path)")
    }
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw EvaluationError.unreadableAudio("Cannot read \(url.path): \(error.localizedDescription)")
    }
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32,
          format.sampleRate > 0,
          format.channelCount > 0,
          file.length > 0,
          file.length <= AVAudioFramePosition(UInt32.max),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw EvaluationError.unreadableAudio("Unsupported PCM stream: \(url.path)")
    }
    try file.read(into: buffer)
    guard let channelData = buffer.floatChannelData else {
        throw EvaluationError.unreadableAudio("No float PCM data: \(url.path)")
    }

    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    let blockFrames = max(1, Int((format.sampleRate * 0.016).rounded()))
    let gate = VoiceActivityGate()
    var counts = Counts()
    var activeBlocks = 0
    var onsetMS: Double?
    var monotonicNS: UInt64 = 0
    var blockCount = 0

    for start in stride(from: 0, to: frameCount, by: blockFrames) {
        let end = min(frameCount, start + blockFrames)
        let durationNS = UInt64((Double(end - start) / format.sampleRate * 1_000_000_000).rounded())
        var sumSquares = 0.0
        for frame in start..<end {
            for channel in 0..<channelCount {
                let sample = Double(channelData[channel][frame])
                sumSquares += sample * sample
            }
        }
        let samples = (end - start) * channelCount
        let levelDB = 20 * log10(max(sqrt(sumSquares / Double(samples)), 0.000_001))
        monotonicNS += durationNS
        let evidence = gate.ingest(
            levelDB: levelDB,
            durationNS: durationNS,
            continuous: blockCount > 0,
            at: monotonicNS
        )
        if evidence.active {
            activeBlocks += 1
            if onsetMS == nil { onsetMS = Double(monotonicNS) / 1_000_000 }
        }
        switch (clip.label, evidence.active) {
        case (.speech, true): counts.truePositive += 1
        case (.speech, false): counts.falseNegative += 1
        case (.noise, true): counts.falsePositive += 1
        case (.noise, false): counts.trueNegative += 1
        }
        blockCount += 1
    }
    return (
        ClipReport(
            id: clip.id,
            label: clip.label,
            sampleRateHz: format.sampleRate,
            blocks: blockCount,
            activeBlocks: activeBlocks,
            onsetMS: onsetMS
        ),
        counts
    )
}

private func run(_ options: Options) throws {
    let data = try Data(contentsOf: options.manifestURL)
    let clips: [LabelledClip]
    do {
        clips = try JSONDecoder().decode([LabelledClip].self, from: data)
    } catch {
        throw EvaluationError.invalidManifest("Expected a JSON array of id/path/label clips: \(error.localizedDescription)")
    }
    guard !clips.isEmpty,
          clips.contains(where: { $0.label == .speech }),
          clips.contains(where: { $0.label == .noise }) else {
        throw EvaluationError.invalidManifest("Manifest requires at least one speech clip and one noise clip")
    }
    var reports: [ClipReport] = []
    var totals = Counts()
    for clip in clips {
        let (report, counts) = try evaluate(clip, baseURL: options.manifestURL.deletingLastPathComponent())
        reports.append(report)
        totals.truePositive += counts.truePositive
        totals.falsePositive += counts.falsePositive
        totals.falseNegative += counts.falseNegative
        totals.trueNegative += counts.trueNegative
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(EvaluationReport(clips: reports, counts: totals)), as: UTF8.self))
}

do {
    try run(Options.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    fputs("soma-vad-eval: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
