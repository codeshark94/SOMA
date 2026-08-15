import Darwin
import Foundation

public enum EmbodimentIPCCommandKind: String, Codable, Sendable {
    case submit
    case snapshot
    case captureResult = "capture_result"
    case personContext = "person_context"
    case indicatorCalibration = "indicator_calibration"
}

/// Local-only person-context operations exposed through the same current-user
/// socket as embodiment. The L0 process owns the encrypted journal lock, so
/// an MCP child never opens a competing memory store.
public enum PersonContextIPCOperation: String, Codable, Sendable {
    case get
    case setPreferredLanguage = "set_preferred_language"
    case clearPreferredLanguage = "clear_preferred_language"
    case setContactPreference = "set_contact_preference"
    case setRapport = "set_rapport"
    case setFact = "set_fact"
    case removeFact = "remove_fact"
}

public struct PersonContextIPCRequest: Codable, Equatable, Sendable {
    public let operation: PersonContextIPCOperation
    public let personEntityID: UUID
    public let languageTag: String?
    public let proactiveContact: ProactiveContactPreference?
    public let familiarity: Double?
    public let interactionComfort: Double?
    public let communicationAlignment: Double?
    public let factKey: String?
    public let factValue: String?
    public let confirmedByUser: Bool

    public init(
        operation: PersonContextIPCOperation,
        personEntityID: UUID,
        languageTag: String? = nil,
        proactiveContact: ProactiveContactPreference? = nil,
        familiarity: Double? = nil,
        interactionComfort: Double? = nil,
        communicationAlignment: Double? = nil,
        factKey: String? = nil,
        factValue: String? = nil,
        confirmedByUser: Bool = false
    ) {
        self.operation = operation
        self.personEntityID = personEntityID
        self.languageTag = languageTag.map { String($0.prefix(35)) }
        self.proactiveContact = proactiveContact
        self.familiarity = familiarity
        self.interactionComfort = interactionComfort
        self.communicationAlignment = communicationAlignment
        self.factKey = factKey.map { String($0.prefix(64)) }
        self.factValue = factValue.map { String($0.prefix(1_024)) }
        self.confirmedByUser = confirmedByUser
    }
}

public struct EmbodimentIPCCommand: Codable, Equatable, Sendable {
    public let kind: EmbodimentIPCCommandKind
    public let request: CognitiveEmbodimentRequest?
    public let requestID: String?
    public let personContext: PersonContextIPCRequest?
    /// An opaque capability issued by the owning L0 process for one live
    /// participant. It is checked locally and never persists in memory/trace.
    public let sessionAuthorization: String?
    /// An owner-local LED calibration request. A missing preset ends the
    /// temporary override and hands the indicator back to normal L0 state.
    public let indicatorPreset: SOMALEDFirmwarePreset?

    public init(
        kind: EmbodimentIPCCommandKind,
        request: CognitiveEmbodimentRequest? = nil,
        requestID: String? = nil,
        personContext: PersonContextIPCRequest? = nil,
        sessionAuthorization: String? = nil,
        indicatorPreset: SOMALEDFirmwarePreset? = nil
    ) {
        self.kind = kind
        self.request = request
        self.requestID = requestID.map { String($0.prefix(96)) }
        self.personContext = personContext
        self.sessionAuthorization = sessionAuthorization.map { String($0.prefix(128)) }
        self.indicatorPreset = indicatorPreset
    }
}

public struct EmbodimentIPCReply: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let decision: EmbodimentShadowDecision?
    public let snapshot: EmbodimentShadowSnapshot?
    public let viewResource: EmbodimentViewResource?
    public let personContext: PersonContextSnapshot?

    public init(
        ok: Bool,
        error: String? = nil,
        decision: EmbodimentShadowDecision? = nil,
        snapshot: EmbodimentShadowSnapshot? = nil,
        viewResource: EmbodimentViewResource? = nil,
        personContext: PersonContextSnapshot? = nil
    ) {
        self.ok = ok
        self.error = error.map { String($0.prefix(240)) }
        self.decision = decision
        self.snapshot = snapshot
        self.viewResource = viewResource
        self.personContext = personContext
    }
}

