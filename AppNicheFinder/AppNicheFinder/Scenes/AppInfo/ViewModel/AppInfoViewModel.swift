//
//  AppInfoViewModel.swift
//  AppNicheFinder
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class AppInfoViewModel {

    // MARK: - UI State
    var appIDInput: String = ""
    var country: String = "us"
    var info: AppInfo?
    var isLoading: Bool = false
    var isShowAlert: Bool = false
    var alertMessage: LocalizedStringResource = ""

    // Reviews
    var badReviews: [AppReview] = []
    var isLoadingReviews: Bool = false
    var maxBadRating: Int = 2

    // AI summary
    var complaintsSummary: String = ""
    var isAnalyzing: Bool = false

    // MARK: - Dependencies
    @ObservationIgnored
    private var appLookupService: AppLookupServicing
    @ObservationIgnored
    private var openAIService: OpenAIServicing

    private var fetchTask: Task<Void, Never>?
    private var reviewsTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?

    // MARK: - Init
    init(appLookupService: AppLookupServicing, openAIService: OpenAIServicing) {
        self.appLookupService = appLookupService
        self.openAIService = openAIService
    }

    // MARK: - Public
    func fetch() {
        fetchTask?.cancel()
        reviewsTask?.cancel()
        analyzeTask?.cancel()
        fetchTask = Task {
            defer { fetchTask = nil }
            isLoading = true
            info = nil
            badReviews = []
            complaintsSummary = ""
            do {
                try Task.checkCancellation()
                let result = try await appLookupService.fetchInfo(
                    appID: appIDInput,
                    country: country.isEmpty ? "us" : country.lowercased()
                )
                try Task.checkCancellation()
                info = result
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isLoading = false

            // Загружаем плохие отзывы после успешной загрузки инфо
            if info != nil {
                loadBadReviews()
            }
        }
    }

    func loadBadReviews() {
        reviewsTask?.cancel()
        reviewsTask = Task {
            defer { reviewsTask = nil }
            isLoadingReviews = true
            do {
                try Task.checkCancellation()
                let reviews = try await appLookupService.fetchBadReviews(
                    appID: appIDInput,
                    country: country.isEmpty ? "us" : country.lowercased(),
                    maxRating: maxBadRating,
                    pages: 10
                )
                try Task.checkCancellation()
                badReviews = reviews
            } catch is CancellationError {
                // ignore
            } catch {
                // не показываем алерт — отзывы не критичны, только лог
                print("Reviews fetch error: \(error.localizedDescription)")
            }
            isLoadingReviews = false
        }
    }

    /// Собирает плохие отзывы (≤ 3 звёзды) и отправляет их в OpenAI для саммари жалоб.
    func analyzeComplaints() {
        guard let appTitle = info?.title else { return }
        analyzeTask?.cancel()
        analyzeTask = Task {
            defer { analyzeTask = nil }
            isAnalyzing = true
            complaintsSummary = ""
            do {
                try Task.checkCancellation()
                // Берём именно ≤ 3 для анализа (независимо от UI-пикера)
                let reviewsForAnalysis = try await appLookupService.fetchBadReviews(
                    appID: appIDInput,
                    country: country.isEmpty ? "us" : country.lowercased(),
                    maxRating: 3,
                    pages: 10
                )
                try Task.checkCancellation()

                guard !reviewsForAnalysis.isEmpty else {
                    alertMessage = "Не нашёл отзывов ≤ 3 звезды для анализа."
                    isShowAlert = true
                    isAnalyzing = false
                    return
                }

                let summary = try await openAIService.summarizeComplaints(
                    appTitle: appTitle,
                    reviews: reviewsForAnalysis
                )
                try Task.checkCancellation()
                complaintsSummary = summary
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isAnalyzing = false
        }
    }

    func reset() {
        fetchTask?.cancel()
        reviewsTask?.cancel()
        analyzeTask?.cancel()
        fetchTask = nil
        reviewsTask = nil
        analyzeTask = nil
        info = nil
        badReviews = []
        complaintsSummary = ""
        appIDInput = ""
    }
}
