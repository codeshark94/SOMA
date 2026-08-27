import AppKit
import Foundation
import LocalAuthentication
import SOMACore
import SwiftUI

/// Deep dark blue accent color used across the Control Center UI.
enum SOMAAccent {
    static let color = Color(red: 0.13, green: 0.27, blue: 0.56)
    static let nsColor = NSColor(red: 0.13, green: 0.27, blue: 0.56, alpha: 1)
}

private enum SOMAPaths {
    static let runtimeRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMA_RUNTIME_ROOT"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/subconscious/runtime", isDirectory: true).path,
        isDirectory: true)
    static let serviceLabel = "com.soma.reactive-l0"
    static let servicePlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.soma.reactive-l0.plist")
    static let menuBarPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.soma.menu-bar.plist")

    static var serviceTarget: String {
        "gui/\(getuid())/\(serviceLabel)"
    }

    static var subconsciousExecutable: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("soma-subconscious")
    }
}

private struct IdentityObservation: Equatable {
    let subject: String
    let state: String
    let confidence: Double
}

private struct SOMARuntimeSnapshot: Equatable {
    let isLive: Bool
    let lastActivity: Date?
    let indicatorState: String?
    let sources: [String: String]
    let identity: IdentityObservation?
    let administratorVerified: Bool

    static let empty = SOMARuntimeSnapshot(
        isLive: false,
        lastActivity: nil,
        indicatorState: nil,
        sources: [:],
        identity: nil,
        administratorVerified: false
    )

    static func read(settings: SOMAControlSettings) -> SOMARuntimeSnapshot {
        guard let traceURL = latestTraceURL() else { return .empty }
        let modifiedAt = (try? traceURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let isLive = modifiedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
        let events = tailLines(from: traceURL, maximumBytes: 196_608)
        var sources: [String: String] = [:]
        var indicatorState: String?
        var identity: IdentityObservation?
        var administratorVerified = false

        for line in events.reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventName = event["event"] as? String else { continue }
            if eventName == "source.health",
               let source = event["source"] as? String,
               let state = event["state"] as? String,
               sources[source] == nil {
                sources[source] = state
            }
            if eventName == "identity.observation", identity == nil,
               let subject = event["subject"] as? String,
               let state = event["state"] as? String {
                identity = IdentityObservation(
                    subject: subject,
                    state: state,
                    confidence: event["confidence"] as? Double ?? 0
                )
                if state == "known_recognized",
                   subject == settings.administrator?.entityID.uuidString.lowercased() {
                    administratorVerified = true
                }
            }
            if eventName == "administrator.identity",
               event["state"] as? String == "verified" {
                administratorVerified = true
            }
            if event["source"] as? String == "social_indicator", indicatorState == nil {
                indicatorState = event["state"] as? String
            }
        }
        return SOMARuntimeSnapshot(
            isLive: isLive,
            lastActivity: modifiedAt,
            indicatorState: indicatorState,
            sources: sources,
            identity: identity,
            administratorVerified: administratorVerified
        )
    }

