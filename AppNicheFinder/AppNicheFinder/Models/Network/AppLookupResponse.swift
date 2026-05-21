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
}

// MARK: - Final UI model (combined data from Lookup + subtitle from page)
struct AppInfo: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let description: String
    let reviewsCount: Int
    let averageRating: Double
    let firstReleaseDate: Date?
    let lastUpdateDate: Date?
    let iconURL: URL?
    let storeURL: URL?
    let sellerName: String
    let primaryGenre: String
    let version: String
}
