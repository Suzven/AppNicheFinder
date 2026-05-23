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
    func analyzeVisuals(payload: VisualAnalysisPayload) async throws -> String
}

// MARK: - Visual analysis input
struct VisualAnalysisPayload {
    struct AppVisual {
        let title: String
        let ratingsCount: Int
        let averageRating: Double
        let iconURL: URL?
        let screenshotURLs: [URL]   // первые 4
    }
    let apps: [AppVisual]
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

        ## 2. Актуальность ниши и timing захода (РАЗВЁРНУТЫЙ АНАЛИЗ)

        Дай системную оценку. ОБЯЗАТЕЛЬНО разбери КАЖДЫЙ из факторов ниже отдельно,
        с конкретными числами из инпута. Не пропускай ни одного.

        ### 2.1 Возраст конкурентов
        - Средний возраст конкурентов в годах (median).
        - Старейший и младший конкурент.
        - Распределение: сколько % младше 2 лет / 2-5 / старше 5.
        - Вывод: ниша молодая / средняя / зрелая / стагнирующая.

        ### 2.2 Активность обновлений (proxy жизни рынка)
        - Сколько конкурентов обновлялось за последние 30 / 90 / 180 / 365 дней.
        - Median и max «дней с последнего обновления» по выборке.
        - Вывод: насколько игроки выкладываются (ежемесячно / квартально / забили).

        ### 2.3 Концентрация рынка
        - Топ-1 и топ-3 по числу оценок — какой % от суммы оценок всей выборки.
        - Есть ли явный лидер с 10× больше оценок чем остальные (significant moat).
        - Распределение: есть ли «длинный хвост» мелких игроков или 2-3 гиганта монополизировали.

        ### 2.4 Скорость накопления оценок (если можно прикинуть)
        - Среднее число оценок на год существования у конкурентов.
        - Какой темп набора нужен новичку чтобы догнать median за 2 года.

        ### 2.5 Барьеры входа
        Конкретные пункты: что нужно сделать чтобы конкурировать. Технологические,
        UX-сложность, цена входа, накопленная экспертиза у лидеров.

        ### 2.6 Окно возможностей
        2-3 предложения: реально ли войти сейчас и сколько у тебя есть месяцев до того,
        как пространство схлопнется или появится крупный игрок.

        ### 2.7 ИТОГОВЫЙ ВЕРДИКТ
        Один из:
        - ⚡ ЗАХОДИТЬ СЕЙЧАС (с обоснованием в 2-3 предложения)
        - 🟢 МОЖНО, ЕСТЬ ОКНО (что именно за окно)
        - 🟡 МОЖНО НО ОСТОРОЖНО (что нужно сделать чтобы преуспеть)
        - 🔴 РИСКОВАННО (что именно проблематично)
        - ⛔ ПЛОХАЯ ИДЕЯ (объясни почему и предложи альтернативу)

        Заверши секцию **числовым score 0-100** с разбивкой по факторам
        (новизна / активность / концентрация / барьеры).

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

