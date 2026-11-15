// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// What Hugging Face says about a token.
enum HubTokenStatus: Equatable, Sendable {
    /// The token is good. `name` is the account it belongs to; it may be empty.
    case valid(name: String)
    /// Hugging Face answered that it does not accept the token.
    case rejected
    /// No answer: the network was down, or the Hub said something else. A
    /// token that could not be checked is not called wrong.
    case unknown
}

/// Asks Hugging Face whether a token is accepted.
///
/// A public model is served to anyone, so a wrong token fails nothing there:
/// the Hub never looks at it. `whoami-v2` needs a good token, which makes it
/// the one place a wrong token shows. The token goes only to huggingface.co.
enum HubTokenCheck {
    static let endpoint = URL(string: "https://huggingface.co/api/whoami-v2")!

    /// Visible ASCII only, the form Hugging Face tokens take. Anything else
    /// would be a malformed header, so it is never sent.
    static func isSendable(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    static func request(token: String) -> URLRequest? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSendable(token) else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The meaning of an answer. Only a 401 is a rejection.
    static func status(statusCode: Int, data: Data) -> HubTokenStatus {
        switch statusCode {
        case 200:
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .valid(name: object?["name"] as? String ?? "")
        case 401:
            return .rejected
        default:
            return .unknown
        }
    }

    static func check(token: String) async -> HubTokenStatus {
        guard let request = request(token: token),
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unknown }
        return status(statusCode: http.statusCode, data: data)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: TokenRedirectGuard(), delegateQueue: nil)
    }()
}

/// A token field with the result of checking it shown beneath. The check runs
/// a moment after the last keystroke, not on each one.
///
/// The check is started by the container, which always has the field in it.
/// A line that starts out empty would never appear, and so would never run.
struct HubTokenField<Field: View>: View {
    let token: String
    @ViewBuilder let field: () -> Field

    @State private var shown: (token: String, status: HubTokenStatus)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field()
            if let shown, shown.token == token {
                switch shown.status {
                case .valid(let name):
                    Label(name.isEmpty ? "Hugging Face accepts this token." : "Signed in to Hugging Face as \(name).",
                          systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                case .rejected:
                    Label("Hugging Face rejected this token.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .unknown:
                    EmptyView()
                }
            }
        }
        .task(id: token) {
            let value = token
            guard HubTokenCheck.isSendable(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                shown = nil
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            let status = await HubTokenCheck.check(token: value)
            guard !Task.isCancelled else { return }
            shown = (value, status)
        }
    }
}
