import Foundation
import SOMACore

enum OwnerOnlyInstallationSecretError: LocalizedError {
    case insecurePermissions

    var errorDescription: String? {
        switch self {
        case .insecurePermissions:
            "installation secret permissions must be owner-only"
        }
    }
}

/// A local installation secret for unattended, persistent SOMA workers.
/// Keychain calls can wait for a GUI authorization agent, which is unsuitable
/// for the L0 startup path. The caller keeps encrypted data beside a dedicated
/// owner-only secret; neither is exported from this Mac.
enum OwnerOnlyInstallationSecret {
    static func loadOrCreate(
        in directoryURL: URL,
        filename: String
    ) throws -> CognitiveMemoryEncryptionKey {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let keyURL = directoryURL.appendingPathComponent(filename, isDirectory: false)

        if fileManager.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL, options: .mappedIfSafe)
            try requireOwnerOnlyPermissions(of: keyURL)
            return try CognitiveMemoryEncryptionKey(rawRepresentation: data)
        }

        let key = CognitiveMemoryEncryptionKey.generate()
        do {
            try key.rawRepresentation.write(to: keyURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            return key
        } catch CocoaError.fileWriteFileExists {
            let data = try Data(contentsOf: keyURL, options: .mappedIfSafe)
            try requireOwnerOnlyPermissions(of: keyURL)
            return try CognitiveMemoryEncryptionKey(rawRepresentation: data)
        }
    }

    private static func requireOwnerOnlyPermissions(of keyURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw OwnerOnlyInstallationSecretError.insecurePermissions
        }
    }
}
