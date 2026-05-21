//
//  NetworkLogger.swift
//  AppNicheFinder
//

import Foundation
import OSLog

enum NetworkLogger {

    private static let logger = Logger(subsystem: "AppNicheFinder", category: "Network")

    // MARK: - Request
    static func logRequest(_ request: URLRequest) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<no url>"

        var lines: [String] = []
        lines.append("➡️ REQUEST \(method) \(url)")

        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            lines.append("   Headers:")
            for (k, v) in headers {
                lines.append("     \(k): \(v)")
            }
        } else {
            lines.append("   Headers: (none)")
        }

        if let body = request.httpBody {
            if let json = prettyJSON(body) {
                lines.append("   Body (json):")
                lines.append(indent(json))
            } else if let text = String(data: body, encoding: .utf8) {
                lines.append("   Body (text):")
                lines.append(indent(text))
            } else {
                lines.append("   Body: <\(body.count) bytes binary>")
            }
        } else {
            lines.append("   Body: (none)")
        }

        let message = lines.joined(separator: "\n")
        logger.debug("\(message, privacy: .public)")
        print(message)
    }

    // MARK: - Response
    static func logResponse(_ response: URLResponse?, data: Data?, error: Error? = nil, requestURL: URL?) {
        var lines: [String] = []
        let url = response?.url?.absoluteString ?? requestURL?.absoluteString ?? "<no url>"

        if let http = response as? HTTPURLResponse {
            lines.append("⬅️ RESPONSE [\(http.statusCode)] \(url)")
            if !http.allHeaderFields.isEmpty {
                lines.append("   Headers:")
                for (k, v) in http.allHeaderFields {
                    lines.append("     \(k): \(v)")
                }
            }
        } else {
            lines.append("⬅️ RESPONSE \(url)")
        }

        if let error {
            lines.append("   Error: \(error.localizedDescription)")
        }

        if let data, !data.isEmpty {
            if let json = prettyJSON(data) {
                lines.append("   Body (json, \(data.count) bytes):")
                lines.append(indent(json))
            } else if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.count > 4000 ? String(text.prefix(4000)) + "\n…[truncated, total \(text.count) chars]" : text
                lines.append("   Body (text, \(data.count) bytes):")
                lines.append(indent(trimmed))
            } else {
                lines.append("   Body: <\(data.count) bytes binary>")
            }
        } else {
            lines.append("   Body: (empty)")
        }

        let message = lines.joined(separator: "\n")
        logger.debug("\(message, privacy: .public)")
        print(message)
    }

    // MARK: - Helpers
    private static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }

    private static func indent(_ text: String, by spaces: Int = 4) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