    private static func latestTraceURL() -> URL? {
        let detailURL = SOMAPaths.runtimeRoot.appendingPathComponent("detail", isDirectory: true)
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: detailURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return candidates
            .filter { $0.pathExtension == "jsonl" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .max {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left < right
            }
    }

    private static func tailLines(from url: URL, maximumBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let text = String(data: (try? handle.readToEnd()) ?? Data(), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

@MainActor
private final class SOMAControlModel: ObservableObject {
    @Published var settings: SOMAControlSettings
    @Published var envSettings: SOMAEnvSettings
    @Published private(set) var runtime = SOMARuntimeSnapshot.empty
    @Published private(set) var message: String?
    // Administrator identity fields stay locked until the Mac login password
    // (or Touch ID) unlocks them, so changing or removing the owner is not a
    // silent, unauthenticated action.
    @Published var administratorProfileUnlocked = false

    private let store: SOMAControlSettingsStore
    private let envStore: SOMAEnvStore
    init(store: SOMAControlSettingsStore = .init()) {
        self.store = store
        self.envStore = .init()
        do {
            settings = try store.load()
        } catch {
            settings = .init()
            message = error.localizedDescription
        }
        do {
            envSettings = try envStore.load()
        } catch {
            envSettings = .init()
            message = message ?? error.localizedDescription
        }
        refresh()
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var latestAnonymousFace: String? {
        // Prefer the dedicated always-current identity file the runtime writes;
        // it is not subject to the trace-tail read window that sparse
        // identity.observation events scroll out of. Accept both a stabilized
        // anonymous face and an in-progress anonymous candidate so a person can
        // enroll without waiting for full recognition confirmation.
        if let file = Self.readIdentityFile(),
           file.subject.hasPrefix("anon_"),
           file.state == "anonymous_recognized" || file.state == "unknown_candidate" {
            return file.subject
        }
        guard let identity = runtime.identity,
              identity.state == "anonymous_recognized" || identity.state == "unknown_candidate",
              identity.subject.hasPrefix("anon_") else { return nil }
        return identity.subject
    }

    static func readIdentityFile() -> (state: String, subject: String)? {
        let url = SOMAPaths.runtimeRoot.appendingPathComponent("identity-current.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              let subject = object["subject"] as? String else { return nil }
        return (state, subject)
    }

    func refresh() {
        runtime = SOMARuntimeSnapshot.read(settings: settings)
    }

    /// Prompts for the Mac login password / Touch ID (system dialog) and
    /// returns true only on success. Fully asynchronous so the main thread is
    /// never blocked while the system dialog is up.
    @discardableResult
    func authenticateMacLogin(reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            message = "Mac login authentication unavailable: \(policyError?.localizedDescription ?? "unknown")"
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    var isSOMARunning: Bool {
        isSOMALoaded()
    }

    func save() {
        do {
            try store.save(settings)
            try envStore.save(envSettings)
            message = "Saved locally. Restart SOMA to apply runtime changes."
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func saveAndRestart() {
        save()
        guard message?.hasPrefix("Saved locally") == true else { return }
        let result = startSOMA(restart: true)
        message = result.status == 0
            ? "Saved and SOMA is restarting."
            : (result.output.isEmpty ? "Could not restart SOMA." : result.output)
    }

    func startSOMA(restart: Bool = false) -> (status: Int32, output: String) {
        if !isSOMALoaded() {
            guard FileManager.default.fileExists(atPath: SOMAPaths.servicePlist.path) else {
                return (1, "SOMA service definition is unavailable.")
            }
            return runLaunchctl([
                "bootstrap",
                "gui/\(getuid())",
                SOMAPaths.servicePlist.path,
            ])
        }
        guard restart else {
            return (0, "SOMA is already running.")
        }
        return runLaunchctl(["kickstart", "-k", SOMAPaths.serviceTarget])
    }

    func stopSOMA() -> (status: Int32, output: String) {
        guard isSOMALoaded() else {
            runtime = .empty
            return (0, "SOMA is already stopped.")
        }
        let result = runLaunchctl([
            "bootout",
            "gui/\(getuid())",
            SOMAPaths.servicePlist.path,
        ])
        if result.status == 0 {
            runtime = .empty
        }
        return result
    }

    private func isSOMALoaded() -> Bool {
        let result = runLaunchctl(["print", SOMAPaths.serviceTarget])
        return result.status == 0 && result.output.contains("\(SOMAPaths.serviceTarget) = {")
    }

    func enrollLatestFace() async {
        guard let handle = latestAnonymousFace else {
            message = "Stand in view until SOMA shows a recognized local face."
            return
        }
        // Enrolling a new face replaces the administrator mapping, so it is
        // also gated behind the Mac login password when a profile exists.
        if settings.administrator != nil {
            guard await authenticateMacLogin(
                reason: "Replacing the SOMA administrator enrollment requires your Mac login password."
            ) else { return }
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Enroll administrator face?"
        confirmation.informativeText = "SOMA will capture several different views of your face so it recognizes you reliably. Stay facing the camera."
        confirmation.addButton(withTitle: "Start")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        // Guided multi-pose capture: while this progress panel is up the running
        // SOMA process is already watching the camera and accumulating distinct
        // face samples into the anonymous cluster, so we let the person turn
        // their head for a few seconds, then promote the enriched cluster.
        GuidedEnrollmentPanel.present(
            handle: handle,
            guide: "Move your head slowly — turn left, right, up, and down — until progress finishes.",
            sampleWindowSeconds: 6
        ) { [weak self] in
            guard let self else { return (false, "SOMA is unavailable.") }
            let result = self.runSubconscious(["--promote-anonymous-face", handle])
            guard result.status == 0,
                  let entityID = parseValue("entity_id", from: result.output).flatMap(UUID.init(uuidString:)) else {
                return (false, result.output.isEmpty ? "Could not enroll this face." : result.output)
            }
            let references = Int(parseValue("references", from: result.output) ?? "?") ?? 0
            let name = settings.administrator?.displayName ?? "Administrator"
            let address = settings.administrator?.preferredAddress
            settings.administrator = SOMAAdministratorIdentity(
                entityID: entityID,
                displayName: name,
                preferredAddress: address
            )
            do {
                try store.save(settings)
                return (true, "Enrolled with \(references) samples. Restart SOMA to load the profile.")
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    func removeAdministrator() {
        guard let administrator = settings.administrator else { return }
        Task {
            guard await authenticateMacLogin(
                reason: "Removing the SOMA administrator enrollment requires your Mac login password."
            ) else { return }
            self.finishRemoveAdministrator(administrator)
        }
    }

    @MainActor
    private func finishRemoveAdministrator(_ administrator: SOMAAdministratorIdentity) {
        let confirmation = NSAlert()
        confirmation.messageText = "Remove administrator enrollment?"
        confirmation.informativeText = "This permanently removes the encrypted local face template and its administrator mapping from this Mac."
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Remove")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let result = runSubconscious(["--remove-face-identity", administrator.entityID.uuidString.lowercased()])
        guard result.status == 0 else {
            message = result.output.isEmpty ? "Could not remove the administrator profile." : result.output
            return
        }
        settings.administrator = nil
        do {
            try store.save(settings)
            message = "Administrator enrollment removed. Restart SOMA to clear the active profile."
        } catch {
            message = error.localizedDescription
        }
    }

    func revealRuntime() {
        NSWorkspace.shared.open(SOMAPaths.runtimeRoot)
    }

    func stopControlCenter() {
        _ = runLaunchctl([
            "bootout",
            "gui/\(getuid())",
            SOMAPaths.menuBarPlist.path,
        ])
    }

    private func runSubconscious(_ arguments: [String]) -> (status: Int32, output: String) {
        runProcess(at: SOMAPaths.subconsciousExecutable, arguments: arguments)
    }

    private func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        runProcess(at: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }

    private func runProcess(at executable: URL, arguments: [String]) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (1, "Required SOMA executable is unavailable: \(executable.lastPathComponent)")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseValue(_ name: String, from output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("\(name)=") }.map {
            String($0.dropFirst(name.count + 1))
        }
    }
}

private enum SOMASettingsSection: String, CaseIterable, Identifiable {
    case experience = "Experience"
    case layers = "Layers"
    case administrator = "Administrator"
    case system = "System"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .experience: "waveform"
        case .layers: "square.stack.3d.up"
        case .administrator: "person.crop.circle.badge.checkmark"
        case .system: "heart.text.square"
        }
    }
}

private struct SOMAMascot {
    static func image(size: CGFloat, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        let stroke = max(1.2, size * 0.075)
        let ink = NSColor.labelColor
        let head = NSBezierPath(ovalIn: NSRect(x: size * 0.12, y: size * 0.22, width: size * 0.76, height: size * 0.62))
        head.lineWidth = stroke
        ink.setStroke()
        head.stroke()

        let antenna = NSBezierPath()
        antenna.lineWidth = stroke
        antenna.lineCapStyle = .round
        antenna.move(to: NSPoint(x: size * 0.45, y: size * 0.82))
        antenna.curve(to: NSPoint(x: size * 0.38, y: size * 0.94), controlPoint1: NSPoint(x: size * 0.43, y: size * 0.90), controlPoint2: NSPoint(x: size * 0.40, y: size * 0.94))
        antenna.move(to: NSPoint(x: size * 0.55, y: size * 0.82))
        antenna.curve(to: NSPoint(x: size * 0.64, y: size * 0.93), controlPoint1: NSPoint(x: size * 0.58, y: size * 0.90), controlPoint2: NSPoint(x: size * 0.61, y: size * 0.93))
        antenna.stroke()

        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.32, y: size * 0.51, width: size * 0.10, height: size * 0.10)).fill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.58, y: size * 0.51, width: size * 0.10, height: size * 0.10)).fill()
        if !template {
            SOMAAccent.nsColor.withAlphaComponent(0.62).setFill()
            NSBezierPath(ovalIn: NSRect(x: size * 0.24, y: size * 0.40, width: size * 0.12, height: size * 0.07)).fill()
            NSBezierPath(ovalIn: NSRect(x: size * 0.64, y: size * 0.40, width: size * 0.12, height: size * 0.07)).fill()
        }
        let smile = NSBezierPath()
        smile.lineWidth = stroke * 0.78
        smile.lineCapStyle = .round
        smile.move(to: NSPoint(x: size * 0.45, y: size * 0.47))
        smile.curve(to: NSPoint(x: size * 0.55, y: size * 0.47), controlPoint1: NSPoint(x: size * 0.47, y: size * 0.40), controlPoint2: NSPoint(x: size * 0.53, y: size * 0.40))
        smile.stroke()
        image.isTemplate = template
        return image
    }

    static func menuBarImage() -> NSImage {
        let source = image(size: 20, template: true)
        let canvas = NSImage(size: NSSize(width: 20, height: 20))
        canvas.lockFocus()
        source.draw(in: NSRect(x: 0, y: -1.6, width: 20, height: 20))
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StateDot: View {
    let active: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.32))
            .frame(width: 8, height: 8)
            .shadow(color: active ? color.opacity(0.45) : .clear, radius: 3)
    }
}

private enum SOMASettingsSidebarLayout {
    static let headerHorizontalInset: CGFloat = 14
    static let headerTopInset: CGFloat = 16
    static let navigationHorizontalInset: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 12
    static let navigationSpacing: CGFloat = 6
    static let statusVerticalInset: CGFloat = 2
}

private struct SOMASettingsView: View {
    @ObservedObject var model: SOMAControlModel
    var onOpenDiagnostics: () -> Void = {}
    @State private var selection: SOMASettingsSection = .experience
    @State private var revealAPIKey = false

    private var selectedSection: SOMASettingsSection { selection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 20) {
                    heading
                    Spacer(minLength: 20)
                    HStack(spacing: 10) {
                        Button("Save") { model.save() }
                        Button("Save & restart SOMA") { model.saveAndRestart() }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                        if let message = model.message {
                            Label(message, systemImage: "info.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 770, idealWidth: 820, minHeight: 580, idealHeight: 620)
        .tint(SOMAAccent.color)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: SOMAMascot.image(size: 34, template: false))
                    .resizable().frame(width: 34, height: 34)
                Text("SOMA").font(.headline)
            }
            .padding(.horizontal, SOMASettingsSidebarLayout.headerHorizontalInset)
            .padding(.top, SOMASettingsSidebarLayout.headerTopInset)

            VStack(spacing: SOMASettingsSidebarLayout.navigationSpacing) {
                HStack(spacing: 8) {
                    StateDot(active: model.runtime.isLive, color: .green)
                    Text(model.runtime.isLive ? "Running locally" : "Waiting for runtime")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(model.runtime.isLive ? .primary : .secondary)
                .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                .padding(.vertical, SOMASettingsSidebarLayout.statusVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(SOMASettingsSection.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                            .padding(.vertical, 8)
                            .background(
                                selection == item ? Color.primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                }

                Divider().padding(.vertical, 4)

                Button {
                    onOpenDiagnostics()
                } label: {
                    Label("Diagnostic", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                        .padding(.vertical, 8)
                        .background(
                            SOMAAccent.color.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open diagnostic panel")
            }
            .padding(.horizontal, SOMASettingsSidebarLayout.navigationHorizontalInset)
            Spacer(minLength: 0)
        }
        .frame(width: 190)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: SOMAMascot.image(size: 54, template: false))
                .resizable().frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.rawValue).font(.system(size: 23, weight: .bold))
                Text(model.runtime.isLive ? "Live settings for your local companion." : "Settings are ready; SOMA will apply them after launch.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .experience: experience
        case .layers: layers
        case .administrator: administrator
        case .system: system
        }
    }

    private var experience: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Realtime voice", subtitle: "The voice used for account-backed spoken responses.") {
                Toggle("Enable spoken realtime conversations", isOn: binding(\.realtimeVoiceEnabled))
                Picker("Voice", selection: binding(\.realtimeVoice)) {
                    ForEach(SOMARealtimeVoice.allCases, id: \.self) { voice in
                        Text(voice.displayName).tag(voice)
                    }
                }
                .disabled(!model.settings.realtimeVoiceEnabled)
            }
            SettingsCard(title: "LED response", subtitle: "Set global visibility and brightness for the hardware indicator.") {
                Picker("Reaction", selection: ledModeBinding) {
                    ForEach(SOMALEDResponseMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                HStack {
                    Text("Brightness")
                    Slider(value: ledBrightnessBinding, in: 0...3, step: 1)
                    Text("\(model.settings.led.brightness)")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
                }
                .disabled(model.settings.led.responseMode == .off)
            }
            SettingsCard(title: "LED signals", subtitle: "Choose a color and timing pattern for each attention state. Voice adds a blink only when the selected state is steady.") {
                LazyVStack(spacing: 8) {
                    ForEach(SubconsciousIndicatorState.configurationStates, id: \.self) { state in
                        LEDSignalRow(state: state, signal: ledSignalBinding(for: state))
                    }
                }
            }
        }
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Ollama", subtitle: "The local server and the model L1 uses. The API key enables hosted web search.") {
                HStack {
                    Text("Host")
                    TextField("http://127.0.0.1:11434", text: ollamaHostBinding)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("L1 model")
                    TextField("gemma4:31b-cloud", text: l1ModelBinding)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Group {
                        if revealAPIKey {
                            TextField("Ollama API key", text: ollamaAPIKeyBinding)
                        } else {
                            SecureField("Ollama API key", text: ollamaAPIKeyBinding)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(action: { revealAPIKey.toggle() }) {
                        Image(systemName: revealAPIKey ? "eye.slash.fill" : "eye.fill")
                    }
                    .buttonStyle(.plain)
                    .help(revealAPIKey ? "Hide API key" : "Show API key")
                }
                Text("Paste your key into the field, then Save. It is only needed for the hosted web_search / web_fetch tools. Create one at ollama.com/settings/keys; without it those tools stay disabled.")
                    .font(.caption).foregroundStyle(.secondary)            }
            SettingsCard(title: "L0 — Perception & attention", subtitle: "What autonomous motion the attention controller may perform. These govern the gimbal and coverage scan.") {
                Toggle("Track a verified human face", isOn: l0TrackingBinding)
                Toggle("Explore when no verified target is present", isOn: l0ExploreBinding)
                Divider()
                HStack {
                    Text("Release fixation after no response")
                    Spacer()
                    Stepper(
                        model.envSettings.l0FaceFixationReleaseSeconds <= 0
                            ? "Keep gazing (no time limit)"
                            : "\(Int(model.envSettings.l0FaceFixationReleaseSeconds)) s",
                        value: l0FaceFixationReleaseBinding,
                        in: 0...120,
                        step: 15
                    )
                }
                HStack {
                    Toggle("On-device vision layer (E2B)", isOn: l05EnabledBinding)
                        .toggleStyle(.switch)
                }
                HStack {
                    Text("Local vision wake sensitivity")
                    Spacer()
                    Stepper("Score ≥ \(String(format: "%.2f", model.envSettings.l0E2BWakeScore))", value: l0E2BWakeScoreBinding, in: 0.1...0.95, step: 0.05)
                }
                HStack {
                    Text("Local vision wake confidence")
                    Spacer()
                    Stepper("Confidence ≥ \(String(format: "%.2f", model.envSettings.l0E2BWakeConfidence))", value: l0E2BWakeConfidenceBinding, in: 0.1...0.95, step: 0.05)
                }
                HStack {
                    Text("Local vision wake repeat")
                    Spacer()
                    Stepper("Every \(Int(model.envSettings.l0E2BWakeIntervalMilliseconds / 1000)) s", value: l0E2BWakeIntervalBinding, in: 2...60, step: 1)
                }
                HStack {
                    Text("Eye-contact sensitivity")
                    Spacer()
                    Stepper("\(Int(model.envSettings.l0EyeContactFreshnessMilliseconds)) ms", value: l0EyeContactFreshnessBinding, in: 100...2000, step: 50)
                }
                HStack {
                    Text("Eye-contact pupil threshold")
                    Spacer()
                    Picker("", selection: l0EyeContactPupilLevelBinding) {
                        ForEach(SOMAEyeContactPupilLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                HStack {
                    Text("Object detection confidence")
                    Spacer()
                    Stepper("≥ \(String(format: "%.2f", model.envSettings.l0YoloConfidenceThreshold))", value: l0YoloConfidenceBinding, in: 0.1...0.95, step: 0.05)
                }
                Text("The on-device vision layer (E2B) wakes L1 on events. Lower thresholds wake L1 more eagerly; higher ones make it more selective. Eye-contact sensitivity is how long a fresh gaze stays valid for opening a spoken turn — lower is stricter. The pupil threshold scales how centered the pupil must be for a direct gaze — lower is stricter. 'Release fixation after no response' time-limits a held gaze that never becomes engagement; 'Keep gazing' disables that timer (E2B still releases a wrong fixation it judges to be non-person). Object detection confidence is the minimum YOLO score for reporting an object — higher filters out phantom detections (e.g. a toothbrush that is not there).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(title: "L1 — Conscious stream", subtitle: "How often L1 reasons, and whether it collects the topics it is curious about.") {
                HStack {
                    Text("Reasoning cadence")
                    Spacer()
                    Stepper("Every \(Int(model.envSettings.l1ReasoningCadenceSeconds)) s", value: l1ReasoningCadenceBinding, in: 30...600, step: 15)
                }
                Text("L1 reasons on a single unified cadence; local vision wakes provide the responsive, event-driven path.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Default language")
                    Spacer()
                    Picker("", selection: l1DefaultLanguageBinding) {
                        ForEach(SOMADefaultLanguage.allCases, id: \.self) { lang in
                            Text(lang.label).tag(lang.tag)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                Text("Used to address a person who has no stored preferred language.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Short-term memory retention")
                    Spacer()
                    Stepper("\(Int(model.envSettings.memoryShortTermRetentionHours)) h", value: memoryRetentionBinding, in: 1...24, step: 1)
                }
                Text("How long raw conversation transcripts are kept before L1 consolidation.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Web curiosity collection", isOn: l1CuriosityEnabledBinding)
                HStack {
                    Text("Collect every")
                    Picker("", selection: l1CollectionIntervalBinding) {
                        ForEach(SOMAEnvCollectionInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval.hours)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    Text("hours")
                }
                .disabled(!model.envSettings.l1CuriosityCollectionEnabled)
                Divider()
                HStack {
                    Text("Spoken opening tendency")
                    Spacer()
                    Text("\(Int(model.envSettings.l1SpokenOpeningTendency * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: l1SpokenOpeningTendencyBinding, in: 0...1, step: 0.1)
                Text("How readily L1 starts a spoken conversation when you look busy. Low = stays quiet, high = more talkative.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Open with unknown identities", isOn: l1OpenWithUnknownBinding)
                Text("When on, L1 may proactively open a spoken conversation with a person it has not yet recognized, treating them as a pseudonymous participant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(title: "L2 — Conversation & interaction", subtitle: "Whether SOMA may start a spoken conversation on its own. The live-voice voice itself is set under Experience.") {
                Toggle("Allow proactive spoken openings", isOn: l2ProactiveOpeningsBinding)
                Text("When on, L1 can hand a purposeful opening to the live-voice conversation runtime instead of staying silent.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Codex file access")
                    Spacer()
                    Picker("", selection: l2CodexSandboxBinding) {
                        ForEach(SOMACodexSandbox.allCases, id: \.self) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                Toggle("Restrict to administrator", isOn: l2CodexAdminOnlyBinding)
                Text("The conversation agent's file access. When restricted, only the administrator gets this level; everyone else is read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var administrator: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Administrator identity", subtitle: "Face embeddings are encrypted locally. Names and preferred address stay in this owner-only settings file.") {
                if model.settings.administrator == nil {
                    Label("No administrator face enrolled", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Button("Enroll face currently in view") { Task { await model.enrollLatestFace() } }
                        .disabled(model.latestAnonymousFace == nil)
                    if model.latestAnonymousFace == nil {
                        Text("Keep your face visible until Identity changes from waiting to a recognized local face.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Administrator profile enabled", isOn: Binding(
                        get: { model.settings.administrator != nil },
                        set: { enabled in if !enabled { model.removeAdministrator() } }
                    ))
                    if model.administratorProfileUnlocked {
                        TextField("Display name", text: administratorNameBinding)
                        TextField("Preferred address", text: administratorAddressBinding)
                        HStack(spacing: 8) {
                            Button("Lock profile", role: .cancel) {
                                model.administratorProfileUnlocked = false
                            }
                            Text("Edits are applied as you type.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Profile locked", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Button("Unlock to edit name & address") {
                            Task {
                                if await model.authenticateMacLogin(
                                    reason: "Editing the SOMA administrator profile requires your Mac login password."
                                ) {
                                    model.administratorProfileUnlocked = true
                                }
                            }
                        }
                    }
                    HStack {
                        StateDot(active: model.runtime.administratorVerified, color: .green)
                        Text(model.runtime.administratorVerified ? "Administrator face verified" : "Waiting for a verified administrator face")
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove administrator enrollment", role: .destructive) { model.removeAdministrator() }
                }
            }
            SettingsCard(title: "Recognition boundary", subtitle: "A visible face never grants remote or motor authority by itself.") {
                Text("SOMA labels the administrator only after repeated local profile matches. Raw embeddings remain encrypted on this Mac and are never written to the activity trace or sent as L2 context.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: model.runtime.isLive ? "SOMA is running" : "SOMA is not reporting activity", subtitle: runtimeSubtitle) {
                ActivityRow(name: "Indicator", state: model.runtime.indicatorState ?? "waiting", active: model.runtime.indicatorState != nil)
                ActivityRow(name: "Settings", state: model.runtime.sources["control_settings"] ?? "not loaded", active: model.runtime.sources["control_settings"] == "loaded")
                ActivityRow(name: "Identity engine", state: model.runtime.sources["face_identity"] ?? "waiting", active: model.runtime.sources["face_identity"] == "configured")
            }
            SettingsCard(title: "Current activity", subtitle: "A compact readout from the local runtime trace.") {
                ActivityRow(name: "Vision", state: model.runtime.sources["face_neural_engine"] ?? "waiting", active: model.runtime.isLive)
                ActivityRow(name: "Voice", state: model.settings.realtimeVoiceEnabled ? (model.runtime.sources["l2_live_voice"] ?? "armed") : "off", active: model.runtime.isLive && model.settings.realtimeVoiceEnabled)
                ActivityRow(name: "Identity", state: identityState, active: model.runtime.identity != nil)
                ActivityRow(name: "Embodiment", state: model.runtime.sources["attention_gimbal_bridge"] ?? "waiting", active: model.runtime.isLive)
            }
            SettingsCard(title: "Apply changes", subtitle: "Runtime settings are read at startup to keep L0 deterministic.") {
                Text("Save writes settings to ~/Library/Application Support/SOMA/settings.json and layer/Ollama values to the owner-only .env beside it. Save & restart relaunches the existing local SOMA service so the layer values take effect.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var identityState: String {
        if model.runtime.administratorVerified { return "administrator verified" }
        return model.runtime.identity?.state.replacingOccurrences(of: "_", with: " ") ?? "waiting"
    }

    private var runtimeSubtitle: String {
        guard let date = model.runtime.lastActivity else { return "No local trace has been observed yet." }
        let formatter = RelativeDateTimeFormatter()
        return "Last local activity \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SOMAControlSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 })
    }

    private var ledModeBinding: Binding<SOMALEDResponseMode> {
        Binding(get: { model.settings.led.responseMode }, set: { model.settings.led.responseMode = $0 })
    }

    private var ledBrightnessBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.led.brightness) },
            set: { model.settings.led.brightness = Int($0.rounded()) }
        )
    }

    private func ledSignalBinding(
        for state: SubconsciousIndicatorState
    ) -> Binding<SOMALEDSignalSettings> {
        Binding(
            get: { model.settings.led.signal(for: state) },
            set: { model.settings.led.signals[state] = $0 }
        )
    }

    private var administratorNameBinding: Binding<String> {
        Binding(
            get: { model.settings.administrator?.displayName ?? "" },
            set: { value in
                guard var administrator = model.settings.administrator else { return }
                administrator.displayName = String(value.prefix(96))
                model.settings.administrator = administrator
            }
        )
    }

    private var administratorAddressBinding: Binding<String> {
        Binding(
            get: { model.settings.administrator?.preferredAddress ?? "" },
            set: { value in
                guard var administrator = model.settings.administrator else { return }
                let normalized = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
                administrator.preferredAddress = normalized.isEmpty ? nil : normalized
                model.settings.administrator = administrator
            }
        )
    }

    private var ollamaAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.envSettings.ollamaAPIKey },
            set: { model.envSettings.ollamaAPIKey = $0 }
        )
    }

    private var ollamaHostBinding: Binding<String> {
        Binding(
            get: { model.envSettings.ollamaHost },
            set: { model.envSettings.ollamaHost = normalizeHost($0) }
        )
    }

    private var l0TrackingBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l0TrackingEnabled },
            set: { model.envSettings.l0TrackingEnabled = $0 }
        )
    }

    private var l0ExploreBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l0ExploreEnabled },
            set: { model.envSettings.l0ExploreEnabled = $0 }
        )
    }

    private var l2ProactiveOpeningsBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l2ProactiveOpeningsEnabled },
            set: { model.envSettings.l2ProactiveOpeningsEnabled = $0 }
        )
    }

    private var l2CodexSandboxBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l2CodexSandbox },
            set: { model.envSettings.l2CodexSandbox = $0 }
        )
    }

    private var l2CodexAdminOnlyBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l2CodexAdminOnly },
            set: { model.envSettings.l2CodexAdminOnly = $0 }
        )
    }

    private var l1ModelBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l1Model },
            set: { model.envSettings.l1Model = String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96)) }
        )
    }

    private var l1ReasoningCadenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1ReasoningCadenceSeconds },
            set: { model.envSettings.l1ReasoningCadenceSeconds = min(max(30, $0), 600) }
        )
    }

    private var l1DefaultLanguageBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l1DefaultLanguage },
            set: { model.envSettings.l1DefaultLanguage = $0 }
        )
    }

    private var l0E2BWakeScoreBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeScore },
            set: { model.envSettings.l0E2BWakeScore = min(max($0, 0.1), 0.95) }
        )
    }
    private var l05EnabledBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l05Enabled },
            set: { model.envSettings.l05Enabled = $0 }
        )
    }
    private var l0FaceFixationReleaseBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0FaceFixationReleaseSeconds },
            set: { model.envSettings.l0FaceFixationReleaseSeconds = max($0, 0) }
        )
    }

    private var l0E2BWakeConfidenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeConfidence },
            set: { model.envSettings.l0E2BWakeConfidence = min(max($0, 0.1), 0.95) }
        )
    }

    private var l0YoloConfidenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0YoloConfidenceThreshold },
            set: { model.envSettings.l0YoloConfidenceThreshold = min(max($0, 0.1), 0.95) }
        )
    }

    private var l0E2BWakeIntervalBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeIntervalMilliseconds },
            set: { model.envSettings.l0E2BWakeIntervalMilliseconds = max($0, 2_000) }
        )
    }

    private var l0EyeContactFreshnessBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0EyeContactFreshnessMilliseconds },
            set: { model.envSettings.l0EyeContactFreshnessMilliseconds = min(max($0, 100), 2_000) }
        )
    }

    private var l0EyeContactPupilLevelBinding: Binding<SOMAEyeContactPupilLevel> {
        Binding(
            get: { SOMAEyeContactPupilLevel(threshold: model.envSettings.l0EyeContactPupilThreshold) },
            set: { model.envSettings.l0EyeContactPupilThreshold = $0.threshold }
        )
    }

    private var memoryRetentionBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.memoryShortTermRetentionHours },
            set: { model.envSettings.memoryShortTermRetentionHours = min(max($0, 1), 24) }
        )
    }

    private var l1CuriosityEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l1CuriosityCollectionEnabled },
            set: { model.envSettings.l1CuriosityCollectionEnabled = $0 }
        )
    }

    private var l1SpokenOpeningTendencyBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1SpokenOpeningTendency },
            set: { model.envSettings.l1SpokenOpeningTendency = min(max($0, 0), 1) }
        )
    }

    private var l1OpenWithUnknownBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l1OpenWithUnknownIdentity },
            set: { model.envSettings.l1OpenWithUnknownIdentity = $0 }
        )
    }

    private var l1CollectionIntervalBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1CollectionIntervalHours },
            set: { model.envSettings.l1CollectionIntervalHours = $0 }
        )
    }

    private func normalizeHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.hasPrefix("http://"), !host.hasPrefix("https://") {
            host = "http://\(host)"
        }
        if host.hasSuffix("/") { host.removeLast() }
        return String(host.prefix(256))
    }
}

