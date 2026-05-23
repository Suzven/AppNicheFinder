//
//  AnalysisSession.swift
//  AppNicheFinder
//
//  Persistable snapshot всего состояния анализа: настройки ввода + entries +
//  результаты GPT (meta, ASO) + discovery / keyword check. Хранится JSON в
//  Documents/sessions/{id}.json.
//

import Foundation

// MARK: - Top-level session record
struct AnalysisSession: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var country: String
    var mode: String                 // raw value of AppInfoViewModel.AnalysisMode
    var appIDsInput: String
    var discoveryKeywordsInput: String
    var keywordsInput: String

    var entries: [AppEntryDTO]
    var discoveredApps: [DiscoveredAppDTO]
    var keywordResults: [KeywordResultDTO]

    var metaSummary: String
    var asoSummary: String
    var visualsSummary: String?

    /// Краткое summary для списка сессий: первые 3 названия приложений.
    var subtitle: String {
        let titles = entries.compactMap { $0.info?.title }
        if titles.isEmpty { return "—" }
        let head = titles.prefix(3).joined(separator: ", ")
        return entries.count > 3 ? "\(head) (+\(entries.count - 3))" : head
    }
}

// MARK: - Entry DTO
struct AppEntryDTO: Codable, Hashable {
    let appID: String
    let country: String
    var info: AppInfoDTO?
    var badReviews: [AppReviewDTO]
    var goodReviews: [AppReviewDTO]
    var complaintsSummary: String
    var praiseSummary: String
}

struct AppInfoDTO: Codable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let description: String
    let ratingsCountTotal: Int
    let averageRating: Double
    let countryCode: String
    let firstReleaseDate: Date?
    let lastUpdateDate: Date?
    let iconURL: URL?
    let storeURL: URL?
    let sellerName: String
    let primaryGenre: String
    let version: String
    let price: Double
    let formattedPrice: String
    let currency: String
    let iaps: [AppIAPDTO]
    let screenshotURLs: [URL]
}

struct AppIAPDTO: Codable, Hashable {
    let id: String
    let name: String
    let priceFormatted: String
    let price: Double
    let isSubscription: Bool
}

struct AppReviewDTO: Codable, Hashable {
    let id: String
    let title: String
    let body: String
    let rating: Int
    let author: String
    let version: String
    let updated: Date?
}

struct DiscoveredAppDTO: Codable, Hashable {
    let id: Int
    let title: String
    let sellerName: String
    let iconURL: URL?
    let averageRating: Double
    let ratingCount: Int
    let bundleId: String
    let positions: [String: Int]
}

struct KeywordResultDTO: Codable, Hashable {
    let keyword: String
    let topResults: [KeywordSearchHitDTO]
    let positions: [Int: Int]
}

struct KeywordSearchHitDTO: Codable, Hashable {
    let id: Int
    let position: Int
    let title: String
    let sellerName: String
    let iconURL: URL?
    let averageRating: Double
    let ratingCount: Int
    let bundleId: String
}

// MARK: - DTO ↔ live model mappings
extension AppIAP {
    init(_ dto: AppIAPDTO) {
        self.init(id: dto.id, name: dto.name, priceFormatted: dto.priceFormatted,
                  price: dto.price, isSubscription: dto.isSubscription)
    }
    func toDTO() -> AppIAPDTO {
        AppIAPDTO(id: id, name: name, priceFormatted: priceFormatted,
                  price: price, isSubscription: isSubscription)
    }
}

extension AppReview {
    init(_ dto: AppReviewDTO) {
        self.init(id: dto.id, title: dto.title, body: dto.body, rating: dto.rating,
                  author: dto.author, version: dto.version, updated: dto.updated)
    }
    func toDTO() -> AppReviewDTO {
        AppReviewDTO(id: id, title: title, body: body, rating: rating,
                     author: author, version: version, updated: updated)
    }
}

