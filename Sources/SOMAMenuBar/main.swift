import AppKit
import Foundation
import SOMACore
import SwiftUI

private enum SOMAPaths {
    static let runtimeRoot = URL(fileURLWithPath: "/Users/seungyeop/workspace/Research/SOMA/artifacts/subconscious/runtime", isDirectory: true)
    static let serviceLabel = "com.soma.reactive-l0"

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
    @Published private(set) var runtime = SOMARuntimeSnapshot.empty
    @Published private(set) var message: String?

    private let store: SOMAControlSettingsStore
    init(store: SOMAControlSettingsStore = .init()) {
        self.store = store
        do {
            settings = try store.load()
        } catch {
            settings = .init()
            message = error.localizedDescription
        }
        refresh()
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var latestAnonymousFace: String? {
        guard let identity = runtime.identity,
              identity.state == "anonymous_recognized",
              identity.subject.hasPrefix("anon_") else { return nil }
        return identity.subject
    }

    func refresh() {
        runtime = SOMARuntimeSnapshot.read(settings: settings)
    }

    func save() {
        do {
            try store.save(settings)
            message = "Saved locally. Restart SOMA to apply runtime changes."
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func saveAndRestart() {
        save()
        guard message?.hasPrefix("Saved locally") == true else { return }
        let result = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(SOMAPaths.serviceLabel)"])
        message = result.status == 0
            ? "Saved and SOMA is restarting."
            : (result.output.isEmpty ? "Could not restart SOMA." : result.output)
    }

    func enrollLatestFace() {
        guard let handle = latestAnonymousFace else {
            message = "Stand in view until SOMA shows a recognized local face."
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Enroll administrator face?"
        confirmation.informativeText = "SOMA will save an encrypted local face template for the currently recognized face. It stays on this Mac and can be removed from this panel."
        confirmation.addButton(withTitle: "Enroll")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let result = runSubconscious(["--promote-anonymous-face", handle])
        guard result.status == 0,
              let entityID = parseValue("entity_id", from: result.output).flatMap(UUID.init(uuidString:)) else {
            message = result.output.isEmpty ? "Could not enroll this face." : result.output
            return
        }
        let name = settings.administrator?.displayName ?? "Administrator"
        let address = settings.administrator?.preferredAddress
        settings.administrator = SOMAAdministratorIdentity(
            entityID: entityID,
            displayName: name,
            preferredAddress: address
        )
        do {
            try store.save(settings)
            message = "Administrator enrolled. Restart SOMA to load the profile."
        } catch {
            message = error.localizedDescription
        }
    }

    func removeAdministrator() {
        guard let administrator = settings.administrator else { return }
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
            "/Users/seungyeop/Library/LaunchAgents/com.soma.menu-bar.plist",
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
    case embodiment = "Embodiment"
    case administrator = "Administrator"
    case system = "System"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .experience: "waveform"
        case .embodiment: "camera.metering.center.weighted"
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
            NSColor.systemPink.withAlphaComponent(0.62).setFill()
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

private struct SOMASettingsView: View {
    @ObservedObject var model: SOMAControlModel
    @State private var selection: SOMASettingsSection = .experience

    private var selectedSection: SOMASettingsSection { selection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    sectionContent
                    if let message = model.message {
                        Label(message, systemImage: "info.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                    HStack {
                        Button("Open runtime") { model.revealRuntime() }
                        Spacer()
                        Button("Save") { model.save() }
                        Button("Save & restart SOMA") { model.saveAndRestart() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 2)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 770, idealWidth: 820, minHeight: 580, idealHeight: 620)
        .tint(.pink)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: SOMAMascot.image(size: 34, template: false))
                    .resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SOMA").font(.headline)
                    Text(model.runtime.isLive ? "Running locally" : "Waiting for runtime")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            VStack(spacing: 3) {
                ForEach(SOMASettingsSection.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selection == item ? Color.primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                }
            }
            .padding(.horizontal, 8)
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
            Spacer()
            StateDot(active: model.runtime.isLive, color: .green)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .experience: experience
        case .embodiment: embodiment
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
            SettingsCard(title: "LED signals", subtitle: "Choose a verified color and behavior. Continuous blinking is available in blue.") {
                LazyVStack(spacing: 8) {
                    ForEach(SubconsciousIndicatorState.configurationStates, id: \.self) { state in
                        LEDSignalRow(state: state, signal: ledSignalBinding(for: state))
                    }
                }
            }
        }
    }

    private var embodiment: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Attention movement", subtitle: "These controls can only restrict the safety-approved motion capabilities of the active service.") {
                Toggle("Track a verified human face", isOn: binding(\.nativeHumanTrackingEnabled))
                Toggle("Explore when no verified target is present", isOn: binding(\.autonomousExplorationEnabled))
            }
            SettingsCard(title: "Current activity", subtitle: "A compact readout from the local runtime trace.") {
                ActivityRow(name: "Vision", state: model.runtime.sources["face_neural_engine"] ?? "waiting", active: model.runtime.isLive)
                ActivityRow(name: "Voice", state: model.settings.realtimeVoiceEnabled ? (model.runtime.sources["l2_live_voice"] ?? "armed") : "off", active: model.runtime.isLive && model.settings.realtimeVoiceEnabled)
                ActivityRow(name: "Identity", state: identityState, active: model.runtime.identity != nil)
                ActivityRow(name: "Embodiment", state: model.runtime.sources["attention_gimbal_bridge"] ?? "waiting", active: model.runtime.isLive)
            }
        }
    }

    private var administrator: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Administrator identity", subtitle: "Face embeddings are encrypted locally. Names and preferred address stay in this owner-only settings file.") {
                if model.settings.administrator == nil {
                    Label("No administrator face enrolled", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Button("Enroll face currently in view") { model.enrollLatestFace() }
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
                    TextField("Display name", text: administratorNameBinding)
                    TextField("Preferred address", text: administratorAddressBinding)
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
            SettingsCard(title: "Apply changes", subtitle: "Runtime settings are read at startup to keep L0 deterministic.") {
                Text("Save writes only to ~/Library/Application Support/SOMA/settings.json with owner-only permissions. Save & restart relaunches the existing local SOMA service.")
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
                CadencePreview(pattern: signal.pattern, color: accent)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Color").foregroundStyle(.secondary)
                    Picker("Color", selection: colorBinding) {
                        ForEach(SOMALEDColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(color)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 94)
                }
                HStack(spacing: 8) {
                    Text("Behavior").foregroundStyle(.secondary)
                    Picker("Behavior", selection: $signal.pattern) {
                        ForEach(availablePatterns, id: \.self) { pattern in
                            Text(pattern.displayName).tag(pattern)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
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
                if !signal.pattern.isPhysicallySupported(for: color) {
                    signal.pattern = .steady
                }
            }
        )
    }

    private var availablePatterns: [SOMALEDPattern] {
        signal.color == .blue ? [.steady, .blink] : [.steady]
    }
}

private struct CadencePreview: View {
    let pattern: SOMALEDPattern
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(pattern.indicatorPattern.phases.enumerated()), id: \.offset) { _, phase in
                Capsule(style: .continuous)
                    .fill(phase.illuminated ? color : Color.secondary.opacity(0.25))
                    .frame(width: phase.durationMilliseconds == nil ? 42 : cadenceWidth(phase.durationMilliseconds!), height: 4)
            }
        }
        .accessibilityLabel("\(pattern.displayName) cadence")
    }

    private func cadenceWidth(_ milliseconds: UInt64) -> CGFloat {
        max(8, min(36, CGFloat(milliseconds) / 32))
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
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 58))
        iconView.image = SOMAMascot.image(size: 34, template: false)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 16, y: 10, width: 34, height: 34)
        addSubview(iconView)
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = (runtime.isLive ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        dotView.layer?.cornerRadius = 4
        dotView.frame = NSRect(x: 59, y: 33, width: 8, height: 8)
        addSubview(dotView)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 74, y: 28, width: 208, height: 18)
        addSubview(titleLabel)
        detailLabel.stringValue = runtime.isLive ? "Live · Voice \(voice.displayName)" : "Waiting for the local runtime"
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 74, y: 11, width: 208, height: 16)
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
        nameLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = active ? .labelColor : .secondaryLabelColor
        nameLabel.frame = NSRect(x: 36, y: 6, width: 84, height: 16)
        addSubview(nameLabel)

        let stateLabel = NSTextField(labelWithString: state.replacingOccurrences(of: "_", with: " "))
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stateLabel.textColor = active ? .labelColor : .secondaryLabelColor
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

@MainActor
private final class SOMAStatusBar: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private let menu = NSMenu()
    private let model = SOMAControlModel()
    private let opensSettingsOnLaunch: Bool
    private var settingsPanel: NSPanel?

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
        panel.contentViewController = NSHostingController(rootView: SOMASettingsView(model: model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = panel
    }

    @objc private func restartSOMA() { model.saveAndRestart() }
    @objc private func openRuntime() { model.revealRuntime() }
    @objc private func quit() {
        model.stopControlCenter()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsPanel { settingsPanel = nil }
    }
}

private let application = NSApplication.shared
private let delegate = SOMAStatusBar(opensSettingsOnLaunch: CommandLine.arguments.contains("--settings"))
application.delegate = delegate
application.run()
