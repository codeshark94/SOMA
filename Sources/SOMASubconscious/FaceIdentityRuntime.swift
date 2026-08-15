import CoreImage
import CoreML
import CoreVideo
import CryptoKit
import Foundation
import SOMACore

struct FaceAlignmentEvidence: Sendable {
    let rect: SOMACore.NormalizedRect
    let leftEye: CGPoint
    let rightEye: CGPoint
    let nose: CGPoint
}

struct FaceIdentityReferenceCounts: Sendable {
    let knownProfileReferenceCounts: [Int]
    let anonymousClusterReferenceCounts: [Int]
}

enum FaceIdentityRuntimeDecision: Sendable {
    case unknownCandidate(handle: AnonymousFaceHandle, confirmations: Int)
    case anonymous(entityID: UUID, handle: AnonymousFaceHandle, similarity: Double, observations: Int)
    case knownCandidate(entityID: UUID, similarity: Double)
    case known(entityID: UUID, similarity: Double, confirmations: Int)

    var state: String {
        switch self {
        case .unknownCandidate: "unknown_candidate"
        case .anonymous: "anonymous_recognized"
        case .knownCandidate: "known_candidate"
        case .known: "known_recognized"
        }
    }

    var opaqueSubject: String {
        switch self {
        case let .unknownCandidate(handle, _), let .anonymous(_, handle, _, _): handle.rawValue
        case let .knownCandidate(entityID, _), let .known(entityID, _, _): entityID.uuidString.lowercased()
        }
    }

    var confidence: Double {
        switch self {
        case let .unknownCandidate(_, confirmations): min(Double(confirmations) / 3, 0.99)
        case let .anonymous(_, _, similarity, _), let .knownCandidate(_, similarity), let .known(_, similarity, _):
            min(max(similarity, 0), 1)
        }
    }
}

private enum FaceIdentityRuntimeError: LocalizedError {
    case modelMissing(String)
    case invalidModelOutput
    case cannotAllocateInput

    var errorDescription: String? {
        switch self {
        case let .modelMissing(path): "ArcFace Core ML model is missing at \(path)"
        case .invalidModelOutput: "ArcFace Core ML returned an invalid 512-dimensional embedding"
        case .cannotAllocateInput: "Cannot allocate the ArcFace alignment buffer"
        }
    }
}

private final class ArcFaceR50Embedder: @unchecked Sendable {
    static let modelID = "insightface-w600k-r50-coreml"
    static let modelRevision = 1

