import Foundation
import SOMACore

private struct EvaluationReport: Codable {
    let corpus: String
    let status: String
    let calibrationExamples: Int
    let evaluationExamples: Int
    let fittedTemperature: Double
    let calibration: EventImportanceEvaluation
    let evaluation: EventImportanceEvaluation
}

private func loadJSONL(_ url: URL) throws -> [LabelledEventImportanceExample] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .enumerated()
        .map { index, line in
            do {
                return try decoder.decode(LabelledEventImportanceExample.self, from: Data(line.utf8))
            } catch {
                throw NSError(
                    domain: "soma-event-eval",
                    code: index + 1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid corpus row \(index + 1): \(error)"]
                )
            }
        }
}

do {
    guard let corpusURL = Bundle.module.url(forResource: "bootstrap-v3", withExtension: "jsonl") else {
        throw NSError(
            domain: "soma-event-eval",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "bootstrap corpus is missing"]
        )
    }
    let examples = try loadJSONL(corpusURL)
    let calibrationExamples = examples.filter { $0.partition == .calibration }
    let evaluationExamples = examples.filter { $0.partition == .evaluation }
    let temperature = try EventImportanceEvaluator.calibratedTemperature(
        parameters: .bootstrap,
        examples: calibrationExamples
    )
    let parameters = try EventImportanceParameters.bootstrap.withTemperature(temperature)
    let model = EventImportanceModel(parameters: parameters)
    let report = EvaluationReport(
        corpus: "bootstrap-v3",
        status: "bootstrap_contract_only_not_deployment_accuracy",
        calibrationExamples: calibrationExamples.count,
        evaluationExamples: evaluationExamples.count,
        fittedTemperature: temperature,
        calibration: try EventImportanceEvaluator.evaluate(model: model, examples: calibrationExamples),
        evaluation: try EventImportanceEvaluator.evaluate(model: model, examples: evaluationExamples)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fputs("soma-event-eval: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
