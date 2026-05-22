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
    func asoAnalysis(payload: ASOAnalysisPayload) async throws -> String
}

// MARK: - ASO analysis input
struct ASOAnalysisPayload {
    /// Один конкурент с данными для ASO-анализа.
    struct CompetitorEntry {
        let title: String
        let subtitle: String
        let description: String
        let genre: String
        let installsEstimate: Int    // примерные установки (review-rate)
        let ratingsCount: Int
        let averageRating: Double
        /// keyword → position
        let keywordPositions: [String: Int]
    }
    /// Резюме ниши (вывод предыдущего metaAnalysis).
    let nicheSummary: String
    let competitors: [CompetitorEntry]
    /// Список keywords которые мы исследовали (объединение discovery + keyword check).
    let allKeywords: [String]
}

// MARK: - Meta-analysis input
struct MetaAnalysisPayload {
    struct KeywordEntry {
        let keyword: String
        /// trackId → позиция в выдаче
        let positions: [Int: Int]
        /// топ-10 апков на ключе (title, sellerName)
        let topTitles: [String]
    }
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
    let keywords: [KeywordEntry]
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

        ## 7. ASO и позиционирование по ключам
        Если в инпуте есть блок KEYWORD-АНАЛИЗ:
        - Перечисли по каким ключам конкуренты сильны (топ-1..10).
        - Где есть «дыры» — keywords, по которым ни один из анализируемых не в топ-10
          (можно атаковать).
        - Какие ключи стоит таргетить в названии / subtitle / keywords-поле нового приложения.
        - Если KEYWORD-АНАЛИЗ пуст — пропусти эту секцию.

        ## 8. Стратегия монетизации
        Опираясь на цены конкурентов:
        - Рекомендуемая модель (paid / freemium / hybrid).
        - Виды и цены подписок (weekly / monthly / yearly / lifetime) — конкретные цифры в USD.
          Поясни почему (медиана конкурентов, anchor pricing, ladder).
        - Trial / hard paywall / soft paywall — что лучше для этой ниши.
        - Целевой ARPU и LTV — конкретные цифры.

        Будь конкретен. Числа давай конкретные. Не пиши очевидных банальностей.
        Опирайся ТОЛЬКО на данные из инпута — не выдумывай факты про конкурентов.
        """

        // Keyword block
        var kwBlock = ""
        if !payload.keywords.isEmpty {
            // titleByTrackId: ID → название (для красивого вывода позиций)
            var titleByID: [Int: String] = [:]
            for (i, app) in payload.apps.enumerated() {
                _ = i
                if let trackId = Int(app.title) { _ = trackId }
                // нам ID не пробрасывается из AppEntry — используем по имени
            }
            kwBlock += "\n=====================================\nKEYWORD-АНАЛИЗ (позиции в App Store search):\n"
            for kw in payload.keywords {
                kwBlock += "\n• «\(kw.keyword)»\n"
                if kw.positions.isEmpty {
                    kwBlock += "    Анализируемые приложения: не в топ-200\n"
                } else {
                    for (id, pos) in kw.positions.sorted(by: { $0.value < $1.value }) {
                        kwBlock += "    appID=\(id) → позиция \(pos)\n"
                    }
                }
                if !kw.topTitles.isEmpty {
                    kwBlock += "    ТОП-10 по ключу: \(kw.topTitles.joined(separator: ", "))\n"
                }
            }
        }

        let userPrompt = "Данные по конкурентам:\n\n\(corpus)\(kwBlock)"
        return try await chat(system: systemPrompt, user: userPrompt, temperature: 0.4, maxTokens: 6000)
    }

    // MARK: - ASO analysis
    func asoAnalysis(payload: ASOAnalysisPayload) async throws -> String {
        guard !payload.competitors.isEmpty else { throw OpenAIError.noReviews }

        // Сборка корпуса по конкурентам
        var corpus = ""
        for (i, c) in payload.competitors.enumerated() {
            let truncatedDesc = c.description.count > 2000
                ? String(c.description.prefix(2000)) + "…[обрезано]"
                : c.description

            let kwLines: String = c.keywordPositions.isEmpty
                ? "    (не нашлось в top-200 по нашим ключам)"
                : c.keywordPositions
                    .sorted(by: { $0.value < $1.value })
                    .map { "    «\($0.key)» → позиция #\($0.value)" }
                    .joined(separator: "\n")

            corpus += """
            =====================================
            КОНКУРЕНТ #\(i + 1)
            Title:    \(c.title)
            Subtitle: \(c.subtitle.isEmpty ? "—" : c.subtitle)
            Категория: \(c.genre)
            Оценка: \(String(format: "%.2f", c.averageRating)) (\(c.ratingsCount) оценок)
            Примерные установки (review-rate ≈1%, ОЦЕНОЧНО): \(c.installsEstimate)

