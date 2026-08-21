import Foundation

/// Identifies the image and detections derived from one camera capture.
/// The menu-bar panel swaps only a complete manifest, which keeps overlays
/// bound to the exact pixels used for the corresponding inference.
public struct LiveDiagnosticsFrameManifest: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let capturedAtNS: UInt64
    public let frameFilename: String
    public let visionFilename: String

    public init(
        generation: UInt64,
        capturedAtNS: UInt64,
        frameFilename: String,
        visionFilename: String
    ) {
        self.generation = generation
        self.capturedAtNS = capturedAtNS
        self.frameFilename = frameFilename
        self.visionFilename = visionFilename
    }

    /// Manifest entries are filenames, never paths outside the diagnostic
    /// frame directory.
    public var containsOnlyFilenames: Bool {
        [frameFilename, visionFilename].allSatisfy { filename in
            !filename.isEmpty
                && filename == URL(fileURLWithPath: filename).lastPathComponent
                && filename != "."
                && filename != ".."
        }
    }

    public var filenamesMatchGeneration: Bool {
        frameFilename == "frame-\(generation).jpg"
            && visionFilename == "vision-\(generation).json"
    }
}
