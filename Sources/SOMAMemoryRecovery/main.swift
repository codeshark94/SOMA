import Foundation
import SOMACore

private func usage() -> Never {
    FileHandle.standardError.write(Data("Usage: soma-memory-recover --stage <memory-directory> <recovery-directory> | --verify <memory-directory> <key-directory>\n".utf8))
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count == 4,
      arguments[1] == "--stage" || arguments[1] == "--verify" else {
    usage()
}

let mode = arguments[1]
let sourceDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let keyDirectory = mode == "--stage"
    ? sourceDirectory
    : URL(fileURLWithPath: arguments[3], isDirectory: true)
let keyURL = keyDirectory.appendingPathComponent("installation-key-v1.bin")

do {
    let key = try CognitiveMemoryEncryptionKey(rawRepresentation: Data(contentsOf: keyURL))
    switch mode {
    case "--stage":
        let recoveryDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let report = try CognitiveMemoryStore.stageRecoverablePrefix(
            from: sourceDirectory,
            encryptionKey: key,
            into: recoveryDirectory
        )
        let rejectedLine = report.firstRejectedLine.map(String.init) ?? "none"
        print(
            "SOMA_MEMORY_RECOVERY staged=true"
                + " source_entries=\(report.sourceEntryCount)"
                + " recovered_entries=\(report.recoveredEntryCount)"
                + " first_rejected_line=\(rejectedLine)"
                + " activation=not_performed"
        )
    case "--verify":
        let store = try CognitiveMemoryStore(directoryURL: sourceDirectory, encryptionKey: key)
        let statistics = try await store.stats()
        try await store.close()
        print(
            "SOMA_MEMORY_RECOVERY verified=true"
                + " active_records=\(statistics.activeRecords)"
                + " short_term_records=\(statistics.shortTermRecords)"
                + " medium_term_records=\(statistics.mediumTermRecords)"
                + " long_term_records=\(statistics.longTermRecords)"
                + " journal_sequence=\(statistics.journalSequence)"
        )
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("SOMA_MEMORY_RECOVERY staged=false error=\(error)\n".utf8))
    exit(1)
}
