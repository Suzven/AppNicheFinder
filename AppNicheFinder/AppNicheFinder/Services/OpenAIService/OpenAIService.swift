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
    case missingKey

    var errorDescription: String? {
        switch self {
        case .noReviews:                return "Нет плохих отзывов для анализа."
        case .badStatusCode(let c, let m): return "OpenAI вернул код \(c). \(m)"
        case .emptyResponse:            return "OpenAI вернул пустой ответ."
        case .invalidPayload:           return "Не удалось сформировать запрос к OpenAI."
        case .missingKey:               return "Не задан OpenAI API key. Открой настройки и введи ключ."
        }
    }
}

// MARK: - Protocol
protocol OpenAIServicing {
    func summarizeComplaints(appTitle: String, reviews: [AppReview]) async throws -> String
    func summarizePraise(appTitle: String, reviews: [AppReview]) async throws -> String
    func metaAnalysis(payload: MetaAnalysisPayload) async throws -> String
}

// MARK: - Meta-analysis input
struct MetaAnalysisPayload {
    struct AppEntry {
        let title: String
        let subtitle: String
        let genre: String
        let installsEstimate: Int      // средний install estimate
        let ratingsCount: Int
        let averageRating: Double
        let isPaid: Bool
        let formattedPrice: String
        let iaps: [AppIAP]
        let complaintsSummary: String
        let praiseSummary: String
        let revenueMinUSD: Double
        let revenueMaxUSD: Double
        let firstReleaseDate: Date?
        let lastUpdateDate: Date?
        let description: String
    }
    let apps: [AppEntry]
}

