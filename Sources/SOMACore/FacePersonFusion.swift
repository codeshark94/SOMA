import Foundation

/// Combines a close-range face measurement with the faster person detector.
/// A confirmed face keeps its own small rectangle; the enclosing person box is
/// used only to bridge the short interval before the next face-model result.
/// This is deliberately not identity recognition and expires quickly when the
/// face model provides no renewed evidence.
public struct FacePersonFusion: Sendable {
    private struct Anchor: Sendable {
        var faceRect: NormalizedRect
        var personRect: NormalizedRect
        var confidence: Double
        let freshFaceNS: UInt64
        var validated: Bool
        var lastHumanEvidenceNS: UInt64
    }

    private var anchor: Anchor?
    private let bridgeNS: UInt64
    private let persistentBridgeAbsenceNS: UInt64

    public init(bridgeMilliseconds: UInt64 = 320, persistentBridgeAbsenceMilliseconds: UInt64 = 2_000) {
        bridgeNS = bridgeMilliseconds * 1_000_000
        persistentBridgeAbsenceNS = persistentBridgeAbsenceMilliseconds * 1_000_000
    }

    /// Only an independently verified face may promote a body association to
    /// a persistent re-acquisition bridge. Once promoted, ordinary stillness
    /// cannot release it; loss requires the paired person evidence itself to
    /// disappear continuously.
    public mutating func promoteValidatedFace(_ rect: NormalizedRect, at monotonicNS: UInt64) {
        guard var anchor, matches(anchor, rect: rect) else { return }
        anchor.faceRect = rect
        anchor.validated = true
        anchor.lastHumanEvidenceNS = monotonicNS
        self.anchor = anchor
    }

    /// Matched person boxes are intentionally removed from this frame: a face
    /// should remain the single motor target instead of alternating with its
    /// larger enclosing body box. Unmatched people and all non-human evidence
    /// are preserved for the local scene field.
    public mutating func fuse(_ observations: [VisualObservation], at monotonicNS: UInt64) -> [VisualObservation] {
        let faces = observations.filter(isFace)
        let persons = observations.filter(isPerson)
        var output = observations.filter { !isFace($0) && !isPerson($0) }
        var consumedPersonIndices = Set<Int>()

        for face in faces {
            if let index = bestContainingPerson(for: face, in: persons, excluding: consumedPersonIndices) {
                let person = persons[index]
                consumedPersonIndices.insert(index)
                let confidence = min(0.999, max(face.confidence, 0.65 * face.confidence + 0.35 * person.confidence))
                let fusedFace = VisualObservation(
                    rect: face.rect,
                    confidence: confidence,
                    source: .neuralFaceDetector,
                    kind: .human,
                    label: "face",
                    attentionWeight: face.attentionWeight,
                    posteriorProbability: face.posteriorProbability,
                    sceneID: face.sceneID,
                    stabilityMilliseconds: face.stabilityMilliseconds,
                    // A face enclosed by an independent person detection is
                    // strong enough to own the L0 motor loop.
                    isActionEligible: true
                )
                anchor = Anchor(
                    faceRect: face.rect,
                    personRect: person.rect,
                    confidence: confidence,
                    freshFaceNS: monotonicNS,
                    validated: false,
                    lastHumanEvidenceNS: monotonicNS
                )
                output.append(fusedFace)
            } else if let anchor,
                      isCurrent(anchor, at: monotonicNS),
                      matches(anchor, face: face) {
                // BlazeFace runs more often than the person detector. A
                // nearby fresh face may retain the last independently
                // confirmed person pairing only for that detector-cadence
                // interval. Crucially, this does not extend the pairing's
                // timestamp: a face-only false positive cannot keep motor
                // authority alive indefinitely.
                let confidence = min(0.999, max(face.confidence, anchor.confidence * 0.85))
                output.append(VisualObservation(
                    rect: face.rect,
                    confidence: confidence,
                    source: .neuralFaceDetector,
                    kind: .human,
                    label: "face",
                    attentionWeight: face.attentionWeight,
                    posteriorProbability: face.posteriorProbability,
                    sceneID: face.sceneID,
                    stabilityMilliseconds: face.stabilityMilliseconds,
                    isActionEligible: true
                ))
                self.anchor = Anchor(
                    faceRect: face.rect,
                    personRect: anchor.personRect,
                    confidence: confidence,
                    freshFaceNS: anchor.freshFaceNS,
                    validated: anchor.validated,
                    lastHumanEvidenceNS: anchor.validated ? monotonicNS : anchor.lastHumanEvidenceNS
                )
            } else {
                // A lone face stays available to the scene field, but cannot
                // command the gimbal. In live testing this prevents a
                // face-shaped texture from locking the camera away from a
                // person. Only a current person+face pairing can grant L0
                // motor authority.
                if anchor?.validated != true { anchor = nil }
                output.append(unpairedFace(face))
            }
        }

        if faces.isEmpty, let anchor {
            let shortBridgeActive = monotonicNS >= anchor.freshFaceNS
                && monotonicNS - anchor.freshFaceNS <= bridgeNS
            let persistentBridgeActive = anchor.validated
                && monotonicNS >= anchor.lastHumanEvidenceNS
                && monotonicNS - anchor.lastHumanEvidenceNS <= persistentBridgeAbsenceNS
            if (shortBridgeActive || persistentBridgeActive),
               let index = bestBridgePerson(for: anchor, in: persons, excluding: consumedPersonIndices) {
                let person = persons[index]
                consumedPersonIndices.insert(index)
                let bridgedRect = translatedFace(
                    anchor.faceRect,
                    from: anchor.personRect,
                    to: person.rect,
                    persistent: anchor.validated
                )
                let confidence = min(anchor.confidence * 0.90, person.confidence)
                output.append(VisualObservation(
                    rect: bridgedRect,
                    confidence: confidence,
                    source: .tracker,
                    kind: .human,
                    label: "face",
                    // Only a previously System-Vision-validated face may
                    // turn a continuing person box into long-lived motor
                    // evidence. The short raw bridge remains unchanged.
                    isActionEligible: true,
                    isFaceVerified: anchor.validated
                ))
                self.anchor = Anchor(
                    faceRect: bridgedRect,
                    personRect: person.rect,
                    confidence: confidence,
                    freshFaceNS: anchor.freshFaceNS,
                    validated: anchor.validated,
                    lastHumanEvidenceNS: monotonicNS
                )
            } else if !anchor.validated && !shortBridgeActive {
                self.anchor = nil
            } else if anchor.validated,
                      monotonicNS >= anchor.lastHumanEvidenceNS,
                      monotonicNS - anchor.lastHumanEvidenceNS > persistentBridgeAbsenceNS {
                self.anchor = nil
            }
        }

        for (index, person) in persons.enumerated() where !consumedPersonIndices.contains(index) {
            output.append(person)
        }
        return output
    }

