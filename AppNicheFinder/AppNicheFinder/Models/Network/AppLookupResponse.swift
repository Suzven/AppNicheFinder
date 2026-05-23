//
//  AppLookupResponse.swift
//  AppNicheFinder
//

import Foundation

// MARK: - iTunes Lookup API top-level response
struct AppLookupResponse: Decodable {
    let resultCount: Int
    let results: [AppLookupResult]
}

// MARK: - Single app result from iTunes Lookup
struct AppLookupResult: Decodable {
    let trackId: Int
    let trackName: String
    let description: String
    let averageUserRating: Double?
    let userRatingCount: Int?
    let releaseDate: String?
    let currentVersionReleaseDate: String?
    let sellerName: String?
    let bundleId: String?
    let version: String?
    let primaryGenreName: String?
    let artworkUrl512: String?
    let artworkUrl100: String?
    let trackViewUrl: String?
    let price: Double?
    let formattedPrice: String?
    let currency: String?
    let screenshotUrls: [String]?
    let ipadScreenshotUrls: [String]?
}

// MARK: - In-App Purchase model (parsed from apps.apple.com)
struct AppIAP: Identifiable, Hashable {
    let id: String
    let name: String
    let priceFormatted: String
    let price: Double
    let isSubscription: Bool

    /// Retention-нормализованная стоимость подписки за весь lifetime юзера.
    /// Опирается на бенчмарки RevenueCat State of Subscription Apps 2025:
    /// - Weekly:  median retention ~6 недель  → price × 6
    /// - Monthly: median retention ~4 месяцев → price × 4
    /// - Yearly:  median retention ~1 год     → price × 1
    /// Это **реалистичная** LTV-оценка, а не гросс «если бы платил весь год».
    var normalizedYearlyPrice: Double {
        let n = name.lowercased()
        if isSubscription {
            if n.contains("week") || n.contains("недел") || n.contains("еженедел") {
                return price * 6
            }
            if n.contains("month") || n.contains("ежемес") || n.contains("месяч") {
                return price * 4
            }
            if n.contains("year") || n.contains("annual") || n.contains("годов") || n.contains("ежегод") {
                return price
            }
            // По умолчанию для подписки — считаем как monthly (× 4)
            return price * 4
        }
        // Одноразовая покупка — берем как есть (платится один раз за lifetime)
        return price
    }
}