private enum SOMADefaultLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"
    case spanish = "es"

    var tag: String { rawValue }

    var label: String {
        switch self {
        case .korean: "Korean"
        case .english: "English"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .spanish: "Spanish"
        }
    }
}

/// Five preset levels for the eye-contact pupil-centering threshold. Each maps
/// to a multiplier on the default 0.68 X / 0.82 Y thresholds.
private enum SOMAEyeContactPupilLevel: CaseIterable {
    case strict, moderate, balanced, lenient, veryLenient

    var threshold: Double {
        switch self {
        case .strict: 0.5
        case .moderate: 0.75
        case .balanced: 1.0
        case .lenient: 1.5
        case .veryLenient: 2.0
        }
    }

    var label: String {
        switch self {
        case .strict: "Strict"
        case .moderate: "Moderate"
        case .balanced: "Balanced"
        case .lenient: "Lenient"
        case .veryLenient: "Very lenient"
        }
    }

    init(threshold: Double) {
        self = Self.allCases.min(by: { abs($0.threshold - threshold) < abs($1.threshold - threshold) }) ?? .balanced
    }
}

private enum SOMAEnvCollectionInterval: CaseIterable {
    case hourly6, hourly12, daily, weekly
    var hours: Double {
        switch self {
        case .hourly6: 6
        case .hourly12: 12
        case .daily: 24
        case .weekly: 168
        }
    }