            Позиции по ключам:
            \(kwLines)

            ПОЛНОЕ ОПИСАНИЕ ИЗ APP STORE (анализируй ВНИМАТЕЛЬНО на наличие ключей):
            \(truncatedDesc)

            """
        }

        // Нумерованный список ключей — для строгого прохода по всем в промпте
        let kwList: String = {
            if payload.allKeywords.isEmpty { return "(не задано)" }
            return payload.allKeywords.enumerated()
                .map { "\($0.offset + 1). «\($0.element)»" }
                .joined(separator: "\n")
        }()
        let kwCount = payload.allKeywords.count

        let systemPrompt = """
        Ты — senior ASO-эксперт (App Store Optimization) с экспертизой по App Store search ranking,
        конверсии лендинга и стратегиям отзывов. Тебе дают:
        - Резюме ниши (вывод предыдущего конкурентного анализа, включая идею MVP).
        - Данные по топовым конкурентам: title, subtitle, ПОЛНОЕ ОПИСАНИЕ (читай его внимательно
          и реально ищи в нём ключи), категория, оценки, ПРИМЕРНЫЕ установки, позиции в App Store
          search по списку ключей.
        - Список keywords (нумерованный) — это ВСЕ ключи которые мы изучали по нише.

        КАК APPLE РАНЖИРУЕТ APP STORE SEARCH (используй это в анализе):
        1. Самый большой вес — точное совпадение слов в Title (вес × 5).
        2. Средний вес — слова в Subtitle (вес × 3).
        3. Чуть меньше — слова в поле Keywords (max 100 символов, скрытое поле).
        4. Маленький, но НЕ нулевой вес — слова в Description (~ × 0.5, нужно несколько повторений).
        5. Popularity signal — кол-во оценок и средняя оценка (downloads × ratings).
        6. Engagement signal — текст отзывов за последние ~90 дней.
        7. Update frequency — недавнее обновление поднимает приложение.

        ВАЖНО про установки: число установок — ОЦЕНОЧНОЕ, не реальное. Говори «оценочно ~10M»,
        а не «у них 10M пользователей».

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        ОБЯЗАТЕЛЬНЫЕ ПРАВИЛА:
        - В §1 пройди ПО ВСЕМ \(kwCount) ключам из списка (НЕ выбирай «главные 5-10», а пройди КАЖДЫЙ).
          Если по ключу нет данных — так и напиши.
        - Для каждого ключа разбирай ВСЕХ конкурентов которые в нём ранжируются (top-10).
          Не давай поверхностных формулировок «у них ключ в title». Детально:
          где именно (title / subtitle / в самом description со ссылкой на абзац),
          какие соседние слова (это влияет на «фразовое совпадение»),
          сколько раз встречается в description (frequency матерится для Apple).
        - Анализ должен явно объяснить «почему #1 а не #2 у этих двух конкурентов»:
          один в title vs subtitle? один с 100k оценок vs 10k? оба в title но первый старше?
        - §3 (готовые тексты) ДОЛЖЕН использовать ключи из §2 «достижимые» (явно ссылайся
          какие из §2 закрыты в этом title/subtitle/keywords). Если в §3 предложил ключ
          которого нет в §2 — это ошибка, добавь его в §2 с обоснованием.
        - В §3.3 (Keywords field) НЕ повторяй слова которые уже в title и subtitle —
          Apple дублирование игнорирует.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        Структура ответа на русском языке, чётко по секциям:

        ## 1. Глубокий разбор: почему конкуренты на своих позициях по каждому ключу

        Для КАЖДОГО ключа из нумерованного списка (всего \(kwCount) штук):