public enum EmbodimentIPCError: Error, Equatable, LocalizedError {
    case invalidSocketPath
    case socketPathOccupied
    case unavailable
    case permissionDenied
    case messageTooLarge
    case malformedMessage
    case timeout
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath: "Invalid Unix socket path"
        case .socketPathOccupied: "Unix socket path is occupied by a non-socket file"
        case .unavailable: "L0 embodiment shadow endpoint is unavailable"
        case .permissionDenied: "Unix socket peer is not the current user"
        case .messageTooLarge: "Embodiment IPC message exceeds its size limit"
        case .malformedMessage: "Embodiment IPC message is malformed"
        case .timeout: "Embodiment IPC operation timed out"
        case let .transportFailure(message): message
        }
    }
}

public final class EmbodimentShadowSocketServer: @unchecked Sendable {
    public typealias DecisionHandler = @Sendable (
        _ request: CognitiveEmbodimentRequest,
        _ decision: EmbodimentShadowDecision
    ) -> Void
    public typealias HealthHandler = @Sendable (_ state: String, _ message: String?) -> Void
    public typealias CaptureResultProvider = @Sendable (
        _ requestID: String,
        _ monotonicNS: UInt64
    ) -> EmbodimentViewResource?
    public typealias PersonContextProvider = @Sendable (
        _ request: PersonContextIPCRequest
    ) -> Result<PersonContextSnapshot, Error>
    public typealias IndicatorCalibrationHandler = @Sendable (
        _ preset: SOMALEDFirmwarePreset?
    ) -> Result<Void, Error>
    public typealias SessionAuthorizationProvider = @Sendable (
        _ token: String?,
        _ scope: SOMASessionCapabilityScope
    ) -> Result<Void, Error>

    private let socketURL: URL
    private let arbiter: ShadowEmbodimentArbiter
    private let onDecision: DecisionHandler
    private let onHealth: HealthHandler
    private let captureResultProvider: CaptureResultProvider
    private let personContextProvider: PersonContextProvider
    private let indicatorCalibrationHandler: IndicatorCalibrationHandler
    private let sessionAuthorizationProvider: SessionAuthorizationProvider
    private let queue = DispatchQueue(label: "soma.embodiment.shadow.socket")
    private let group = DispatchGroup()
    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var accepting = false
    private var recentRequestNS: [UInt64] = []
    private let maximumMessageBytes = 1_048_576
    private let maximumRequestsPerSecond = 40

    public init(
        socketURL: URL,
        arbiter: ShadowEmbodimentArbiter = ShadowEmbodimentArbiter(),
        onDecision: @escaping DecisionHandler = { _, _ in },
        captureResultProvider: @escaping CaptureResultProvider = { _, _ in nil },
        personContextProvider: @escaping PersonContextProvider = { _ in .failure(EmbodimentIPCError.unavailable) },
        indicatorCalibrationHandler: @escaping IndicatorCalibrationHandler = { _ in .failure(EmbodimentIPCError.unavailable) },
        sessionAuthorizationProvider: @escaping SessionAuthorizationProvider = { _, _ in .success(()) },
        onHealth: @escaping HealthHandler = { _, _ in }
    ) {
        self.socketURL = socketURL
        self.arbiter = arbiter
        self.onDecision = onDecision
        self.captureResultProvider = captureResultProvider
        self.personContextProvider = personContextProvider
        self.indicatorCalibrationHandler = indicatorCalibrationHandler
        self.sessionAuthorizationProvider = sessionAuthorizationProvider
        self.onHealth = onHealth
    }