        Будь конкретен. Числа давай конкретные. Не пиши очевидных банальностей.
        Опирайся ТОЛЬКО на данные из инпута — не выдумывай факты про конкурентов.
        """

        let userPrompt = "Данные по конкурентам:\n\n\(corpus)"
        return try await chat(system: systemPrompt, user: userPrompt, temperature: 0.4, maxTokens: 6000)
    }

    // MARK: - ASO analysis
    func asoAnalysis(payload: ASOAnalysisPayload) async throws -> String {
        guard !payload.competitors.isEmpty else { throw OpenAIError.noReviews }

        // Сборка корпуса по конкурентам — ТОЛЬКО ASO-релевантные поля.
        // Description Apple НЕ индексирует для search ranking (в отличие от Google Play),
        // поэтому в инпут не включаем — экономим контекст и не запутываем модель.
        var corpus = ""
        for (i, c) in payload.competitors.enumerated() {
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
            Оценка: \(String(format: "%.2f", c.averageRating)) (\(c.ratingsCount) оценок) — это популярность.
            Примерные установки (review-rate ≈1%, ОЦЕНОЧНО): \(c.installsEstimate)

            Позиции по ключам:
            \(kwLines)

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
        ТВОЯ РОЛЬ: ты — senior ASO-engineer уровня Phiture / AppTweak / SplitMetrics с 10+ лет
        специализации именно на App Store ranking algorithm. Ты НЕ копирайтер и НЕ маркетолог.
        Твоя задача — оптимизация под RANKING и CTR, а не «написать красиво».

        Ты ОБЯЗАН думать как алгоритм Apple Search:
        - Считаешь токены, длины, частоту, signal weight.
        - Не используешь художественные обороты, метафоры, эмоциональные эпитеты в title/subtitle.
          Apple ранжирует по словам, а не по поэзии. Прилагательные вроде "amazing", "best",
          "ultimate" — ТОКЕНЫ-ПАРАЗИТЫ: занимают место, не дают ranking signal на конкурентных
          ключах. Запрещены если они не часть target-keyword.
        - Слова в title должны быть из реального поискового спроса (data-driven), а не из
          твоего воображения.

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        ВХОДНЫЕ ДАННЫЕ:
        - Резюме ниши (контекст для общего понимания продукта).
        - Конкуренты: title, subtitle, кол-во оценок (популярность), категория, позиции по
          списку ключей в App Store search US.
        - Нумерованный список ВСЕХ исследованных keywords (\(kwCount) шт.).

        ВАЖНО — описание App Store description Apple для search ranking ПРАКТИЧЕСКИ НЕ
        индексирует. В этой задаче description конкурентов НЕ передан и НЕ нужен. Не пиши
        выводы вида «у X ключ встречается N раз в описании» — у тебя нет описания. Работай
        только с title / subtitle / число оценок / позиция / категория.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        КАК APPLE РАНЖИРУЕТ APP STORE SEARCH (используй это в анализе):
        1. **Exact match в Title** (наивысший вес ×5). Полная фраза > слова вразброс.
        2. **Exact match в Subtitle** (×3).
        3. **Слова в скрытом поле Keywords** (×2).
        4. **Popularity** (кол-во оценок + средняя). Может перебить exact match.
        5. **Engagement** — свежие отзывы за ~90 дней.
        6. **Категория и поведенческие данные** (CTR, retention из аналитики Apple).
        7. **Update frequency** — недавнее обновление поднимает.
        8. **Семантическое расширение** — Apple склоняет, переводит между plural/singular,
           синонимит близкие слова (особенно в одной категории).
           ИМЕННО ЭТО объясняет «почему #N ранжируется без exact keyword» — Apple распознала
           родственный токен или категорийный сигнал.

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        СТРОГИЕ ПРАВИЛА:
        1. В §1 пройди ПО ВСЕМ \(kwCount) ключам — каждому отдельный подраздел. Не выбирай.
        2. Если у конкурента в title/subtitle НЕТ exact match — ОБЯЗАТЕЛЬНО разбери, ПОЧЕМУ
           он всё равно ранжируется (популярность? brand authority? категория? косвенные
           токены? semantic match со словом другой формы?). Это критически важно для понимания
           реальной механики Apple — не отделывайся фразой «непонятно».
        3. В §3 (готовые тексты) ЗАПРЕЩЕНО использовать ключи которых нет в §2.2-2.4.
           Если хочется использовать новый — добавь его в §2 с обоснованием.
        4. ЗАПРЕЩЕНО в title/subtitle:
           - Эмоциональные прилагательные ("Best", "Amazing", "Smart" без обоснования).
           - Generic слова ("App", "Pro" если не часть бренда, "AI" если не закрывает спрос).
           - Слова-паразиты без ranking ценности.
        5. Каждый предложенный title/subtitle в §3 ОБЯЗАН содержать минимум 2 exact-match
           слова из target-keyword. Если меньше — это не ASO, это копирайт. Переделай.
        6. В §3.3 (Keywords field) НЕ повторяй слова из выбранного title/subtitle.
        7. Все рекомендации должны быть data-driven: ссылайся на конкретного конкурента
           («у #1 по "X" работает паттерн Y, копируем»).
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        Структура ответа на русском, чётко по секциям:

        ## 1. Per-keyword разбор ранжирования

        Для КАЖДОГО ключа из нумерованного списка (всего \(kwCount)):

        ### Ключ N: «keyword»
        - Top-5 конкурентов по этому ключу с позициями.
        - Для каждого подряд:
          - Title и Subtitle (точно процитируй строки).
          - Где совпадает keyword: в title? subtitle? нигде?
          - Тип совпадения: **exact phrase** / **bag-of-words** (слова есть но не подряд) /
            **partial token** (одно слово из фразы) / **semantic** (родственное слово) /
            **none** (нет ни одного слова).
          - Если совпадения НЕТ — обязательно разбери ПОЧЕМУ ранжируется:
            * popularity (X оценок vs median по выборке Y)
            * brand authority (зрелое имя в категории)
            * category match (Apple дописывает category-fit к выдаче)
            * semantic synonym (укажи какое именно слово в title/subtitle Apple
              сопоставляет с этим keyword)
            * cross-keyword cannibalization (популярность по соседнему ключу подтягивает)
          - Кол-во оценок (popularity signal).
          - **ВЫВОД 2-3 предложениями**: почему именно эта позиция у этого конкурента.
            Например: «#2 несмотря на отсутствие exact match — у них brand authority (180k
            оценок vs median 12k) + слово 'identifier' в title — Apple семантически связывает
            "identifier" с "plant identifier" в этой категории».

        ## 2. Карта возможностей

        ### 2.1 Tier S — недостижимые
        Ключи, где топ-3 держат позицию через сочетание exact match + 100k+ оценок.
        Объясни кого и почему не сдвинуть.

        ### 2.2 Tier A — exact-keyword войны
        Ключи где топ слабые или не используют exact match в title. Можно отвоевать
        грамотным title/subtitle.

        ### 2.3 Tier B — long-tail (3+ слова)
        Низкая конкуренция, легко занять с нуля.

        ### 2.4 Дыры
        Ключи где НИКТО из проанализированных не таргетит.

        ## 3. ASO-тексты (English, App Store US) — STRICT

        Каждый вариант ОБЯЗАН содержать:
        - exact-match слова из конкретных ключей §2.2-2.4 (явно перечисли какие).
        - Никаких "Best", "Amazing", "Smart", "Ultimate" если они не часть target-keyword.

        ### 3.1 Title (max 30 символов)
        3 варианта. Формат предпочтителен: `{Primary keyword} {Secondary keyword OR brand}`.
        Под каждым:
        - Символов: NN / 30
        - Exact match закрывает: «keyword 1», «keyword 2»
        - Ranking-логика: почему этот порядок слов сильный (расположение primary в начале).

        ### 3.2 Subtitle (max 30 символов)
        3 варианта. Закрывает ключи которые НЕ влезли в title.
        Под каждым тот же формат.
        ЗАПРЕТ: дублировать слова из выбранного title (потеря места).

        ### 3.3 Keywords field (max 100 символов, comma-separated БЕЗ ПРОБЕЛОВ)
        - Только слова, которых нет в title и subtitle.
        - Plural/singular, синонимы, long-tail из §2.3-2.4.
        - Финальная длина (NN/100) и какие ключи покрывает.

        ### 3.4 Promotional Text (max 170 символов)
        Это поле НЕ ранжируется, но влияет на CTR.
        - Главный USP + call-to-action.
        - Можно использовать эмоциональные слова (тут CTR > ranking).

        ### 3.5 Description (~1500-2500 символов)
        Description не ранжируется, но влияет на конверсию из views в installs.
        Структура:
        - **Hook (3 строки, видно без раскрытия)** — главное value-prop.
        - **Key features** — 5-7 буллетов.
        - **How it works** — 3 шага.
        - **Why us vs alternatives**.
        - **Subscription terms** — стандартный disclaimer Apple.

        ## 4. Review templates для ASO

        Apple учитывает текст отзывов за ~90 дней. 5 шаблонов отзывов (English, US):
        - Разные persona (newcomer, expert, parent, traveler, student).
        - В каждом 2-3 keyword из §2 органично вшиты.
        - Естественный английский — никаких "Best app ever!".
        - Разные тоны: восторг / use-case / удивление / problem→solution / comparison.

        Под каждым: какие keywords закрыты + почему звучит реалистично.

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Не лей воду. Не пиши банальностей. Цифры, цитаты, конкретика.
        Если резюме ниши пусто — отметь и работай без него.
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

        return try await chat(system: systemPrompt, user: userPrompt, temperature: 0.2, maxTokens: 12000)
    }

    // MARK: - Visual analysis (GPT-4o Vision API)
    func analyzeVisuals(payload: VisualAnalysisPayload) async throws -> String {
        guard !payload.apps.isEmpty else { throw OpenAIError.noReviews }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIError.missingKey }

        let systemPrompt = """
        Ты — senior ASO-эксперт и UX/visual-дизайнер с экспертизой по App Store творчеству.
        Тебе показывают иконку и первые 4 скриншота нескольких приложений из одной ниши.
        К каждому приложению приложено название и кол-во оценок (proxy популярности).

