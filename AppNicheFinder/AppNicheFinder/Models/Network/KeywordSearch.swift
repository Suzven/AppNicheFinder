//
//  KeywordSearch.swift
//  AppNicheFinder
//

import Foundation

/// Один app в результатах поиска по ключу.
struct KeywordSearchHit: Identifiable, Hashable {
    let id: Int            // trackId
    let position: Int      // 1-based
    let title: String
    let sellerName: String
    let iconURL: URL?
    let averageRating: Double
    let ratingCount: Int
    let bundleId: String
}

/// Результат проверки одного keyword-а.
struct KeywordResult: Identifiable, Hashable {
    var id: String { keyword }
    let keyword: String
    let topResults: [KeywordSearchHit]    // топ-10
    /// trackId → позиция (1-based). Если отсутствует — приложение не в top-200.
    let positions: [Int: Int]
}

/// Приложение найденное в поиске по нескольким ключам.
/// Используется в discovery-режиме (поиск по keywords).
struct DiscoveredApp: Identifiable, Hashable {
    let id: Int                    // trackId
    let title: String
    let sellerName: String
    let iconURL: URL?
    let averageRating: Double
    let ratingCount: Int
    let bundleId: String
    /// keyword → позиция (1-based) в выдаче.
    var positions: [String: Int]

    /// Лучшая (минимальная) позиция среди всех ключей.
    var bestPosition: Int { positions.values.min() ?? Int.max }

    /// На скольких ключах нашлось.
    var keywordCount: Int { positions.count }

    /// Примерные установки = userRatingCount × 100 (review-rate 1%).
    var installsEstimate: Int { ratingCount * 100 }
}