    let computeUnits = "cpu_and_neural_engine"
    private(set) var warmupMS: Double = 0
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw FaceIdentityRuntimeError.modelMissing(modelURL.path)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let started = DispatchTime.now().uptimeNanoseconds
        let warmup = try Self.makePixelBuffer()
        context.render(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112)), to: warmup)
        _ = try predict(warmup, quality: 1)
        warmupMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    func embed(
        pixelBuffer: CVPixelBuffer,
        alignment: FaceAlignmentEvidence
    ) throws -> LocalFaceEmbedding {
        let aligned = try Self.makePixelBuffer()
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let source = [alignment.leftEye, alignment.rightEye, alignment.nose].map {
            CGPoint(x: Double($0.x) * width, y: Double($0.y) * height)
        }
        // ArcFace's canonical template uses top-left image coordinates;
        // Core Image uses bottom-left coordinates.
        let destination = [
            CGPoint(x: 38.2946, y: 112 - 51.6963),
            CGPoint(x: 73.5318, y: 112 - 51.5014),
            CGPoint(x: 56.0252, y: 112 - 71.7366),
        ]
        let transform = Self.similarityTransform(source: source, destination: destination)
        let alignedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
        context.render(alignedImage, to: aligned)
        let faceScale = sqrt(max(0, alignment.rect.width * alignment.rect.height))
        let quality = min(max(faceScale / 0.18, 0), 1)
        return try predict(aligned, quality: quality)
    }

    private func predict(_ pixelBuffer: CVPixelBuffer, quality: Double) throws -> LocalFaceEmbedding {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "face": MLFeatureValue(pixelBuffer: pixelBuffer),
        ])
        let result = try model.prediction(from: provider)
        guard let array = result.featureValue(for: "embedding")?.multiArrayValue,
              array.count == 512 else {
            throw FaceIdentityRuntimeError.invalidModelOutput
        }
        let values = (0..<array.count).map { index -> Float in
            switch array.dataType {
            case .float16:
                Float(array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)[index])
            case .float32:
                array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[index]
            case .double:
                Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[index])
            default:
                0
            }
        }
        return try LocalFaceEmbedding(
            modelID: Self.modelID,
            modelRevision: Self.modelRevision,
            quality: quality,
            values: values
        )
    }

    private static func similarityTransform(
        source: [CGPoint],
        destination: [CGPoint]
    ) -> CGAffineTransform {
        precondition(source.count == destination.count && source.count >= 2)
        let sourceCenter = CGPoint(
            x: source.map(\.x).reduce(0, +) / CGFloat(source.count),
            y: source.map(\.y).reduce(0, +) / CGFloat(source.count)
        )
        let destinationCenter = CGPoint(
            x: destination.map(\.x).reduce(0, +) / CGFloat(destination.count),
            y: destination.map(\.y).reduce(0, +) / CGFloat(destination.count)
        )
        var denominator = 0.0
        var real = 0.0
        var imaginary = 0.0
        for (sourcePoint, destinationPoint) in zip(source, destination) {
            let sx = Double(sourcePoint.x - sourceCenter.x)
            let sy = Double(sourcePoint.y - sourceCenter.y)
            let dx = Double(destinationPoint.x - destinationCenter.x)
            let dy = Double(destinationPoint.y - destinationCenter.y)
            denominator += sx * sx + sy * sy
            real += sx * dx + sy * dy
            imaginary += sx * dy - sy * dx
        }
        guard denominator > 1e-9 else { return .identity }
        let a = real / denominator
        let b = imaginary / denominator
        let tx = Double(destinationCenter.x) - a * Double(sourceCenter.x) + b * Double(sourceCenter.y)
        let ty = Double(destinationCenter.y) - b * Double(sourceCenter.x) - a * Double(sourceCenter.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            112,
            112,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw FaceIdentityRuntimeError.cannotAllocateInput
        }
        return pixelBuffer
    }
}

/// A latest-one, bounded-rate identity path. It is deliberately independent
/// from the face detector and motor-control queue: identity may arrive late,
/// but it can never delay face fixation or exploration.
final class FaceIdentityRuntime: @unchecked Sendable {
    private final class SynchronousResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value?

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func get() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct WorkItem {
        let pixelBuffer: CVPixelBuffer
        let alignment: FaceAlignmentEvidence
        let monotonicNS: UInt64
    }

    private let queue = DispatchQueue(label: "soma.subconscious.face-identity", qos: .utility)
    private let lock = NSLock()
    private let embedder: ArcFaceR50Embedder
    private let profileStore: FaceIdentityProfileStore
    private let anonymousRegistry: AnonymousFaceRegistry
    private let onHealth: @Sendable (String, String) -> Void
    private let onDecision: @Sendable (FaceIdentityRuntimeDecision, UInt64, Double) -> Void
    private var profileSnapshot: [LocalFaceIdentityProfile] = []
    private var matcher: FaceIdentityMatcher
    private var pending: WorkItem?
    private var running = false
    private var stopped = false
    private var nextAcceptedNS: UInt64 = 0