    var label: String {
        switch self {
        case .hourly6: "6"
        case .hourly12: "12"
        case .daily: "24"
        case .weekly: "168"
        }
    }
}

private struct ActivityRow: View {
    let name: String
    let state: String
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            StateDot(active: active, color: active ? .green : .orange)
            Text(name)
            Spacer()
            Text(state.replacingOccurrences(of: "_", with: " "))
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
        }
        .font(.subheadline)
    }
}

private struct LEDSignalRow: View {
    let state: SubconsciousIndicatorState
    @Binding var signal: SOMALEDSignalSettings

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(accent)
                .frame(width: 11, height: 11)
                .shadow(color: accent.opacity(0.45), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(signal.pattern.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Text("Color").foregroundStyle(.secondary)
                Picker("Color", selection: colorBinding) {
                    ForEach(SOMALEDColor.selectableCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 94)
                Picker("Pattern", selection: patternBinding) {
                    ForEach(SOMALEDPattern.allCases, id: \.self) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        switch state {
        case .exploring: "Exploring"
        case .humanDetected: "Person noticed"
        case .contactReady: "Ready to talk"
        case .conversation: "Conversation"
        case .working: "Preparing reply"
        case .listening, .speaking: "Conversation"
        }
    }

    private var accent: Color {
        switch signal.color {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        }
    }

    private var colorBinding: Binding<SOMALEDColor> {
        Binding(
            get: { signal.color },
            set: { color in
                signal.color = color
            }
        )
    }

    private var patternBinding: Binding<SOMALEDPattern> {
        Binding(
            get: { signal.pattern },
            set: { signal.pattern = $0 }
        )
    }
}

private enum SOMAStatusMenuLayout {
    static let width: CGFloat = 306
    static let inset: CGFloat = 16
}

private final class SOMAStatusMenuHeader: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "SOMA")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()

    init(runtime: SOMARuntimeSnapshot, voice: SOMARealtimeVoice) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 50))
        iconView.image = SOMAMascot.image(size: 34, template: false)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 16, y: 8, width: 34, height: 34)
        addSubview(iconView)
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = (runtime.isLive ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        dotView.layer?.cornerRadius = 4
        dotView.frame = NSRect(x: 59, y: 28, width: 8, height: 8)
        addSubview(dotView)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.frame = NSRect(x: 74, y: 24, width: 208, height: 17)
        addSubview(titleLabel)
        detailLabel.stringValue = runtime.isLive ? "Live · Voice \(voice.displayName)" : "Waiting for the local runtime"
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.frame = NSRect(x: 74, y: 8, width: 208, height: 15)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuSection: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 28))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.frame = NSRect(x: SOMAStatusMenuLayout.inset, y: 6, width: 220, height: 14)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuActivityRow: NSView {
    init(name: String, state: String, active: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 28))
        let dot = NSView(frame: NSRect(x: SOMAStatusMenuLayout.inset, y: 10, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = active ? .labelColor : .secondaryLabelColor
        nameLabel.alignment = .left
        nameLabel.frame = NSRect(x: 36, y: 6, width: 84, height: 16)
        addSubview(nameLabel)

        let stateLabel = NSTextField(labelWithString: state.replacingOccurrences(of: "_", with: " "))
        stateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        stateLabel.textColor = active ? .labelColor : .secondaryLabelColor
        stateLabel.alignment = .left
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.frame = NSRect(x: 124, y: 6, width: 166, height: 16)
        addSubview(stateLabel)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuDivider: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 8))
        let line = NSView(frame: NSRect(x: SOMAStatusMenuLayout.inset, y: 3, width: SOMAStatusMenuLayout.width - SOMAStatusMenuLayout.inset * 2, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(line)
    }

    required init?(coder: NSCoder) { nil }
}