    deinit { stop() }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !accepting else { return }
        try Self.validateSocketPath(socketURL.path)
        let directory = socketURL.deletingLastPathComponent()
        try Self.prepareSocketDirectory(directory)
        try Self.removeStaleSocket(at: socketURL)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("Cannot create embodiment IPC socket") }
        do {
            try Self.bind(fd: fd, path: socketURL.path)
            guard Darwin.chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw EmbodimentIPCError.transportFailure("Cannot protect embodiment IPC socket")
            }
            guard Darwin.listen(fd, 8) == 0 else {
                throw Self.posixError("Cannot listen on embodiment IPC socket")
            }
        } catch {
            Darwin.close(fd)
            try? Self.removeStaleSocket(at: socketURL)
            throw error
        }
        listenerFD = fd
        accepting = true
        group.enter()
        queue.async { [self] in
            acceptLoop()
            group.leave()
        }
        let snapshot = arbiter.snapshot(at: DispatchTime.now().uptimeNanoseconds)
        onHealth(
            "ready",
            "socket=\(socketURL.path); mode=\(snapshot.mode); physical_actuation=\(snapshot.physicalActuationEnabled)"
        )
    }

    public func stop() {
        stateLock.lock()
        let fd = listenerFD
        let wasAccepting = accepting
        accepting = false
        listenerFD = -1
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if wasAccepting { group.wait() }
        try? Self.removeStaleSocket(at: socketURL)
    }

    private func acceptLoop() {
        while isAccepting {
            let clientFD = Darwin.accept(currentListenerFD, nil, nil)
            if clientFD < 0 {
                if isAccepting { onHealth("accept_error", String(cString: strerror(errno))) }
                continue
            }
            autoreleasepool { handle(clientFD) }
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
    }

    private func handle(_ clientFD: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(clientFD, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            writeReply(.init(ok: false, error: EmbodimentIPCError.permissionDenied.localizedDescription), to: clientFD)
            return
        }
        guard admitsRequest(at: DispatchTime.now().uptimeNanoseconds) else {
            writeReply(.init(ok: false, error: "rate_limited"), to: clientFD)
            return
        }
        do {
            Self.setTimeouts(clientFD)
            let data = try Self.readLine(from: clientFD, maximumBytes: maximumMessageBytes)
            let command = try JSONDecoder().decode(EmbodimentIPCCommand.self, from: data)
            switch command.kind {
            case .snapshot:
                guard command.request == nil,
                      command.requestID == nil,
                      command.personContext == nil,
                      command.indicatorPreset == nil else {
                    throw EmbodimentIPCError.malformedMessage
                }
                try authorize(command.sessionAuthorization, scope: .embodimentControl)
                let snapshot = arbiter.snapshot(at: DispatchTime.now().uptimeNanoseconds)
                writeReply(.init(ok: true, snapshot: snapshot), to: clientFD)
            case .submit:
                guard let request = command.request,
                      command.requestID == nil,
                      command.personContext == nil,
                      command.indicatorPreset == nil else {
                    throw EmbodimentIPCError.malformedMessage
                }
                try authorize(command.sessionAuthorization, scope: .embodimentControl)
                let decision = arbiter.submit(request, at: DispatchTime.now().uptimeNanoseconds)
                onDecision(request, decision)
                writeReply(.init(
                    ok: decision.status != .rejected,
                    error: decision.status == .rejected ? decision.reason : nil,
                    decision: decision,
                    snapshot: decision.snapshot
                ), to: clientFD)
            case .captureResult:
                guard command.request == nil,
                      command.personContext == nil,
                      command.indicatorPreset == nil,
                      let requestID = command.requestID,
                      !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EmbodimentIPCError.malformedMessage
                }
                try authorize(command.sessionAuthorization, scope: .embodimentControl)
                let now = DispatchTime.now().uptimeNanoseconds
                guard let resource = captureResultProvider(requestID, now) else {
                    writeReply(.init(
                        ok: false,
                        error: "capture_result_unknown",
                        snapshot: arbiter.snapshot(at: now)
                    ), to: clientFD)
                    return
                }
                let ok = resource.state != .failed && resource.state != .expired
                writeReply(.init(
                    ok: ok,
                    error: ok ? nil : resource.failureReason ?? resource.state.rawValue,
                    snapshot: arbiter.snapshot(at: now),
                    viewResource: resource
                ), to: clientFD)
            case .personContext:
                guard command.request == nil,
                      command.requestID == nil,
                      command.indicatorPreset == nil,
                      let request = command.personContext else {
                    throw EmbodimentIPCError.malformedMessage
                }
                try authorize(command.sessionAuthorization, scope: .personContext(request.personEntityID))
                switch personContextProvider(request) {
                case let .success(context):
                    writeReply(.init(ok: true, personContext: context), to: clientFD)
                case let .failure(error):
                    writeReply(.init(ok: false, error: error.localizedDescription), to: clientFD)
                }
            case .indicatorCalibration:
                guard command.request == nil,
                      command.requestID == nil,
                      command.personContext == nil else {
                    throw EmbodimentIPCError.malformedMessage
                }
                try authorize(command.sessionAuthorization, scope: .embodimentControl)
                switch indicatorCalibrationHandler(command.indicatorPreset) {
                case .success:
                    writeReply(.init(ok: true), to: clientFD)
                case let .failure(error):
                    writeReply(.init(ok: false, error: error.localizedDescription), to: clientFD)
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writeReply(.init(ok: false, error: message), to: clientFD)
        }
    }

    private func authorize(
        _ token: String?,
        scope: SOMASessionCapabilityScope
    ) throws {
        switch sessionAuthorizationProvider(token, scope) {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    private func writeReply(_ reply: EmbodimentIPCReply, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        try? Self.writeAll(data, to: fd)
    }

    private func admitsRequest(at monotonicNS: UInt64) -> Bool {
        let cutoff = monotonicNS > 1_000_000_000 ? monotonicNS - 1_000_000_000 : 0
        recentRequestNS.removeAll { $0 < cutoff }
        guard recentRequestNS.count < maximumRequestsPerSecond else { return false }
        recentRequestNS.append(monotonicNS)
        return true
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }

    private var currentListenerFD: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerFD
    }

    fileprivate static func validateSocketPath(_ path: String) throws {
        let byteCount = path.lengthOfBytes(using: .utf8)
        guard path.hasPrefix("/"), byteCount > 1, byteCount < 104 else {
            throw EmbodimentIPCError.invalidSocketPath
        }
    }

    private static func removeStaleSocket(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeSocket else {
            throw EmbodimentIPCError.socketPathOccupied
        }
        guard Darwin.unlink(url.path) == 0 else { throw posixError("Cannot remove stale embodiment IPC socket") }
    }

    private static func prepareSocketDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard Darwin.chmod(directory.path, S_IRWXU) == 0 else {
                throw EmbodimentIPCError.transportFailure("Cannot protect embodiment IPC directory")
            }
            return
        }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o700 == 0o700,
              permissions & 0o077 == 0 else {
            throw EmbodimentIPCError.transportFailure(
                "Embodiment IPC requires a current-user directory with permissions 0700"
            )
        }
    }

    private static func bind(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw posixError("Cannot bind embodiment IPC socket") }
    }

    fileprivate static func setTimeouts(_ fd: Int32) {
        var noSignal: Int32 = 1
        withUnsafePointer(to: &noSignal) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    fileprivate static func readLine(from fd: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count <= maximumBytes {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return result }
                result.append(byte)
                continue
            }
            if count == 0 { throw EmbodimentIPCError.malformedMessage }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw EmbodimentIPCError.timeout }
            if errno == EINTR { continue }
            throw posixError("Cannot read embodiment IPC message")
        }
        throw EmbodimentIPCError.messageTooLarge
    }

    fileprivate static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(fd, base, remaining)
                if count > 0 {
                    remaining -= count
                    base = base.advanced(by: count)
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw EmbodimentIPCError.timeout }
                throw posixError("Cannot write embodiment IPC message")
            }
        }
    }

    private static func posixError(_ prefix: String) -> EmbodimentIPCError {
        .transportFailure("\(prefix): \(String(cString: strerror(errno)))")
    }
}

public enum EmbodimentShadowSocketClient {
    public static func send(
        _ command: EmbodimentIPCCommand,
        socketURL: URL
    ) throws -> EmbodimentIPCReply {
        try EmbodimentShadowSocketServer.validateSocketPath(socketURL.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EmbodimentIPCError.unavailable }
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        EmbodimentShadowSocketServer.setTimeouts(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw EmbodimentIPCError.unavailable }
        var data = try JSONEncoder().encode(command)
        data.append(0x0A)
        try EmbodimentShadowSocketServer.writeAll(data, to: fd)
        let replyData = try EmbodimentShadowSocketServer.readLine(from: fd, maximumBytes: 1_048_576)
        return try JSONDecoder().decode(EmbodimentIPCReply.self, from: replyData)
    }
}