    init(
        modelURL: URL = FaceIdentityRuntime.defaultModelURL(),
        dataDirectoryURL: URL = FaceIdentityRuntime.defaultDataDirectoryURL(),
        onHealth: @escaping @Sendable (String, String) -> Void,
        onDecision: @escaping @Sendable (FaceIdentityRuntimeDecision, UInt64, Double) -> Void
    ) throws {
        let key = try OwnerOnlyInstallationSecret.loadOrCreate(
            in: dataDirectoryURL,
            filename: "installation-key-v2.bin"
        )
        embedder = try ArcFaceR50Embedder(modelURL: modelURL)
        profileStore = try FaceIdentityProfileStore(
            fileURL: dataDirectoryURL.appendingPathComponent("known-v2.encjson"),
            encryptionKey: key
        )
        anonymousRegistry = try AnonymousFaceRegistry(
            fileURL: dataDirectoryURL.appendingPathComponent("anonymous-v2.encjson"),
            encryptionKey: key,
            calibration: try Self.anonymousCalibration()
        )
        matcher = FaceIdentityMatcher(calibration: try FaceIdentityCalibration(
            minimumCosineSimilarity: 0.62,
            minimumBestAlternativeMargin: 0.10,
            minimumObservationQuality: 0.52,
            confirmationsRequired: 3,
            evidenceWindowMilliseconds: 1_000
        ))
        self.onHealth = onHealth
        self.onDecision = onDecision
        onHealth(
            "configured",
            String(format: "model=%@; dimensions=512; compute_units=%@; prewarm_ms=%.3f; max_hz=5; profiles=encrypted_local_v2; unknowns=hmac_pseudonymous; installation_key=owner_only_file",
                   ArcFaceR50Embedder.modelID, embedder.computeUnits, embedder.warmupMS)
        )
        Task { [weak self, profileStore] in
            let profiles = await profileStore.profiles()
            self?.queue.async { [weak self] in self?.profileSnapshot = profiles }
        }
    }

