import Foundation

public struct DirectGazeConsensusSample: Equatable, Sendable {
    public let rect: NormalizedRect
    public let evidence: VisualGazeEvidence
    public let capturedNS: UInt64

    public init(rect: NormalizedRect, evidence: VisualGazeEvidence, capturedNS: UInt64) {
        self.rect = rect
        self.evidence = evidence
        self.capturedNS = capturedNS
    }
}

/// Stabilizes direct-gaze evidence across independent camera captures. Reusing
/// one landmark result across several L0 frames cannot satisfy the consensus.
public struct DirectGazeConsensus: Sendable {
    private struct Track: Sendable {
        var rect: NormalizedRect
        var lastCaptureNS: UInt64
        var consecutiveDirectSamples: Int
    }

    private let requiredIndependentSamples: Int
    private let maximumInterSampleNS: UInt64
    private var tracks: [Track] = []

    public init(
        requiredIndependentSamples: Int = 2,
        maximumInterSampleMilliseconds: UInt64 = 350
    ) {
        precondition(requiredIndependentSamples >= 2)
        precondition(maximumInterSampleMilliseconds > 0)
        self.requiredIndependentSamples = requiredIndependentSamples
        self.maximumInterSampleNS = maximumInterSampleMilliseconds * 1_000_000
    }

    /// Returns one stabilized state per input sample, preserving input order.
    /// Averted or unavailable evidence immediately breaks a direct-gaze run.
    public mutating func stabilize(_ samples: [DirectGazeConsensusSample]) -> [VisualGazeEvidence] {
        guard !samples.isEmpty else {
            tracks.removeAll()
            return []
        }

        let newestCaptureNS = samples.map(\.capturedNS).max() ?? 0
        tracks.removeAll { track in
            newestCaptureNS > track.lastCaptureNS
                && newestCaptureNS - track.lastCaptureNS > maximumInterSampleNS
        }

        var claimedTrackIndices = Set<Int>()
        return samples.map { sample in
            let trackIndex = tracks.indices
                .filter { !claimedTrackIndices.contains($0) }
                .max { lhs, rhs in
                    overlap(tracks[lhs].rect, sample.rect) < overlap(tracks[rhs].rect, sample.rect)
                }
                .flatMap { overlap(tracks[$0].rect, sample.rect) >= 0.10 ? $0 : nil }

            let index: Int
            if let trackIndex {
                index = trackIndex
                claimedTrackIndices.insert(trackIndex)
            } else {
                tracks.append(Track(
                    rect: sample.rect,
                    lastCaptureNS: 0,
                    consecutiveDirectSamples: 0
                ))
                index = tracks.index(before: tracks.endIndex)
                claimedTrackIndices.insert(index)
            }

            var track = tracks[index]
            let isIndependentCapture = sample.capturedNS > track.lastCaptureNS
            let continuesRun = isIndependentCapture
                && sample.capturedNS - track.lastCaptureNS <= maximumInterSampleNS

            switch sample.evidence {
            case .direct:
                if isIndependentCapture {
                    track.consecutiveDirectSamples = continuesRun
                        ? track.consecutiveDirectSamples + 1
                        : 1
                    track.lastCaptureNS = sample.capturedNS
                }
            case .averted, .unavailable:
                track.consecutiveDirectSamples = 0
                if isIndependentCapture {
                    track.lastCaptureNS = sample.capturedNS
                }
            }
            track.rect = sample.rect
            tracks[index] = track

            guard sample.evidence == .direct else { return sample.evidence }
            return track.consecutiveDirectSamples >= requiredIndependentSamples
                ? .direct
                : .unavailable
        }
    }

    private func overlap(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