/// Non-modal progress panel for guided multi-pose face enrollment. Shows the
/// pose guidance and a live countdown while the running SOMA process (which
/// owns the camera) accumulates distinct face samples, then runs the blocking
/// promotion and reports the outcome.
@MainActor
private final class GuidedEnrollmentPanel: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let guideLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let totalSeconds: Double
    private let onEnroll: @MainActor () -> (Bool, String)
    private var timer: Timer?
    private var elapsed = 0.0
    private var finished = false
    private static var live: GuidedEnrollmentPanel?

    private init(
        totalSeconds: Double,
        onEnroll: @escaping @MainActor () -> (Bool, String)
    ) {
        self.totalSeconds = max(totalSeconds, 1)
        self.onEnroll = onEnroll
        super.init()
        build()
    }

    private func build() {
        panel.title = "Enroll Administrator Face"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = totalSeconds
        progress.doubleValue = 0

        guideLabel.font = .systemFont(ofSize: 13)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [guideLabel, progress, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
    }

    static func present(
        handle: String,
        guide: String,
        sampleWindowSeconds: Double,
        onEnroll: @escaping @MainActor () -> (Bool, String)
    ) {
        let controller = GuidedEnrollmentPanel(totalSeconds: sampleWindowSeconds, onEnroll: onEnroll)
        GuidedEnrollmentPanel.live = controller
        controller.guideLabel.stringValue = guide
        controller.statusLabel.stringValue = "Capturing samples…"
        controller.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard !finished else { return }
        elapsed += 0.1
        let remaining = max(totalSeconds - elapsed, 0)
        progress.doubleValue = min(elapsed, totalSeconds)
        if remaining > 0 {
            statusLabel.stringValue = String(format: "%.0f s remaining — keep turning your head", remaining)
        } else {
            finished = true
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = "Enrolling samples…"
            // The promotion subprocess is short; run it here so we can update
            // the panel with the final result and keep self alive via `live`.
            let outcome = onEnroll()
            finish(success: outcome.0, message: outcome.1)
        }
    }

    private func finish(success: Bool, message: String) {
        finished = true
        timer?.invalidate()
        timer = nil
        progress.stopAnimation(nil)
        statusLabel.stringValue = message
        guideLabel.stringValue = success ? "Administrator face enrolled." : "Enrollment failed."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.close()
            GuidedEnrollmentPanel.live = nil
        }
    }
}