        ### Ключ N: «keyword»
        - Top-3 конкурента по этому ключу (с указанием позиции).
        - Для каждого из них таблично:
          • Где ключ используется:
              — в title? Покажи строку title и слово/фразу-совпадение.
              — в subtitle? Покажи строку subtitle и совпадение.
              — в description? Сколько раз упоминается, в каком контексте (intro / features / footer).
          • Какие popularity-signals: кол-во оценок / средняя оценка.
          • ВЫВОД 1-2 предложениями: почему именно эта позиция у этого конкурента
            (например: «#1 потому что full match в title + 87k оценок vs у #2 ключ только в subtitle и 12k оценок»).
        - Если по ключу нет данных или конкурентов мало — отметь это явно.

        ## 2. Стратегические выводы и достижимые ключи

        ### 2.1 Полностью НЕДОСТИЖИМЫЕ ключи (Tier S — потеряем без 100k+ оценок)
        Перечень с пояснением: какой конкурент держит позицию и почему его не подвинуть.

        ### 2.2 Средне-достижимые ключи (Tier A — реально с грамотным title/subtitle)
        Где конкуренты слабы или не используют keyword в title.

        ### 2.3 Лёгкие ключи (Tier B — long-tail, можем взять с нуля)
        3-словные фразы, синонимы, варианты с brand-words.

        ### 2.4 ДЫРЫ — ключи на которые никто не таргетируется
        Бесплатное золото.

        ## 3. ГОТОВЫЕ ТЕКСТЫ для App Store Connect (на английском, App Store US)

        Каждый вариант ДОЛЖЕН явно ссылаться на ключи из §2.2-2.4 (например: «закрывает Tier-A
        ключ "plant identifier" + Tier-B "ai garden helper"»).

        ### 3.1 Title (max 30 символов)
        Дай 3 варианта. Формат `Главный keyword — Бренд`.
        Под каждым:
        - Символов: NN / 30
        - Закрывает ключи: [список из §2]
        - Почему этот вариант сильный.

        ### 3.2 Subtitle (max 30 символов)
        Дай 3 варианта. Содержит ключи, которые НЕ влезли в title.
        Под каждым:
        - Символов: NN / 30
        - Закрывает ключи: [из §2]
        - Объяснение.

        ### 3.3 Keywords field (max 100 символов, через запятую БЕЗ ПРОБЕЛОВ)
        - Не повторяй слова из выбранного выше title и subtitle.
        - Используй plural/singular, синонимы, long-tail.
        - Формат: `word1,word2,phrase3,word4` без пробелов.
        - Укажи финальную длину строки и какие ключи покрывает.

        ### 3.4 Promotional Text (max 170 символов)
        Главный USP + call-to-action. Без keyword-stuffing.

        ### 3.5 Description (~1500-2500 символов)
        Структура:
        - **Hook (3 строки)** — самое мощное, видно без раскрытия.
        - **Why us** — главный value prop.
        - **Key features** — 5-7 буллетов, в каждом органично вшит ключ (укажи какой).
        - **How it works** — 3 шага.
        - **Why it's different from X** — упомяни 1-2 категорий конкурентов и наш differentiator.
        - **Subscription terms** — стандартный disclaimer Apple.

        Описание должно использовать каждый из ключей §2.2-2.4 минимум 1-2 раза (Apple учитывает
        частоту в description).

        ## 4. Стратегия отзывов под ASO

        Подготовь 5 шаблонов отзывов (англ., App Store US):
        - Разные persona (новичок, эксперт, родитель, путешественник, студент и т.д.).
        - В каждом органично 2-3 ключа из §2.
        - Натуральный английский — без шаблонных оборотов вроде "Best app ever!".
        - Тон каждого отличается (восторг / описание use-case / удивление / поломка→решение / сравнение).

        Под каждым отзывом: какие ключи закрыты + почему этот отзыв реалистичен.

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Не лей воду. Не пиши банальностей. Конкретика, цифры, ссылки на конкретные тексты.
        Если в инпуте «резюме ниши» пусто — отметь это и работай без него.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """

        let userPrompt = """
        РЕЗЮМЕ НИШИ (из предыдущего анализа):
        \(payload.nicheSummary.isEmpty ? "(не сформировано — действуй универсально)" : payload.nicheSummary)

        ИССЛЕДОВАННЫЕ KEYWORDS (всего \(kwCount), пройди по КАЖДОМУ в §1):
        \(kwList)

        ДАННЫЕ КОНКУРЕНТОВ (анализируй их описания внимательно):
        \(corpus)
        """

        return try await chat(system: systemPrompt, user: userPrompt, temperature: 0.4, maxTokens: 12000)
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