        Проанализируй ВИЗУАЛЬНУЮ КОНКУРЕНЦИЮ детально:

        ## 1. Иконки конкурентов
        - У каждого опиши: основной цвет, центральный объект/символ, стиль (flat / gradient / 3D / illustration / photo).
        - Найди ОБЩИЕ паттерны (что повторяется у топовых = индустриальный стандарт ниши).
        - Найди отличающихся (кто решил выделиться) — работает ли это для них (по числу оценок).
        - Какую иконку рекомендовать новому приложению (конкретно: цвет, символ, стиль).

        ## 2. Скриншоты — паттерны успешных
        Для каждого приложения:
        - Первый скриншот: hero / feature-showcase / paywall? Заголовок?
        - 2-4 скриншоты: что показывают, в каком порядке.
        - Текст: размер, цвет, шрифт (sans-serif bold? handwritten?), сколько слов.
        - Фон: solid color / gradient / photo / blurred screenshot.
        - Композиция: device mockup / full screen / split-screen.

        ## 3. Сводные паттерны лидеров
        Отсортируй приложения от наибольшего числа оценок к наименьшему. У топ-2 найди:
        - Общую цветовую гамму (например, «зелёный + белый + акценты оранжевым»).
        - Шрифты и размер текста на 1-м скрине.
        - Тематические сцены (что они показывают — процесс использования? результат? before/after?).
        - Что они НЕ делают (например, не показывают paywall в первых 4).

