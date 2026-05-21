//
//  AppEntry.swift
//  AppNicheFinder
//

import Foundation

/// Состояние одного приложения в multi-app сессии анализа.
@Observable
final class AppEntry: Identifiable {
    let id: UUID = UUID()
    let appID: String
    let country: String

    enum Status {
        case pending          // ещё не начали
        case loadingInfo
        case loadingReviews
        case analyzingComplaints
        case analyzingPraise
        case done
        case failed(String)
    }

    var status: Status = .pending
    var info: AppInfo?
    var badReviews: [AppReview] = []
    var goodReviews: [AppReview] = []
    var complaintsSummary: String = ""
    var praiseSummary: String = ""

    init(appID: String, country: String) {
        self.appID = appID
        self.country = country
    }

    var isDone: Bool {
        if case .done = status { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    var statusLabel: String {
        switch status {
        case .pending:             return "В очереди…"
        case .loadingInfo:         return "Загрузка инфо…"
        case .loadingReviews:      return "Загрузка отзывов…"
        case .analyzingComplaints: return "Анализ жалоб…"
        case .analyzingPraise:     return "Анализ плюсов…"
        case .done:                return "Готово"
        case .failed(let msg):     return "Ошибка: \(msg)"
        }
    }
}