extension AppInfo {
    init(_ dto: AppInfoDTO) {
        self.init(
            id: dto.id, title: dto.title, subtitle: dto.subtitle,
            description: dto.description,
            ratingsCountTotal: dto.ratingsCountTotal,
            averageRating: dto.averageRating,
            countryCode: dto.countryCode,
            firstReleaseDate: dto.firstReleaseDate,
            lastUpdateDate: dto.lastUpdateDate,
            iconURL: dto.iconURL,
            storeURL: dto.storeURL,
            sellerName: dto.sellerName,
            primaryGenre: dto.primaryGenre,
            version: dto.version,
            price: dto.price,
            formattedPrice: dto.formattedPrice,
            currency: dto.currency,
            iaps: dto.iaps.map(AppIAP.init),
            screenshotURLs: dto.screenshotURLs
        )
    }
    func toDTO() -> AppInfoDTO {
        AppInfoDTO(
            id: id, title: title, subtitle: subtitle, description: description,
            ratingsCountTotal: ratingsCountTotal, averageRating: averageRating,
            countryCode: countryCode, firstReleaseDate: firstReleaseDate,
            lastUpdateDate: lastUpdateDate, iconURL: iconURL, storeURL: storeURL,
            sellerName: sellerName, primaryGenre: primaryGenre, version: version,
            price: price, formattedPrice: formattedPrice, currency: currency,
            iaps: iaps.map { $0.toDTO() },
            screenshotURLs: screenshotURLs
        )
    }
}

extension DiscoveredApp {
    init(_ dto: DiscoveredAppDTO) {
        self.init(
            id: dto.id, title: dto.title, sellerName: dto.sellerName,
            iconURL: dto.iconURL, averageRating: dto.averageRating,
            ratingCount: dto.ratingCount, bundleId: dto.bundleId, positions: dto.positions
        )
    }
    func toDTO() -> DiscoveredAppDTO {
        DiscoveredAppDTO(
            id: id, title: title, sellerName: sellerName, iconURL: iconURL,
            averageRating: averageRating, ratingCount: ratingCount,
            bundleId: bundleId, positions: positions
        )
    }
}

extension KeywordSearchHit {
    init(_ dto: KeywordSearchHitDTO) {
        self.init(id: dto.id, position: dto.position, title: dto.title,
                  sellerName: dto.sellerName, iconURL: dto.iconURL,
                  averageRating: dto.averageRating, ratingCount: dto.ratingCount,
                  bundleId: dto.bundleId)
    }
    func toDTO() -> KeywordSearchHitDTO {
        KeywordSearchHitDTO(id: id, position: position, title: title,
                            sellerName: sellerName, iconURL: iconURL,
                            averageRating: averageRating, ratingCount: ratingCount,
                            bundleId: bundleId)
    }
}

extension KeywordResult {
    init(_ dto: KeywordResultDTO) {
        self.init(keyword: dto.keyword,
                  topResults: dto.topResults.map(KeywordSearchHit.init),
                  positions: dto.positions)
    }
    func toDTO() -> KeywordResultDTO {
        KeywordResultDTO(keyword: keyword,
                         topResults: topResults.map { $0.toDTO() },
                         positions: positions)
    }
}

// MARK: - AppEntry mapping (live class ↔ DTO)
extension AppEntry {
    func toDTO() -> AppEntryDTO {
        AppEntryDTO(
            appID: appID,
            country: country,
            info: info?.toDTO(),
            badReviews: badReviews.map { $0.toDTO() },
            goodReviews: goodReviews.map { $0.toDTO() },
            complaintsSummary: complaintsSummary,
            praiseSummary: praiseSummary
        )
    }

    /// Восстановление entry из DTO (для загрузки сохранённой сессии).
    /// Статус всегда .done — мы загружаем уже завершённый анализ.
    static func fromDTO(_ dto: AppEntryDTO) -> AppEntry {
        let entry = AppEntry(appID: dto.appID, country: dto.country)
        entry.info = dto.info.map(AppInfo.init)
        entry.badReviews = dto.badReviews.map(AppReview.init)
        entry.goodReviews = dto.goodReviews.map(AppReview.init)
        entry.complaintsSummary = dto.complaintsSummary
        entry.praiseSummary = dto.praiseSummary
        entry.status = .done
        return entry
    }
}