@MainActor
private final class SOMAStatusBar: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private let menu = NSMenu()
    private let model = SOMAControlModel()
    private let opensSettingsOnLaunch: Bool
    private var settingsPanel: NSPanel?
    private var diagnosticsPanel: NSPanel?

    init(opensSettingsOnLaunch: Bool) {
        self.opensSettingsOnLaunch = opensSettingsOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        menu.minimumWidth = SOMAStatusMenuLayout.width
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = SOMAMascot.menuBarImage()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "SOMA Control Center"
        }
        if opensSettingsOnLaunch {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = SOMAStatusMenuHeader(runtime: model.runtime, voice: model.settings.realtimeVoice)
        menu.addItem(header)
        addDivider(to: menu)
        addSection("LIVE ACTIVITY", to: menu)
        addStatus("Vision", state: model.runtime.sources["face_neural_engine"] ?? "waiting", active: model.runtime.isLive, to: menu)
        addStatus("Voice", state: model.settings.realtimeVoiceEnabled ? (model.runtime.sources["l2_live_voice"] ?? "armed") : "off", active: model.settings.realtimeVoiceEnabled && model.runtime.isLive, to: menu)
        let identityText = model.runtime.administratorVerified ? "administrator verified" : (model.runtime.identity?.state ?? "waiting")
        addStatus("Identity", state: identityText, active: model.runtime.identity != nil, to: menu)
        addStatus("Embodiment", state: model.runtime.sources["attention_gimbal_bridge"] ?? "waiting", active: model.runtime.isLive, to: menu)
        addDivider(to: menu)
        menu.addItem(item("Settings…", action: #selector(openSettings)))
        menu.addItem(item("Diagnostic panel…", action: #selector(openDiagnostics)))
        if model.isSOMARunning {
            menu.addItem(item("Stop SOMA", action: #selector(stopSOMA)))
        } else {
            menu.addItem(item("Start SOMA", action: #selector(startSOMA)))
        }
        menu.addItem(item("Restart SOMA", action: #selector(restartSOMA)))
        menu.addItem(item("Open runtime folder", action: #selector(openRuntime)))
        addDivider(to: menu)
        menu.addItem(item("Quit SOMA Control", action: #selector(quit)))
    }

    private func addSection(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuSection(title: title)
        menu.addItem(item)
    }

    private func addStatus(_ name: String, state: String, active: Bool, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuActivityRow(name: name, state: state, active: active)
        menu.addItem(item)
    }

    private func addDivider(to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuDivider()
        menu.addItem(item)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() {
        if let settingsPanel {
            settingsPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "SOMA Settings"
        panel.minSize = NSSize(width: 770, height: 580)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: SOMASettingsView(
            model: model,
            onOpenDiagnostics: { [weak self] in self?.openDiagnostics() }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }

    @objc private func openDiagnostics() {
        if let diagnosticsPanel {
            diagnosticsPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Ask the runtime to start writing live diagnostic files.
        let flagURL = SOMAPaths.runtimeRoot.appendingPathComponent("live-diagnostics.enabled")
        try? Data().write(to: flagURL, options: .atomic)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "SOMA Diagnostic"
        panel.minSize = NSSize(width: 700, height: 560)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let diagnosticsModel = SOMADiagnosticsModel(runtimeRoot: SOMAPaths.runtimeRoot)
        panel.contentViewController = NSHostingController(rootView: SOMADiagnosticsView(model: diagnosticsModel))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsPanel = panel
    }

    @objc private func startSOMA() {
        let result = model.startSOMA()
        model.refresh()
        guard result.status != 0 else { return }
        NSAlert(error: NSError(
            domain: "SOMAControl",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Could not start SOMA." : result.output]
        )).runModal()
    }

    @objc private func stopSOMA() {
        let result = model.stopSOMA()
        guard result.status != 0 else { return }
        NSAlert(error: NSError(
            domain: "SOMAControl",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Could not stop SOMA." : result.output]
        )).runModal()
    }

    @objc private func restartSOMA() { model.saveAndRestart() }
    @objc private func openRuntime() { model.revealRuntime() }
    @objc private func quit() {
        model.stopControlCenter()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsPanel {
            settingsPanel = nil
        }
        if notification.object as? NSWindow === diagnosticsPanel {
            // Stop the runtime's live-diagnostic writer.
            let flagURL = SOMAPaths.runtimeRoot.appendingPathComponent("live-diagnostics.enabled")
            try? FileManager.default.removeItem(at: flagURL)
            diagnosticsPanel = nil
        }
    }
}

private let application = NSApplication.shared
private let delegate = SOMAStatusBar(opensSettingsOnLaunch: CommandLine.arguments.contains("--settings"))
application.delegate = delegate
application.run()
