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
}

// MARK: - In-App Purchase model (parsed from apps.apple.com)
struct AppIAP: Identifiable, Hashable {
    let id: String
    let name: String
    let priceFormatted: String
    let price: Double
    let isSubscription: Bool

    /// Нормализованная годовая стоимость для оценки LTV.
    /// Weekly → ×52, Monthly → ×12, Yearly → ×1, Lifetime/IAP → как есть.
    var normalizedYearlyPrice: Double {
        let n = name.lowercased()
        if isSubscription {
            if n.contains("week") || n.contains("недел") || n.contains("еженедел") {
                return price * 52
            }
            if n.contains("month") || n.contains("ежемес") || n.contains("месяч") {
                return price * 12
            }
            if n.contains("year") || n.contains("annual") || n.contains("годов") || n.contains("ежегод") {
                return price
            }
            // По умолчанию для подписки — месячная (самый частый дефолт)
            return price * 12
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