        ## 4. Конкретные рекомендации для нового приложения
        - Цветовая палитра (3 hex-кода).
        - Стиль 1-го скриншота: что должно быть на нём для максимальной конверсии.
        - Структура 4 скриншотов: что показать и в каком порядке.
        - Текст на скриншотах: тон, длина, главные слова (опираясь на keywords ниши).
        - Чем отличиться от конкурентов, не теряя «узнаваемость ниши».

        Будь конкретен, описывай детали визуально (цвета, расположение, текстура). На русском.
        """

        // Сборка multi-modal сообщения: текстовая преамбула + изображения
        var contentBlocks: [[String: Any]] = []
        var preamble = "Анализируй \(payload.apps.count) конкурентов в одной нише.\n\n"
        for (i, app) in payload.apps.enumerated() {
            preamble += "ПРИЛОЖЕНИЕ #\(i + 1): \(app.title)\n"
            preamble += "Оценка: \(String(format: "%.2f", app.averageRating)) (\(app.ratingsCount) оценок)\n\n"
        }
        contentBlocks.append(["type": "text", "text": preamble])

        for (i, app) in payload.apps.enumerated() {
            contentBlocks.append(["type": "text", "text": "--- ПРИЛОЖЕНИЕ #\(i + 1): \(app.title) ---"])
            if let icon = app.iconURL {
                contentBlocks.append([
                    "type": "text", "text": "Иконка:"
                ])
                contentBlocks.append([
                    "type": "image_url",
                    "image_url": ["url": icon.absoluteString, "detail": "low"]
                ])
            }
            if !app.screenshotURLs.isEmpty {
                contentBlocks.append(["type": "text", "text": "Скриншоты (первые \(app.screenshotURLs.count)):"])
                for url in app.screenshotURLs {
                    contentBlocks.append([
                        "type": "image_url",
                        "image_url": ["url": url.absoluteString, "detail": "low"]
                    ])
                }
            }
        }

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0.4,
            "max_tokens": 4000,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": contentBlocks]
            ]
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: body) else {
            throw OpenAIError.invalidPayload
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = payloadData

        NetworkLogger.logRequest(request)
        let (data, response) = try await URLSession.shared.data(for: request)
        NetworkLogger.logResponse(response, data: data, requestURL: request.url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.badStatusCode(http.statusCode, raw)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw OpenAIError.emptyResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
