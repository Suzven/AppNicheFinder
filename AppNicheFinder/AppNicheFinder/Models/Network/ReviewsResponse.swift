//
//  ReviewsResponse.swift
//  AppNicheFinder
//

import Foundation

// MARK: - RSS top-level
struct ReviewsRSSResponse: Decodable {
    let feed: ReviewsFeed
}

struct ReviewsFeed: Decodable {
    let entry: [ReviewEntry]?
}

// MARK: - Review entry (note: the RSS JSON has unusual nesting with .label)
struct ReviewEntry: Decodable {
    let id: LabelValue
    let title: LabelValue
    let content: ContentField
    let rating: LabelValue
    let author: AuthorField
    let updated: LabelValue?
    let version: LabelValue?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case rating = "im:rating"
        case author
        case updated
        case version = "im:version"
    }
}

struct LabelValue: Decodable {
    let label: String
}

struct ContentField: Decodable {
    let label: String
}

struct AuthorField: Decodable {
    let name: LabelValue
}

// MARK: - UI model
struct AppReview: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let rating: Int
    let author: String
    let version: String
    let updated: Date?
}
