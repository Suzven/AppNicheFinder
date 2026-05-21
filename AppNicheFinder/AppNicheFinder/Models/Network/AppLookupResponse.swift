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

    // MARK: - Estimated lifetime revenue (very rough)
    /// Доля разработчика (Apple берёт 15-30% — берём 15% как best-case для small business program).
    private static let developerShare: Double = 0.85

    /// LTV-бенчмарки для free приложений БЕЗ IAP (per install, lifetime, USD) — ads/utility.
    private static let ltvNoIapLow: Double  = 0.05
    private static let ltvNoIapMid: Double  = 0.20
    private static let ltvNoIapHigh: Double = 0.50

    /// Конверсия в платящего юзера (paying user rate) для free-app с IAP:
    /// низ/средне/верх — индустрия даёт примерно 1% / 3% / 5% за весь lifetime.
    private static let payingRateLow: Double  = 0.01
    private static let payingRateMid: Double  = 0.03
    private static let payingRateHigh: Double = 0.05

    /// Множитель lifetime для подписок (~12 месяцев среднего срока).
    private static let subscriptionLifetimeMonths: Double = 12

    var isPaid: Bool { price > 0 }
    var hasIAPs: Bool { !iaps.isEmpty }
    var hasSubscriptions: Bool { iaps.contains(where: { $0.isSubscription }) }

    /// Среднее значение цены IAP (используется для оценки revenue).
    var averageIAPPrice: Double {
        guard !iaps.isEmpty else { return 0 }
        return iaps.map(\.price).reduce(0, +) / Double(iaps.count)
    }

    /// Revenue estimate (USD), 3 bands: low / mid / high.
    var revenueLow: Double {
        if isPaid {
            return Double(installEstimateLow) * price * AppInfo.developerShare
        }
        if hasIAPs {
            let perPaying = averageIAPPrice * (hasSubscriptions ? AppInfo.subscriptionLifetimeMonths : 1)
            return Double(installEstimateLow) * AppInfo.payingRateLow * perPaying * AppInfo.developerShare
        }
        return Double(installEstimateMid) * AppInfo.ltvNoIapLow
    }

    var revenueMid: Double {
        if isPaid {
            return Double(installEstimateMid) * price * AppInfo.developerShare
        }
        if hasIAPs {
            let perPaying = averageIAPPrice * (hasSubscriptions ? AppInfo.subscriptionLifetimeMonths : 1)
            return Double(installEstimateMid) * AppInfo.payingRateMid * perPaying * AppInfo.developerShare
        }
        return Double(installEstimateMid) * AppInfo.ltvNoIapMid
    }

    var revenueHigh: Double {
        if isPaid {
            return Double(installEstimateHigh) * price * AppInfo.developerShare
        }
        if hasIAPs {
            let perPaying = averageIAPPrice * (hasSubscriptions ? AppInfo.subscriptionLifetimeMonths : 1)
            return Double(installEstimateHigh) * AppInfo.payingRateHigh * perPaying * AppInfo.developerShare
        }
        return Double(installEstimateMid) * AppInfo.ltvNoIapHigh
    }

    var revenueFormulaDescription: String {
        if isPaid {
            return "Платное (\(formattedPrice)): установки × цена × 85% (доля разработчика). Вилка — диапазон установок (×50 / ×100 / ×200 от оценок)."
        }
        if hasIAPs {
            let avg = String(format: "$%.2f", averageIAPPrice)
            if hasSubscriptions {
                return "Free + подписки: установки × paying-rate (1/3/5%) × ср. чек \(avg) × 12 мес × 85%. Найдено подписок: учитываются как годовой lifetime."
            } else {
                return "Free + покупки: установки × paying-rate (1/3/5%) × ср. чек \(avg) × 85% (один платёж за lifetime)."
            }
        }
        return "Free без IAP: установки × LTV ($0.05 / $0.20 / $0.50). Доход в основном от рекламы."
    }
}
