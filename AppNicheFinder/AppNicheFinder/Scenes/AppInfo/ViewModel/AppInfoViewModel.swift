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

    // MARK: - Dependencies
    @ObservationIgnored
    private var appLookupService: AppLookupServicing

    private var fetchTask: Task<Void, Never>?

    // MARK: - Init
    init(appLookupService: AppLookupServicing) {
        self.appLookupService = appLookupService
    }

    // MARK: - Public
    func fetch() {
        fetchTask?.cancel()
        fetchTask = Task {
            defer { fetchTask = nil }
            isLoading = true
            info = nil
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
        }
    }

    func reset() {
        fetchTask?.cancel()
        fetchTask = nil
        info = nil
        appIDInput = ""
    }
}