    func submit(
        pixelBuffer: CVPixelBuffer,
        alignment: FaceAlignmentEvidence,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        guard !stopped, monotonicNS >= nextAcceptedNS else {
            lock.unlock()
            return
        }
        nextAcceptedNS = monotonicNS + 200_000_000
        pending = WorkItem(pixelBuffer: pixelBuffer, alignment: alignment, monotonicNS: monotonicNS)
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard !stopped, let item = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            autoreleasepool { process(item) }
        }
    }

    private func process(_ item: WorkItem) {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let embedding = try embedder.embed(pixelBuffer: item.pixelBuffer, alignment: item.alignment)
            let known = matcher.match(embedding, profiles: profileSnapshot, at: item.monotonicNS)
            let inferenceMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            switch known {
            case let .recognized(entityID, similarity, _, confirmations):
                onDecision(.known(entityID: entityID, similarity: similarity, confirmations: confirmations), item.monotonicNS, inferenceMS)
                retainKnownView(entityID: entityID, embedding: embedding)
            case let .candidate(entityID, similarity, _):
                onDecision(.knownCandidate(entityID: entityID, similarity: similarity), item.monotonicNS, inferenceMS)
            case .unknown:
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<Result<AnonymousFaceDecision, Error>>()
                let observedNS = item.monotonicNS
                Task { [anonymousRegistry] in
                    do {
                        resultBox.set(.success(try await anonymousRegistry.observe(
                            embedding,
                            at: observedNS
                        )))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                switch resultBox.get() {
                case let .success(.candidate(handle, confirmations)):
                    onDecision(.unknownCandidate(handle: handle, confirmations: confirmations), item.monotonicNS, inferenceMS)
                case let .success(.recognized(handle, similarity, observations)):
                    onDecision(
                        .anonymous(
                            entityID: Self.pseudonymousEntityID(for: handle),
                            handle: handle,
                            similarity: similarity,
                            observations: observations
                        ),
                        item.monotonicNS,
                        inferenceMS
                    )
                case .success(.rejected):
                    break
                case let .failure(error):
                    onHealth("runtime_error", error.localizedDescription)
                case .none:
                    onHealth("runtime_error", "anonymous_registry_no_result")
                }
            }
        } catch {
            onHealth("runtime_error", error.localizedDescription)
        }
    }

    /// Profile enrichment is deliberately asynchronous to the latest-one
    /// identity worker. A successful recognition can improve later viewpoint
    /// coverage but must not hold up this frame's recognition decision.
    private func retainKnownView(entityID: UUID, embedding: LocalFaceEmbedding) {
        Task { [weak self, profileStore] in
            do {
                guard let referenceCount = try await profileStore.retainPersistentObservation(
                    entityID: entityID,
                    embedding: embedding
                ) else {
                    return
                }
                let profiles = await profileStore.profiles()
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    profileSnapshot = profiles
                    onHealth("profile_view_retained", "references=\(referenceCount); storage=encrypted_local")
                }
            } catch {
                self?.queue.async { [weak self] in
                    self?.onHealth("profile_view_rejected", String(error.localizedDescription.prefix(192)))
                }
            }
        }
    }

    static func defaultModelURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/models/arcface-r50-v1/ArcFaceR50.mlmodelc")
    }

    static func defaultDataDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/identity", isDirectory: true)
    }

    static func promoteAnonymousIdentity(
        handle: AnonymousFaceHandle,
        dataDirectoryURL: URL = FaceIdentityRuntime.defaultDataDirectoryURL()
    ) async throws -> (entityID: UUID, referenceCount: Int) {
        let key = try OwnerOnlyInstallationSecret.loadOrCreate(
            in: dataDirectoryURL,
            filename: "installation-key-v2.bin"
        )
        let registry = try AnonymousFaceRegistry(
            fileURL: dataDirectoryURL.appendingPathComponent("anonymous-v2.encjson"),
            encryptionKey: key,
            calibration: try anonymousCalibration()
        )
        let references = try await registry.enrollmentReferences(for: handle)
        let profile = try LocalFaceIdentityProfile(
            entityID: pseudonymousEntityID(for: handle),
            consentScope: .persistent,
            references: references
        )
        let profileStore = try FaceIdentityProfileStore(
            fileURL: dataDirectoryURL.appendingPathComponent("known-v2.encjson"),
            encryptionKey: key
        )
        try await profileStore.upsert(profile)
        return (profile.entityID, references.count)
    }

    static func removeKnownIdentity(
        entityID: UUID,
        dataDirectoryURL: URL = FaceIdentityRuntime.defaultDataDirectoryURL()
    ) async throws {
        let key = try OwnerOnlyInstallationSecret.loadOrCreate(
            in: dataDirectoryURL,
            filename: "installation-key-v2.bin"
        )
        let profileStore = try FaceIdentityProfileStore(
            fileURL: dataDirectoryURL.appendingPathComponent("known-v2.encjson"),
            encryptionKey: key
        )
        try await profileStore.remove(entityID: entityID)
    }

    static func referenceCounts(
        dataDirectoryURL: URL = FaceIdentityRuntime.defaultDataDirectoryURL()
    ) async throws -> FaceIdentityReferenceCounts {
        let key = try OwnerOnlyInstallationSecret.loadOrCreate(
            in: dataDirectoryURL,
            filename: "installation-key-v2.bin"
        )
        let profileStore = try FaceIdentityProfileStore(
            fileURL: dataDirectoryURL.appendingPathComponent("known-v2.encjson"),
            encryptionKey: key
        )
        let registry = try AnonymousFaceRegistry(
            fileURL: dataDirectoryURL.appendingPathComponent("anonymous-v2.encjson"),
            encryptionKey: key,
            calibration: try anonymousCalibration()
        )
        let profiles = await profileStore.profiles()
        let knownProfileReferenceCounts = profiles.map { $0.references.count }
        let anonymousClusterReferenceCounts = await registry.persistentReferenceCounts()
        return FaceIdentityReferenceCounts(
            knownProfileReferenceCounts: knownProfileReferenceCounts,
            anonymousClusterReferenceCounts: anonymousClusterReferenceCounts
        )
    }

    static func pseudonymousEntityID(for handle: AnonymousFaceHandle) -> UUID {
        let digest = Array(SHA256.hash(data: Data(handle.rawValue.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func anonymousCalibration() throws -> AnonymousFaceCalibration {
        try AnonymousFaceCalibration(
            minimumCosineSimilarity: 0.58,
            minimumBestAlternativeMargin: 0.08,
            minimumObservationQuality: 0.52,
            confirmationsRequired: 3
        )
    }
}
