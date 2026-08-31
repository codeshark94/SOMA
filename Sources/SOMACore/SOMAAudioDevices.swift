import CoreAudio
import Foundation

public struct SOMAAudioDeviceDescriptor: Identifiable, Hashable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct SOMAAudioDeviceSnapshot: Equatable, Sendable {
    public let inputs: [SOMAAudioDeviceDescriptor]
    public let outputs: [SOMAAudioDeviceDescriptor]
    public let defaultInputUID: String?
    public let defaultOutputUID: String?

    public init(
        inputs: [SOMAAudioDeviceDescriptor],
        outputs: [SOMAAudioDeviceDescriptor],
        defaultInputUID: String?,
        defaultOutputUID: String?
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.defaultInputUID = defaultInputUID
        self.defaultOutputUID = defaultOutputUID
    }
}

public enum SOMAAudioDeviceScope: Sendable {
    case input
    case output

    fileprivate var coreAudioScope: AudioObjectPropertyScope {
        switch self {
        case .input: kAudioDevicePropertyScopeInput
        case .output: kAudioDevicePropertyScopeOutput
        }
    }
}

public enum SOMAAudioDeviceCatalog {
    public static func snapshot() -> SOMAAudioDeviceSnapshot {
        let deviceIDs = allDeviceIDs()
        let inputs = descriptors(from: deviceIDs, scope: .input)
        let outputs = descriptors(from: deviceIDs, scope: .output)
        return SOMAAudioDeviceSnapshot(
            inputs: inputs,
            outputs: outputs,
            defaultInputUID: defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice),
            defaultOutputUID: defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    public static func deviceID(
        forUID uid: String,
        scope: SOMAAudioDeviceScope
    ) -> AudioDeviceID? {
        allDeviceIDs().first { deviceID in
            hasStreams(deviceID, scope: scope) && stringProperty(
                deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ) == uid
        }
    }

    private static func descriptors(
        from deviceIDs: [AudioDeviceID],
        scope: SOMAAudioDeviceScope
    ) -> [SOMAAudioDeviceDescriptor] {
        deviceIDs.compactMap { deviceID in
            guard hasStreams(deviceID, scope: scope),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return SOMAAudioDeviceDescriptor(uid: uid, name: name)
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func hasStreams(
        _ deviceID: AudioDeviceID,
        scope: SOMAAudioDeviceScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope.coreAudioScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func defaultDeviceUID(
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }
}