    private func isFace(_ observation: VisualObservation) -> Bool {
        observation.kind == .human
            && (observation.label == "face" || observation.source == .neuralFaceDetector)
    }

    private func isPerson(_ observation: VisualObservation) -> Bool {
        observation.kind == .human && observation.label == "person"
    }

    private func bestContainingPerson(
        for face: VisualObservation,
        in persons: [VisualObservation],
        excluding excluded: Set<Int>
    ) -> Int? {
        persons.indices
            .filter { index in !excluded.contains(index) && contains(persons[index].rect, face.rect.centerX, face.rect.centerY) }
            .min { lhs, rhs in
                distance(face.rect, persons[lhs].rect) < distance(face.rect, persons[rhs].rect)
            }
    }

    private func bestBridgePerson(
        for anchor: Anchor,
        in persons: [VisualObservation],
        excluding excluded: Set<Int>
    ) -> Int? {
        persons.indices
            .filter { index in
                guard !excluded.contains(index) else { return false }
                let person = persons[index].rect
                return overlap(person, anchor.personRect) >= 0.20
                    || contains(person, anchor.faceRect.centerX, anchor.faceRect.centerY)
            }
            .max { lhs, rhs in persons[lhs].confidence < persons[rhs].confidence }
    }

    private func isCurrent(_ anchor: Anchor, at monotonicNS: UInt64) -> Bool {
        monotonicNS >= anchor.freshFaceNS
            && monotonicNS - anchor.freshFaceNS <= bridgeNS
    }

    private func matches(_ anchor: Anchor, face: VisualObservation) -> Bool {
        matches(anchor, rect: face.rect)
    }

    private func matches(_ anchor: Anchor, rect: NormalizedRect) -> Bool {
        let overlap = overlap(anchor.faceRect, rect)
        if overlap >= 0.10 { return true }
        let centreDistance = distance(anchor.faceRect, rect)
        let areaRatio = (rect.width * rect.height)
            / max(anchor.faceRect.width * anchor.faceRect.height, 0.000_001)
        return centreDistance <= 0.18 && areaRatio >= 0.45 && areaRatio <= 2.25
    }

    private func unpairedFace(_ face: VisualObservation) -> VisualObservation {
        VisualObservation(
            rect: face.rect,
            confidence: face.confidence,
            source: face.source,
            kind: .human,
            label: "face",
            attentionWeight: face.attentionWeight,
            posteriorProbability: face.posteriorProbability,
            sceneID: face.sceneID,
            stabilityMilliseconds: face.stabilityMilliseconds,
            isActionEligible: false,
            isFaceVerified: face.isFaceVerified
        )
    }

    private func translatedFace(
        _ face: NormalizedRect,
        from oldPerson: NormalizedRect,
        to newPerson: NormalizedRect,
        persistent: Bool
    ) -> NormalizedRect {
        // The body detector is less precise than BlazeFace. Use only a damped
        // body-centre delta, bounded to prevent one loose body box from making
        // a face jump across the frame.
        let gain = persistent ? 0.95 : 0.65
        let maximumDelta = persistent ? 0.22 : 0.12
        let dx = min(maximumDelta, max(-maximumDelta, (newPerson.centerX - oldPerson.centerX) * gain))
        let dy = min(maximumDelta, max(-maximumDelta, (newPerson.centerY - oldPerson.centerY) * gain))
        return NormalizedRect(
            x: min(max(face.x + dx, 0), max(0, 1 - face.width)),
            y: min(max(face.y + dy, 0), max(0, 1 - face.height)),
            width: face.width,
            height: face.height
        )
    }

    private func contains(_ rect: NormalizedRect, _ x: Double, _ y: Double) -> Bool {
        x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
    }

    private func distance(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY)
    }

    private func overlap(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        let intersection = width * height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