// MARK: - Service
actor OpenAIService: OpenAIServicing {

    // Ключ читается из настроек пользователя (см. AppSettings).
    // Хардкод убран — небезопасно держать ключ в коде, к тому же ключи часто ротируются.
    private var apiKey: String { AppSettings.shared.openAIKey }
    private let model = "gpt-4o"  // мощная модель — даёт связные саммари по жалобам

    func summarizeComplaints(appTitle: String, reviews: [AppReview]) async throws -> String {
        guard !reviews.isEmpty else { throw OpenAIError.noReviews }
        let joined = reviewsToText(reviews, limit: 300)

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
        let userPrompt = "Приложение: \(appTitle)\nКоличество отзывов на анализ: \(reviews.count)\n\nОТЗЫВЫ:\n\(joined)"
        return try await chat(system: systemPrompt, user: userPrompt)
    }

    // MARK: - Praise summary
    func summarizePraise(appTitle: String, reviews: [AppReview]) async throws -> String {
        guard !reviews.isEmpty else { throw OpenAIError.noReviews }
        let joined = reviewsToText(reviews, limit: 200)

        let systemPrompt = """
        Ты — продуктовый аналитик. На вход получаешь хорошие отзывы из App Store (4-5 звёзд).
        Многие хорошие отзывы — общие/шаблонные/накрученные («лучшее приложение», «класс», «спасибо разработчикам»).
        Твоя задача — игнорировать общие фразы и вытащить КОНКРЕТНЫЕ ФИЧИ и СВОЙСТВА продукта, которые пользователи ценят:
        - что именно работает хорошо (конкретные функции, экраны, сценарии)
        - какие проблемы юзеров приложение решает на практике
        - какие свойства (скорость, точность, UX, цена, поддержка) отмечают

        Формат ответа на русском языке:
        1. Кратко (2-3 предложения) — за что реально хвалят (только конкретика).
        2. Топ-фичи которые ценят — маркированный список: фича/свойство + частота (часто/иногда) + короткая цитата если есть.
        3. Что приложение делает лучше альтернатив (если есть упоминания сравнений).
        4. Сильные стороны продуктовой стратегии — что точно стоит копировать конкурентам.

        ИГНОРИРУЙ отзывы без содержания вроде «отличное приложение, рекомендую» — отметь это в конце одной строкой.
        Не придумывай факты. Опирайся только на отзывы.
        """
        let userPrompt = "Приложение: \(appTitle)\nКоличество отзывов на анализ: \(reviews.count)\n\nОТЗЫВЫ:\n\(joined)"
        return try await chat(system: systemPrompt, user: userPrompt)
    }

    // MARK: - Meta-analysis across multiple apps
    func metaAnalysis(payload: MetaAnalysisPayload) async throws -> String {
        guard !payload.apps.isEmpty else { throw OpenAIError.noReviews }

        // Сборка инпута
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let now = Date()

        var corpus = ""
        for (i, app) in payload.apps.enumerated() {
            let iapList = app.iaps.isEmpty
                ? "нет"
                : app.iaps.map { "  - \($0.name): \($0.priceFormatted)\($0.isSubscription ? " (subscription)" : "")" }.joined(separator: "\n")

            // Активность приложения по датам
            let firstRelease = app.firstReleaseDate.map { dateFormatter.string(from: $0) } ?? "—"
            let lastUpdate   = app.lastUpdateDate.map  { dateFormatter.string(from: $0) } ?? "—"
            let ageYears: String = {
                guard let d = app.firstReleaseDate else { return "—" }
                let years = now.timeIntervalSince(d) / (365.25 * 86400)
                return String(format: "%.1f лет", years)
            }()
            let daysSinceUpdate: String = {
                guard let d = app.lastUpdateDate else { return "—" }
                let days = Int(now.timeIntervalSince(d) / 86400)
                return "\(days) дней назад"
            }()

            // Описание (обрезаем до 1500 символов, чтобы по всем апам не выйти за контекст)
            let truncatedDesc: String = {
                let raw = app.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.count <= 1500 { return raw }
                return String(raw.prefix(1500)) + "…[обрезано]"
            }()

            corpus += """
            =====================================
            ПРИЛОЖЕНИЕ #\(i + 1): \(app.title)
            Subtitle: \(app.subtitle.isEmpty ? "—" : app.subtitle)
            Категория: \(app.genre)
            Оценка: \(String(format: "%.2f", app.averageRating)) (\(app.ratingsCount) оценок)
            Примерные установки: \(app.installsEstimate)
            Доход (lifetime USD): $\(Int(app.revenueMinUSD)) – $\(Int(app.revenueMaxUSD))
            Монетизация: \(app.isPaid ? "Платное \(app.formattedPrice)" : "Free / Freemium")
            АКТИВНОСТЬ: первый релиз \(firstRelease) (возраст \(ageYears)), последнее обновление \(lastUpdate) (\(daysSinceUpdate))
            IAP:
            \(iapList)

            ОПИСАНИЕ (как разработчик позиционирует продукт и какие кор-фичи заявляет):
            \(truncatedDesc.isEmpty ? "—" : truncatedDesc)

            ЖАЛОБЫ:
            \(app.complaintsSummary.isEmpty ? "—" : app.complaintsSummary)

            ЧТО ХВАЛЯТ (конкретика):
            \(app.praiseSummary.isEmpty ? "—" : app.praiseSummary)

            """
        }

        let systemPrompt = """
        Ты — senior продуктовый аналитик и UA-эксперт по мобильным приложениям.
        Тебе дают агрегированные данные по нескольким конкурентам в одной нише:
        характеристики, даты релиза и обновлений, ОПИСАНИЯ (там разработчики перечисляют кор-фичи),
        IAP, доход, саммари жалоб и саммари похвалы пользователей.

        Твоя задача — провести КОНКУРЕНТНЫЙ АНАЛИЗ, оценить актуальность ниши и предложить
        детальную продуктовую идею для нового приложения в этой нише.

        Формат ответа на русском языке, чётко по секциям:

        ## 1. Сводная картина рынка
        - Что это за ниша (1-2 предложения).
        - Главные тренды монетизации (какие чаще цены/типы подписок/виды IAP).
        - Сильные стороны категории в целом (что юзеры массово ценят).
        - Главные системные боли (что массово ломается у конкурентов).

        ## 2. Актуальность ниши и timing захода
        Опираясь на даты релиза и последних обновлений конкурентов:
        - Возраст ниши: новая / зрелая / устаревшая. Поясни на цифрах.
        - Активность игроков: обновляются ли конкуренты регулярно? Если последние обновления
          у большинства > 6 месяцев назад — рынок «уснул», можно заходить. Если все
          обновляются < 30 дней — конкуренция активная.
        - Окно возможностей: 1-2 предложения о том, реально ли сейчас зайти и сколько
          у тебя есть времени до того, как пространство «закроют».
        - Вердикт по timing-у: ⚡ ЗАХОДИТЬ СЕЙЧАС / 🟡 МОЖНО НО ОСТОРОЖНО / 🔴 РИСКОВАННО.

        ## 3. Кор-фичи конкурентов (из их описаний)
        Прочитай описания приложений и составь сводный реестр кор-фич, которые разработчики
        сами выделяют как ключевые. Группируй похожие фичи. Для каждой укажи:
        - Сама фича / способность продукта.
        - У скольких из проанализированных она есть (например, 3 из 5).
        - Является ли она «table stakes» (must have для входа) или дифференциатором.

        ## 4. Что стоит ВЗЯТЬ у конкурентов
        Объедини инсайты из ПЛЮСОВ отзывов + кор-фич из описаний. Маркированный список:
        фича/паттерн + у кого это сделано хорошо + почему юзеры это ценят.

        ## 5. Чего стоит ИЗБЕЖАТЬ
        Маркированный список из жалоб: проблема + у кого встречается + как этого избежать.

        ## 6. Идея нового приложения (детальный MVP)
        - Название (рабочий вариант).
        - Краткое позиционирование (1 предложение).
        - Уникальный value proposition: чем отличаемся от существующих, чтобы юзер выбрал нас.
        - MVP-фичи (8-12 пунктов, более детально): какие фичи копируем у победителей (укажи источник),
          какие добавляем как ответ на жалобы конкурентов, какие добавляем уникального.
        - Что осознанно НЕ делаем на старте (anti-features, чтобы не размывать MVP).
        - План версий: что в v1.0, что добавим в v1.1, v1.2.

        ## 7. Стратегия монетизации
        Опираясь на цены конкурентов:
        - Рекомендуемая модель (paid / freemium / hybrid).
        - Виды и цены подписок (weekly / monthly / yearly / lifetime) — конкретные цифры в USD.
          Поясни почему (медиана конкурентов, anchor pricing, ladder).
        - Trial / hard paywall / soft paywall — что лучше для этой ниши.
        - Целевой ARPU и LTV — конкретные цифры.

        Будь конкретен. Числа давай конкретные. Не пиши очевидных банальностей.
        Опирайся ТОЛЬКО на данные из инпута — не выдумывай факты про конкурентов.
        """

        let userPrompt = "Данные по конкурентам:\n\n\(corpus)"
        return try await chat(system: systemPrompt, user: userPrompt, temperature: 0.4, maxTokens: 6000)
    }

    // MARK: - Helpers
    private func reviewsToText(_ reviews: [AppReview], limit: Int) -> String {
        reviews.prefix(limit)
            .map { "[\($0.rating)★ v\($0.version)] \($0.title.isEmpty ? "" : $0.title + " — ")\($0.body)" }
            .joined(separator: "\n---\n")
    }

    private func chat(system: String, user: String, temperature: Double = 0.3, maxTokens: Int = 2000) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIError.missingKey }

        // Диагностика: показать маску ключа, чтобы было видно, какой именно был отправлен.
        let masked: String = {
            guard key.count > 12 else { return String(repeating: "•", count: key.count) }
            return "\(key.prefix(10))…\(key.suffix(4))  (len=\(key.count))"
        }()
        print("🔑 OpenAI key used: \(masked)")

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw OpenAIError.invalidPayload
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
