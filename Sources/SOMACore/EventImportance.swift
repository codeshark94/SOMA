import Foundation

public enum CognitiveRoute: String, Codable, CaseIterable, Sendable {
    case stayL0 = "stay_l0"
    case wakeL1 = "wake_l1"
    case requestHumanInteraction = "request_human_interaction"

    public var wakesConsciousLayer: Bool {
        self == .wakeL1 || self == .requestHumanInteraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.stayL0.rawValue:
            self = .stayL0
        case Self.wakeL1.rawValue:
            self = .wakeL1
        case Self.requestHumanInteraction.rawValue, "request_l2_human":
            self = .requestHumanInteraction
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown cognitive route: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Bounded scalar evidence for a temporal transition decision. The vector is
/// intentionally model-independent so learned parameters can replace the
/// bootstrap linear model without changing the L0/L1 boundary contract.
public struct EventImportanceFeatures: Codable, Equatable, Sendable {
    public let explicitContact: Double
    public let socialSalience: Double
    public let novelty: Double
    public let predictionError: Double
    public let taskRelevance: Double
    public let memoryMismatch: Double
    public let uncertainty: Double
    public let informationGain: Double
    public let persistence: Double
    public let crossModalCorroboration: Double
    public let urgency: Double
    public let safetyRisk: Double
    public let interruptionCost: Double
    public let recentWakePressure: Double
    public let humanPresence: Double
    public let acceptedMemoryCuriosity: Double

    public init(
        explicitContact: Double = 0,
        socialSalience: Double = 0,
        novelty: Double = 0,
        predictionError: Double = 0,
        taskRelevance: Double = 0,
        memoryMismatch: Double = 0,
        uncertainty: Double = 0,
        informationGain: Double = 0,
        persistence: Double = 0,
        crossModalCorroboration: Double = 0,
        urgency: Double = 0,
        safetyRisk: Double = 0,
        interruptionCost: Double = 0,
        recentWakePressure: Double = 0,
        humanPresence: Double = 0,
        acceptedMemoryCuriosity: Double = 0
    ) {
        self.explicitContact = Self.bound(explicitContact)
        self.socialSalience = Self.bound(socialSalience)
        self.novelty = Self.bound(novelty)
        self.predictionError = Self.bound(predictionError)
        self.taskRelevance = Self.bound(taskRelevance)
        self.memoryMismatch = Self.bound(memoryMismatch)
        self.uncertainty = Self.bound(uncertainty)
        self.informationGain = Self.bound(informationGain)
        self.persistence = Self.bound(persistence)
        self.crossModalCorroboration = Self.bound(crossModalCorroboration)
        self.urgency = Self.bound(urgency)
        self.safetyRisk = Self.bound(safetyRisk)
        self.interruptionCost = Self.bound(interruptionCost)
        self.recentWakePressure = Self.bound(recentWakePressure)
        self.humanPresence = Self.bound(humanPresence)
        self.acceptedMemoryCuriosity = Self.bound(acceptedMemoryCuriosity)
    }

    private enum CodingKeys: String, CodingKey {
        case explicitContact
        case socialSalience
        case novelty
        case predictionError
        case taskRelevance
        case memoryMismatch
        case uncertainty
        case informationGain
        case persistence
        case crossModalCorroboration
        case urgency
        case safetyRisk
        case interruptionCost
        case recentWakePressure
        case humanPresence
        case acceptedMemoryCuriosity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            explicitContact: try values.decodeIfPresent(Double.self, forKey: .explicitContact) ?? 0,
            socialSalience: try values.decodeIfPresent(Double.self, forKey: .socialSalience) ?? 0,
            novelty: try values.decodeIfPresent(Double.self, forKey: .novelty) ?? 0,
            predictionError: try values.decodeIfPresent(Double.self, forKey: .predictionError) ?? 0,
            taskRelevance: try values.decodeIfPresent(Double.self, forKey: .taskRelevance) ?? 0,
            memoryMismatch: try values.decodeIfPresent(Double.self, forKey: .memoryMismatch) ?? 0,
            uncertainty: try values.decodeIfPresent(Double.self, forKey: .uncertainty) ?? 0,
            informationGain: try values.decodeIfPresent(Double.self, forKey: .informationGain) ?? 0,
            persistence: try values.decodeIfPresent(Double.self, forKey: .persistence) ?? 0,
            crossModalCorroboration: try values.decodeIfPresent(Double.self, forKey: .crossModalCorroboration) ?? 0,
            urgency: try values.decodeIfPresent(Double.self, forKey: .urgency) ?? 0,
            safetyRisk: try values.decodeIfPresent(Double.self, forKey: .safetyRisk) ?? 0,
            interruptionCost: try values.decodeIfPresent(Double.self, forKey: .interruptionCost) ?? 0,
            recentWakePressure: try values.decodeIfPresent(Double.self, forKey: .recentWakePressure) ?? 0,
            humanPresence: try values.decodeIfPresent(Double.self, forKey: .humanPresence) ?? 0,
            acceptedMemoryCuriosity: try values.decodeIfPresent(Double.self, forKey: .acceptedMemoryCuriosity) ?? 0
        )
    }

    fileprivate var vector: [Double] {
        [
            explicitContact,
            socialSalience,
            novelty,
            predictionError,
            taskRelevance,
            memoryMismatch,
            uncertainty,
            informationGain,
            persistence,
            crossModalCorroboration,
            urgency,
            safetyRisk,
            interruptionCost,
            recentWakePressure,
            humanPresence,
            acceptedMemoryCuriosity,
        ]
    }

    private static func bound(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct EventImportanceInput: Codable, Equatable, Sendable {
    public let eventID: String
    public let monotonicNS: UInt64
    public let evidenceIDs: [String]
    public let features: EventImportanceFeatures

    public init(
        eventID: String,
        monotonicNS: UInt64,
        evidenceIDs: [String],
        features: EventImportanceFeatures
    ) {
        self.eventID = String(eventID.prefix(96))
        self.monotonicNS = monotonicNS
        self.evidenceIDs = Array(evidenceIDs.prefix(16)).map { String($0.prefix(128)) }
        self.features = features
    }
}

public struct CognitiveRouteDistribution: Codable, Equatable, Sendable {
    public let stayL0: Double
    public let wakeL1: Double
    public let requestHumanInteraction: Double

    public subscript(route: CognitiveRoute) -> Double {
        switch route {
        case .stayL0: stayL0
        case .wakeL1: wakeL1
        case .requestHumanInteraction: requestHumanInteraction
        }
    }

    public var mostProbableRoute: CognitiveRoute {
        CognitiveRoute.allCases.max { self[$0] < self[$1] } ?? .stayL0
    }

    public var sum: Double {
        stayL0 + wakeL1 + requestHumanInteraction
    }

    fileprivate init(probabilities: [Double]) {
        precondition(probabilities.count == CognitiveRoute.allCases.count)
        stayL0 = probabilities[0]
        wakeL1 = probabilities[1]
        requestHumanInteraction = probabilities[2]
    }
}

public enum CognitiveTransitionPolicyReason: String, Codable, Sendable {
    case localSafety = "local_safety"
    case explicitHumanContact = "explicit_human_contact"
    case acceptedMemoryCuriosity = "accepted_memory_curiosity"
    case probabilisticEvidence = "probabilistic_evidence"
    case humanInteractionNotAuthorized = "human_interaction_not_authorized"
}

public struct EventImportanceDecision: Codable, Equatable, Sendable {
    public let modelVersion: String
    public let eventID: String
    public let monotonicNS: UInt64
    public let evidenceIDs: [String]
    public let distribution: CognitiveRouteDistribution
    public let recommendedRoute: CognitiveRoute
    public let policyReason: CognitiveTransitionPolicyReason

    /// Explicit contact opens the interaction endpoint immediately while L1
    /// prepares richer context in parallel. This is an orchestration decision,
    /// never speech content generated inside L0.
    public var dispatch: CognitiveTransitionDispatch {
        switch recommendedRoute {
        case .stayL0:
            CognitiveTransitionDispatch(
                wakeL1Context: false,
                openHumanInteraction: false,
                bypassesL1Admission: false
            )
        case .wakeL1:
            CognitiveTransitionDispatch(
                wakeL1Context: true,
                openHumanInteraction: false,
                bypassesL1Admission: false
            )
        case .requestHumanInteraction:
            CognitiveTransitionDispatch(
                wakeL1Context: policyReason == .explicitHumanContact,
                openHumanInteraction: true,
                bypassesL1Admission: policyReason == .explicitHumanContact
            )
        }
    }

    /// Samples a route from the calibrated distribution. Supplying the draw
    /// makes replay and evaluation deterministic without changing semantics.
    public func sample(unitInterval: Double) -> CognitiveRoute {
        if policyReason == .localSafety { return .stayL0 }
        if policyReason == .explicitHumanContact { return .requestHumanInteraction }
        let draw = min(max(unitInterval.isFinite ? unitInterval : 0, 0), 1.nextDown)
        var cumulative = 0.0
        for route in CognitiveRoute.allCases {
            cumulative += distribution[route]
            if draw < cumulative { return route }
        }
        return .requestHumanInteraction
    }
}

public struct CognitiveTransitionDispatch: Codable, Equatable, Sendable {
    public let wakeL1Context: Bool
    public let openHumanInteraction: Bool
    public let bypassesL1Admission: Bool

    public init(
        wakeL1Context: Bool,
        openHumanInteraction: Bool,
        bypassesL1Admission: Bool
    ) {
        self.wakeL1Context = wakeL1Context
        self.openHumanInteraction = openHumanInteraction
        self.bypassesL1Admission = bypassesL1Admission
    }
}

public struct EventImportanceParameters: Codable, Equatable, Sendable {
    public let modelVersion: String
    public let biases: [Double]
    public let weights: [[Double]]
    public let temperature: Double

    public init(
        modelVersion: String = "bootstrap-v3",
        biases: [Double],
        weights: [[Double]],
        temperature: Double = 1
    ) throws {
        let routeCount = CognitiveRoute.allCases.count
        let featureCount = EventImportanceFeatures().vector.count
        guard !modelVersion.isEmpty,
              modelVersion.count <= 64,
              biases.count == routeCount,
              weights.count == routeCount,
              weights.allSatisfy({ $0.count == featureCount }),
              biases.allSatisfy(\.isFinite),
              weights.flatMap({ $0 }).allSatisfy(\.isFinite),
              temperature.isFinite,
              temperature > 0 else {
            throw EventImportanceError.invalidParameters
        }
        self.modelVersion = modelVersion
        self.biases = biases
        self.weights = weights
        self.temperature = temperature
    }

    public static let bootstrap: EventImportanceParameters = {
        try! EventImportanceParameters(
            biases: [1.20, -0.30, -2.00],
            weights: [
                [-2.0, -0.7, -1.4, -1.2, -0.7, -0.6, 0.2, -0.5, -0.3, -0.6, 0.4, 4.0, 1.5, 1.3, -0.2, -1.0],
                [0.8, 0.8, 2.4, 2.2, 2.5, 2.8, 0.8, 2.3, 1.0, 1.2, 2.0, 0.2, -1.4, -1.8, 0.5, 1.5],
                [5.5, 1.5, 0.0, 0.0, 0.4, 0.0, 0.0, 0.2, 0.5, 1.2, 0.2, -4.0, -1.5, -1.8, 1.2, 3.8],
            ]
        )
    }()

    public func withTemperature(_ temperature: Double) throws -> EventImportanceParameters {
        try EventImportanceParameters(
            modelVersion: modelVersion,
            biases: biases,
            weights: weights,
            temperature: temperature
        )
    }
}

public enum EventImportanceError: Error, Equatable {
    case invalidParameters
    case emptyEvaluationCorpus
}

public struct EventImportanceModel: Sendable {
    public let parameters: EventImportanceParameters

    public init(parameters: EventImportanceParameters = .bootstrap) {
        self.parameters = parameters
    }

    public func evaluate(_ input: EventImportanceInput) -> EventImportanceDecision {
        let features = input.features
        var vector = features.vector
        let interactionAuthorized = Self.humanInteractionAuthorized(features)

        // A directed human request is not suppressed because optional model
        // wakes recently occurred. Cooldown remains active for all other cases.
        if features.explicitContact >= 0.80 && features.humanPresence >= 0.50 {
            vector[12] = 0
            vector[13] = 0
        }

        var logits = zip(parameters.biases, parameters.weights).map { bias, weights in
            bias + zip(weights, vector).reduce(0) { $0 + $1.0 * $1.1 }
        }

        var reason: CognitiveTransitionPolicyReason = .probabilisticEvidence
        if features.safetyRisk >= 0.50 {
            logits[0] += 6 * features.safetyRisk
            logits[1] -= 4 * features.safetyRisk
            logits[2] = -.infinity
            reason = .localSafety
        } else if !interactionAuthorized {
            logits[2] = -.infinity
            reason = .humanInteractionNotAuthorized
        } else if features.explicitContact >= 0.80 {
            reason = .explicitHumanContact
        } else if features.acceptedMemoryCuriosity >= 0.65 {
            reason = .acceptedMemoryCuriosity
        }

        let probabilities = Self.softmax(logits.map { $0 / parameters.temperature })
        let distribution = CognitiveRouteDistribution(probabilities: probabilities)
        let recommendedRoute: CognitiveRoute
        if reason == .localSafety {
            recommendedRoute = .stayL0
        } else if reason == .explicitHumanContact {
            recommendedRoute = .requestHumanInteraction
        } else {
            recommendedRoute = distribution.mostProbableRoute
        }
        return EventImportanceDecision(
            modelVersion: parameters.modelVersion,
            eventID: input.eventID,
            monotonicNS: input.monotonicNS,
            evidenceIDs: input.evidenceIDs,
            distribution: distribution,
            recommendedRoute: recommendedRoute,
            policyReason: reason
        )
    }

    private static func humanInteractionAuthorized(_ features: EventImportanceFeatures) -> Bool {
        let directContact = features.explicitContact >= 0.55 && features.humanPresence >= 0.35
        let acceptedCuriosity = features.acceptedMemoryCuriosity >= 0.65 && features.humanPresence >= 0.55
        return directContact || acceptedCuriosity
    }

    private static func softmax(_ logits: [Double]) -> [Double] {
        let finite = logits.filter(\.isFinite)
        guard let maximum = finite.max() else { return [1, 0, 0] }
        let exponentials = logits.map { $0.isFinite ? exp($0 - maximum) : 0 }
        let total = exponentials.reduce(0, +)
        guard total.isFinite, total > 0 else { return [1, 0, 0] }
        return exponentials.map { $0 / total }
    }
}

public enum EventImportancePartition: String, Codable, Sendable {
    case calibration
    case evaluation
}

public struct LabelledEventImportanceExample: Codable, Equatable, Sendable {
    public let id: String
    public let partition: EventImportancePartition
    public let expectedRoute: CognitiveRoute
    public let features: EventImportanceFeatures

    public init(
        id: String,
        partition: EventImportancePartition,
        expectedRoute: CognitiveRoute,
        features: EventImportanceFeatures
    ) {
        self.id = id
        self.partition = partition
        self.expectedRoute = expectedRoute
        self.features = features
    }

    public var input: EventImportanceInput {
        EventImportanceInput(
            eventID: id,
            monotonicNS: 0,
            evidenceIDs: ["label:\(id)"],
            features: features
        )
    }
}

public struct CognitiveRouteEvaluation: Codable, Equatable, Sendable {
    public let route: CognitiveRoute
    public let labelled: Int
    public let predicted: Int
    public let correct: Int
    public let precision: Double
    public let recall: Double

    public init(route: CognitiveRoute, labelled: Int, predicted: Int, correct: Int) {
        self.route = route
        self.labelled = labelled
        self.predicted = predicted
        self.correct = correct
        precision = predicted == 0 ? 0 : Double(correct) / Double(predicted)
        recall = labelled == 0 ? 0 : Double(correct) / Double(labelled)
    }
}

public struct EventImportanceEvaluation: Codable, Equatable, Sendable {
    public let exampleCount: Int
    public let accuracy: Double
    public let negativeLogLikelihood: Double
    public let brierScore: Double
    public let expectedCalibrationError: Double
    public let falseWakeRate: Double
    public let missedWakeRate: Double
    public let unauthorizedHumanInteractionRequests: Int
    public let routes: [CognitiveRouteEvaluation]
}

public enum EventImportanceEvaluator {
    public static func evaluate(
        model: EventImportanceModel,
        examples: [LabelledEventImportanceExample],
        calibrationBins: Int = 10
    ) throws -> EventImportanceEvaluation {
        guard !examples.isEmpty else { throw EventImportanceError.emptyEvaluationCorpus }
        let bins = max(calibrationBins, 1)
        var labelled = Array(repeating: 0, count: CognitiveRoute.allCases.count)
        var predicted = Array(repeating: 0, count: CognitiveRoute.allCases.count)
        var correct = Array(repeating: 0, count: CognitiveRoute.allCases.count)
        var binCount = Array(repeating: 0, count: bins)
        var binConfidence = Array(repeating: 0.0, count: bins)
        var binCorrect = Array(repeating: 0.0, count: bins)
        var totalCorrect = 0
        var logLoss = 0.0
        var brier = 0.0
        var falseWake = 0
        var missedWake = 0
        var unauthorizedHumanInteraction = 0

        for example in examples {
            let decision = model.evaluate(example.input)
            let predictedRoute = decision.recommendedRoute
            let expectedIndex = CognitiveRoute.allCases.firstIndex(of: example.expectedRoute)!
            let predictedIndex = CognitiveRoute.allCases.firstIndex(of: predictedRoute)!
            labelled[expectedIndex] += 1
            predicted[predictedIndex] += 1
            if predictedRoute == example.expectedRoute {
                totalCorrect += 1
                correct[expectedIndex] += 1
            }
            let expectedProbability = max(decision.distribution[example.expectedRoute], 1e-12)
            logLoss -= log(expectedProbability)
            for route in CognitiveRoute.allCases {
                let target = route == example.expectedRoute ? 1.0 : 0.0
                let error = decision.distribution[route] - target
                brier += error * error
            }
            if predictedRoute.wakesConsciousLayer && !example.expectedRoute.wakesConsciousLayer {
                falseWake += 1
            }
            if !predictedRoute.wakesConsciousLayer && example.expectedRoute.wakesConsciousLayer {
                missedWake += 1
            }
            if predictedRoute == .requestHumanInteraction,
               decision.policyReason == .humanInteractionNotAuthorized || decision.policyReason == .localSafety {
                unauthorizedHumanInteraction += 1
            }
            let confidence = decision.distribution[predictedRoute]
            let index = min(Int(confidence * Double(bins)), bins - 1)
            binCount[index] += 1
            binConfidence[index] += confidence
            if predictedRoute == example.expectedRoute { binCorrect[index] += 1 }
        }

        let count = Double(examples.count)
        let ece = zip(zip(binCount, binConfidence), binCorrect).reduce(0.0) { partial, value in
            let ((countInBin, confidenceSum), correctInBin) = value
            guard countInBin > 0 else { return partial }
            let binSize = Double(countInBin)
            return partial + (binSize / count) * abs(correctInBin / binSize - confidenceSum / binSize)
        }
        let routeMetrics = CognitiveRoute.allCases.enumerated().map { index, route in
            CognitiveRouteEvaluation(
                route: route,
                labelled: labelled[index],
                predicted: predicted[index],
                correct: correct[index]
            )
        }
        return EventImportanceEvaluation(
            exampleCount: examples.count,
            accuracy: Double(totalCorrect) / count,
            negativeLogLikelihood: logLoss / count,
            brierScore: brier / count,
            expectedCalibrationError: ece,
            falseWakeRate: Double(falseWake) / count,
            missedWakeRate: Double(missedWake) / count,
            unauthorizedHumanInteractionRequests: unauthorizedHumanInteraction,
            routes: routeMetrics
        )
    }

    public static func calibratedTemperature(
        parameters: EventImportanceParameters,
        examples: [LabelledEventImportanceExample],
        candidates: [Double] = stride(from: 0.50, through: 3.00, by: 0.05).map { $0 }
    ) throws -> Double {
        guard !examples.isEmpty else { throw EventImportanceError.emptyEvaluationCorpus }
        var bestTemperature = parameters.temperature
        var bestLoss = Double.infinity
        for temperature in candidates where temperature.isFinite && temperature > 0 {
            let candidate = try parameters.withTemperature(temperature)
            let metrics = try evaluate(model: EventImportanceModel(parameters: candidate), examples: examples)
            if metrics.negativeLogLikelihood < bestLoss {
                bestLoss = metrics.negativeLogLikelihood
                bestTemperature = temperature
            }
        }
        return bestTemperature
    }
}
