//
//  AppLookupService.swift
//  AppNicheFinder
//

import Foundation

// MARK: - Errors
enum AppLookupError: LocalizedError {
    case invalidAppID
    case badStatusCode(Int)
    case appNotFound
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidAppID:    return "Некорректный Apple ID приложения."
        case .badStatusCode(let code): return "Сервер вернул код \(code)."
        case .appNotFound:     return "Приложение с таким ID не найдено в App Store."
        case .decodingFailed:  return "Не удалось разобрать ответ сервера."
        }
    }
}

// MARK: - Protocol (SOLID — service is injected by protocol)
protocol AppLookupServicing {
    func fetchInfo(appID: String, country: String) async throws -> AppInfo
    func fetchBadReviews(appID: String, country: String, maxRating: Int, pages: Int) async throws -> [AppReview]
}

// MARK: - Service (actor — thread-safe networking)
actor AppLookupService: AppLookupServicing {

    // MARK: - Public API
    func fetchInfo(appID: String, country: String = "us") async throws -> AppInfo {
        let cleanID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, Int(cleanID) != nil else {
            throw AppLookupError.invalidAppID
        }

        async let lookup = fetchLookup(appID: cleanID, country: country)
        async let subtitle = fetchSubtitle(appID: cleanID, country: country)

        let result = try await lookup
        let parsedSubtitle = (try? await subtitle) ?? ""

        return makeAppInfo(from: result, subtitle: parsedSubtitle, country: country)
    }

    // MARK: - Bad reviews (RSS feed, up to 10 pages, ~500 reviews max)
    func fetchBadReviews(appID: String, country: String = "us", maxRating: Int = 2, pages: Int = 10) async throws -> [AppReview] {
        let cleanID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, Int(cleanID) != nil else {
            throw AppLookupError.invalidAppID
        }
        let pageRange = 1...min(max(pages, 1), 10)
        let country = country.isEmpty ? "us" : country.lowercased()

        var collected: [AppReview] = []
        var seenIDs = Set<String>()

        try await withThrowingTaskGroup(of: [AppReview].self) { group in
            for page in pageRange {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.fetchReviewsPage(appID: cleanID, country: country, page: page)
                }
            }
            for try await pageReviews in group {
                for review in pageReviews where !seenIDs.contains(review.id) {
                    seenIDs.insert(review.id)
                    collected.append(review)
                }
            }
        }

        let bad = collected.filter { $0.rating <= maxRating }
        return bad.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    private func fetchReviewsPage(appID: String, country: String, page: Int) async -> [AppReview] {
        let urlString = "https://itunes.apple.com/\(country)/rss/customerreviews/page=\(page)/id=\(appID)/sortby=mostrecent/json"
        guard let url = URL(string: urlString) else { return [] }
        let request = URLRequest(url: url)

        NetworkLogger.logRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NetworkLogger.logResponse(nil, data: nil, error: error, requestURL: request.url)
            return []
        }
        NetworkLogger.logResponse(response, data: data, requestURL: request.url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return []
        }

        guard let rss = try? JSONDecoder().decode(ReviewsRSSResponse.self, from: data) else {
            return []
        }
        let entries = rss.feed.entry ?? []
        return entries.map { entry in
            AppReview(
                id: entry.id.label,
                title: entry.title.label,
                body: entry.content.label,
                rating: Int(entry.rating.label) ?? 0,
                author: entry.author.name.label,
                version: entry.version?.label ?? "",
                updated: Self.parseISO(entry.updated?.label)
            )
        }
    }

    // MARK: - iTunes Lookup
    private func fetchLookup(appID: String, country: String) async throws -> AppLookupResult {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: appID),
            URLQueryItem(name: "country", value: country)
        ]
        let request = URLRequest(url: components.url!)

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
            throw AppLookupError.badStatusCode(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(AppLookupResponse.self, from: data)
            guard let first = decoded.results.first else {
                throw AppLookupError.appNotFound
            }
            return first
        } catch is DecodingError {
            throw AppLookupError.decodingFailed
        }
    }

    // MARK: - Subtitle parsing (not exposed via Lookup API)
    private func fetchSubtitle(appID: String, country: String) async throws -> String {
        guard let url = URL(string: "https://apps.apple.com/\(country)/app/id\(appID)") else { return "" }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

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

        guard let html = String(data: data, encoding: .utf8) else { return "" }

        // 1) Try og:title-style header: <h2 class="product-header__subtitle ...">SUBTITLE</h2>
        if let s = firstMatch(in: html,
                              pattern: #"<h2[^>]*class="[^"]*product-header__subtitle[^"]*"[^>]*>([^<]+)</h2>"#) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2) Fallback: schema.org JSON-LD "description" sometimes carries the marketing subtitle
        if let s = firstMatch(in: html, pattern: #""applicationSubtitle"\s*:\s*"([^"]+)""#) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    // MARK: - Mapping
    private func makeAppInfo(from r: AppLookupResult, subtitle: String, country: String) -> AppInfo {
        AppInfo(
            id: r.trackId,
            title: r.trackName,
            subtitle: subtitle,
            description: r.description,
            ratingsCountTotal: r.userRatingCount ?? 0,
            averageRating: r.averageUserRating ?? 0,
            countryCode: country.uppercased(),
            firstReleaseDate: Self.parseISO(r.releaseDate),
            lastUpdateDate: Self.parseISO(r.currentVersionReleaseDate),
            iconURL: URL(string: r.artworkUrl512 ?? r.artworkUrl100 ?? ""),
            storeURL: URL(string: r.trackViewUrl ?? ""),
            sellerName: r.sellerName ?? "",
            primaryGenre: r.primaryGenreName ?? "",
            version: r.version ?? ""
        )
    }

    // MARK: - Helpers
    private nonisolated func firstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[r])
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

