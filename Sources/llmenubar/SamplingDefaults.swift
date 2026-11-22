// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

extension ServerConfiguration.Config {
    /// One value `--sampling-default` sets, and what Settings shows for it.
    struct SamplingParameter {
        let name: String
        let title: String
        let field: Field
        let keyPath: WritableKeyPath<ServerConfiguration.Config, String>
        let rule: SplashOptionValues.SamplingRule
        /// What a request that sets none gets when this is empty.
        let defaultText: String
        let defaultNote: String
    }

    private static let familyDefault = "Default: the model family's published value."

    /// In the order Splash lists them.
    nonisolated(unsafe) static let samplingParameters: [SamplingParameter] = [
        .init(name: "temperature", title: "Temperature", field: .samplingTemperature,
              keyPath: \.samplingTemperature, rule: .closed(0, 2),
              defaultText: "Model's own", defaultNote: familyDefault),
        .init(name: "top_p", title: "Top P", field: .samplingTopP,
              keyPath: \.samplingTopP, rule: .aboveZero(upTo: 1),
              defaultText: "Model's own", defaultNote: familyDefault),
        .init(name: "top_k", title: "Top K", field: .samplingTopK,
              keyPath: \.samplingTopK, rule: .wholeNumber,
              defaultText: "Model's own", defaultNote: familyDefault + " 0 or -1 turns it off."),
        .init(name: "min_p", title: "Min P", field: .samplingMinP,
              keyPath: \.samplingMinP, rule: .closed(0, 1),
              defaultText: "0", defaultNote: "Default: 0, which changes nothing."),
        .init(name: "presence_penalty", title: "Presence penalty", field: .samplingPresencePenalty,
              keyPath: \.samplingPresencePenalty, rule: .closed(-2, 2),
              defaultText: "0", defaultNote: "Default: 0, which changes nothing."),
        .init(name: "frequency_penalty", title: "Frequency penalty", field: .samplingFrequencyPenalty,
              keyPath: \.samplingFrequencyPenalty, rule: .closed(-2, 2),
              defaultText: "0", defaultNote: "Default: 0, which changes nothing."),
        .init(name: "repetition_penalty", title: "Repetition penalty", field: .samplingRepetitionPenalty,
              keyPath: \.samplingRepetitionPenalty, rule: .aboveZero(upTo: Double(Float.greatestFiniteMagnitude)),
              defaultText: "1", defaultNote: "Default: 1, which changes nothing."),
    ]

    /// Whether any value is set.
    var hasSamplingDefaults: Bool {
        Self.samplingParameters.contains { !self[keyPath: $0.keyPath].isEmpty }
    }

    /// `NAME=VALUE` for each value set, one per `--sampling-default`.
    var samplingArguments: [String] {
        Self.samplingParameters.compactMap { parameter in
            let value = self[keyPath: parameter.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : parameter.name + "=" + value
        }
    }

    /// Why the value of `parameter` is refused, or nil.
    func samplingIssue(_ parameter: SamplingParameter) -> String? {
        let value = self[keyPath: parameter.keyPath]
        guard !value.isEmpty, !parameter.rule.accepts(value) else { return nil }
        return "Use \(parameter.rule.requirement)."
    }
}