// MARK: - Final UI model (combined data from Lookup + subtitle from page)
struct AppInfo: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let description: String
    let ratingsCountTotal: Int    // userRatingCount — все оценки (звёзды) в стране
    let averageRating: Double     // средняя за всё время
    let countryCode: String       // для пометки "по стране XX"
    let firstReleaseDate: Date?
    let lastUpdateDate: Date?
    let iconURL: URL?
    let storeURL: URL?
    let sellerName: String
    let primaryGenre: String
    let version: String
    let price: Double          // 0 — бесплатное
    let formattedPrice: String // "Free", "$4.99" и т.д.
    let currency: String       // "USD"
    let iaps: [AppIAP]         // покупки и подписки внутри приложения
    let screenshotURLs: [URL]  // iPhone-скриншоты со страницы App Store

    // MARK: - Estimated installs (very rough — based on review-rate benchmarks)
    /// Industry rule-of-thumb conversion rates of active users → ratings.
    /// 2.0% optimistic, 1.0% mid, 0.5% conservative.
    var installEstimateLow: Int  { ratingsCountTotal * 50 }   // 2%   → lower install bound
    var installEstimateMid: Int  { ratingsCountTotal * 100 }  // 1%   → mid estimate
    var installEstimateHigh: Int { ratingsCountTotal * 200 }  // 0.5% → upper install bound

    // MARK: - Estimated lifetime revenue (refined: min/max vilka)
    /// Доля разработчика. Apple берёт 30%; 15% — только для Small Business Program (≤ $1M/год оборота).
    /// Берём 0.80 как разумный midpoint, чуть оптимистичнее 30%-варианта.
    private static let developerShare: Double = 0.80

    /// LTV-бенчмарки для free без IAP (per install, lifetime, USD).
    /// Источник: ad-supported ARPU $0.50-$1/мес → за lifetime ~3-12 мес даёт $1.5-12.
    private static let ltvNoIapMin: Double = 0.30
    private static let ltvNoIapMax: Double = 5.00

    /// Конверсия в платящего юзера (freemium baseline 3%, sensitivity 2% / 5%).
    private static let payingRateMin: Double = 0.02
    private static let payingRateMid: Double = 0.03
    private static let payingRateMax: Double = 0.05

    var isPaid: Bool { price > 0 }
    var hasIAPs: Bool { !iaps.isEmpty }
    var hasSubscriptions: Bool { iaps.contains(where: { $0.isSubscription }) }

    /// Самая дешёвая нормализованная (годовая) цена среди IAP.
    var minYearlyIAPPrice: Double {
        iaps.map(\.normalizedYearlyPrice).filter { $0 > 0 }.min() ?? 0
    }

    /// Самая дорогая нормализованная (годовая) цена среди IAP.
    var maxYearlyIAPPrice: Double {
        iaps.map(\.normalizedYearlyPrice).filter { $0 > 0 }.max() ?? 0
    }

    /// Медианная цена IAP — используется для среднего сценария.
    var medianYearlyIAPPrice: Double {
        let values = iaps.map(\.normalizedYearlyPrice).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 0 ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    // MARK: - Final revenue range (USD, lifetime)
    /// Минимальная оценка дохода — нижняя установка × минимальный план × нижняя конверсия.
    var revenueMin: Double {
        if isPaid {
            return Double(installEstimateLow) * price * AppInfo.developerShare
        }
        if hasIAPs {
            return Double(installEstimateLow) * AppInfo.payingRateMin * minYearlyIAPPrice * AppInfo.developerShare
        }
        return Double(installEstimateLow) * AppInfo.ltvNoIapMin
    }

    /// Средний сценарий — все mid-параметры. Используется для расчёта LTV/install.
    var revenueMid: Double {
        if isPaid {
            return Double(installEstimateMid) * price * AppInfo.developerShare
        }
        if hasIAPs {
            return Double(installEstimateMid) * AppInfo.payingRateMid * medianYearlyIAPPrice * AppInfo.developerShare
        }
        return Double(installEstimateMid) * ((AppInfo.ltvNoIapMin + AppInfo.ltvNoIapMax) / 2)
    }

    /// Максимальная оценка дохода — верхняя установка × максимальный план × верхняя конверсия.
    var revenueMax: Double {
        if isPaid {
            return Double(installEstimateHigh) * price * AppInfo.developerShare
        }
        if hasIAPs {
            return Double(installEstimateHigh) * AppInfo.payingRateMax * maxYearlyIAPPrice * AppInfo.developerShare
        }
        return Double(installEstimateHigh) * AppInfo.ltvNoIapMax
    }

    var revenueFormulaDescription: String {
        if isPaid {
            return "Платное (\(formattedPrice)): установки × цена × 80%. Min/Max — за счёт вилки установок (×50…×200 от оценок)."
        }
        if hasIAPs {
            let minP = String(format: "$%.0f", minYearlyIAPPrice)
            let maxP = String(format: "$%.0f", maxYearlyIAPPrice)
            if hasSubscriptions {
                return "Free + подписки: установки × paying-rate (2-5%) × годовая цена плана (\(minP)…\(maxP)) × 80%. Подписки нормализованы к году."
            } else {
                return "Free + покупки: установки × paying-rate (2-5%) × чек (\(minP)…\(maxP)) × 80% (одноразовый платёж)."
            }
        }
        return "Free без IAP: установки × LTV ($0.30 на нижней / $5 на верхней). Основной доход — реклама."
    }
}
