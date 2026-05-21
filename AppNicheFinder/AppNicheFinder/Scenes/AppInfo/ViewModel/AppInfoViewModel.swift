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

    // MARK: - Dependencies
    @ObservationIgnored
    private var appLookupService: AppLookupServicing

    private var fetchTask: Task<Void, Never>?
    private var reviewsTask: Task<Void, Never>?

    // MARK: - Init
    init(appLookupService: AppLookupServicing) {
        self.appLookupService = appLookupService
    }

    // MARK: - Public
    func fetch() {
        fetchTask?.cancel()
        reviewsTask?.cancel()
        fetchTask = Task {
            defer { fetchTask = nil }
            isLoading = true
            info = nil
            badReviews = []
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

    func reset() {
        fetchTask?.cancel()
        reviewsTask?.cancel()
        fetchTask = nil
        reviewsTask = nil
        info = nil
        badReviews = []
        appIDInput = ""
    }
}
