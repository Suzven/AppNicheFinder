//
//  OpenAIService.swift
//  AppNicheFinder
//

import Foundation

// MARK: - Errors
enum OpenAIError: LocalizedError {
    case noReviews
    case badStatusCode(Int, String)
    case emptyResponse
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .noReviews:                return "Нет плохих отзывов для анализа."
        case .badStatusCode(let c, let m): return "OpenAI вернул код \(c). \(m)"
        case .emptyResponse:            return "OpenAI вернул пустой ответ."
        case .invalidPayload:           return "Не удалось сформировать запрос к OpenAI."
        }
    }
}

// MARK: - Protocol
protocol OpenAIServicing {
    func summarizeComplaints(appTitle: String, reviews: [AppReview]) async throws -> String
}

// MARK: - Service
actor OpenAIService: OpenAIServicing {

    // ⚠️ ВНИМАНИЕ: хардкод ключа в клиентском приложении НЕБЕЗОПАСНО.
    // Любой может вытащить его из IPA. Для прода — проксируй запросы через свой бэкенд.
    private let apiKey = "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"
    private let model = "gpt-4o"  // мощная модель — даёт связные саммари по жалобам

    func summarizeComplaints(appTitle: String, reviews: [AppReview]) async throws -> String {
        guard !reviews.isEmpty else { throw OpenAIError.noReviews }

        // Готовим компактный список отзывов: rating + текст
        // Ограничим длину, чтобы не упереться в контекст-окно.
        let joined = reviews
            .prefix(300)
            .map { "[\($0.rating)★ v\($0.version)] \($0.title.isEmpty ? "" : $0.title + " — ")\($0.body)" }
            .joined(separator: "\n---\n")

        let systemPrompt = """
        Ты — продуктовый аналитик. На вход получаешь список плохих отзывов из App Store (3 звезды и ниже).
        Твоя задача — выделить ключевые жалобы пользователей и сделать структурированное саммари на русском языке.

        Формат ответа:
        1. Кратко (2-3 предложения) — главные боли пользователей.
        2. Топ-проблем — маркированный список, каждая проблема: коротко суть + примерная частота (часто/иногда/редко) + 1 короткая цитата в кавычках если уместно.
        3. Возможные причины — гипотезы, что именно ломается или плохо сделано.
        4. Что улучшить в первую очередь — приоритизированный список действий.

        Не выдумывай факты, опирайся только на отзывы. Если жалоб мало — так и скажи.
        """

        let userPrompt = """
        Приложение: \(appTitle)
        Количество отзывов на анализ: \(reviews.count)

        ОТЗЫВЫ:
        \(joined)
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw OpenAIError.invalidPayload
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        NetworkLogger.logRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NetworkLogger.logResponse(nil, data: nil, error: error, requestURL: request.url)
            throw error
        }
        NetworkLogger.logResponse(response, data: data, requestURL: request.url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.badStatusCode(http.statusCode, raw)
        }

        // Парсим { choices: [ { message: { content: "..." } } ] }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenAIError.emptyResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
