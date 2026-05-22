//
//  AppInfoViewModel.swift
//  AppNicheFinder
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class AppInfoViewModel {

    // MARK: - Input
    /// Многострочный ввод: один ID на строку или через запятую/пробел.
    var appIDsInput: String = ""
    var country: String = "us"

    // MARK: - Entries (один на каждое введенное приложение)
    var entries: [AppEntry] = []

    // MARK: - Meta-analysis state
    var metaSummary: String = ""
    var isRunningMeta: Bool = false

    // MARK: - Errors
    var isShowAlert: Bool = false
    var alertMessage: LocalizedStringResource = ""

    // MARK: - Dependencies
    @ObservationIgnored
    private var appLookupService: AppLookupServicing
    @ObservationIgnored
    private var openAIService: OpenAIServicing

    @ObservationIgnored
    private var orchestratorTask: Task<Void, Never>?
    @ObservationIgnored
    private var metaTask: Task<Void, Never>?

    // MARK: - Init
    init(appLookupService: AppLookupServicing, openAIService: OpenAIServicing) {
        self.appLookupService = appLookupService
        self.openAIService = openAIService
    }

    // MARK: - Derived progress
    var progress: (done: Int, total: Int) {
        (entries.filter { $0.isDone || $0.isFailed }.count, entries.count)
    }

    var allDone: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.isDone || $0.isFailed }
    }

    var hasAnySuccess: Bool {
        entries.contains(where: { $0.isDone })
    }

    // MARK: - Run analysis
    func startAnalysis() {
        orchestratorTask?.cancel()
        let ids = parseAppIDs(from: appIDsInput)
        guard !ids.isEmpty else {
            alertMessage = "Введите хотя бы один Apple ID приложения."
            isShowAlert = true
            return
        }

        let countryLower = country.isEmpty ? "us" : country.lowercased()
        entries = ids.map { AppEntry(appID: $0, country: countryLower) }
        metaSummary = ""

        orchestratorTask = Task { [weak self] in
            await self?.runAll()
        }
    }

    func cancelAll() {
        orchestratorTask?.cancel()
        metaTask?.cancel()
        orchestratorTask = nil
        metaTask = nil
    }

    func reset() {
        cancelAll()
        entries = []
        metaSummary = ""
        appIDsInput = ""
    }

    // MARK: - Orchestrator
    private func runAll() async {
        // Запускаем все приложения параллельно
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { [weak self] in
                    await self?.process(entry: entry)
                }
            }
        }
    }

    /// Полный цикл для одного приложения: info → reviews → complaints/praise (параллельно).
    private func process(entry: AppEntry) async {
        // 1) Info
        entry.status = .loadingInfo
        do {
            try Task.checkCancellation()
            let info = try await appLookupService.fetchInfo(
                appID: entry.appID,
                country: entry.country
            )
            entry.info = info
        } catch is CancellationError {
            return
        } catch {
            entry.status = .failed(error.localizedDescription)
            return
        }

        // 2) Reviews (параллельно good + bad)
        entry.status = .loadingReviews
        async let badReviews = (try? appLookupService.fetchBadReviews(
            appID: entry.appID,
            country: entry.country,
            maxRating: 3,
            pages: 10
        )) ?? []
        async let goodReviews = (try? appLookupService.fetchGoodReviews(
            appID: entry.appID,
            country: entry.country,
            minRating: 4,
            limit: 80,
            pages: 10
        )) ?? []
        entry.badReviews = await badReviews
        entry.goodReviews = await goodReviews

        // 3) Анализ жалоб (если есть данные)
        entry.status = .analyzingComplaints
        if !entry.badReviews.isEmpty, let title = entry.info?.title {
            do {
                try Task.checkCancellation()
                entry.complaintsSummary = try await openAIService.summarizeComplaints(
                    appTitle: title,
                    reviews: entry.badReviews
                )
            } catch is CancellationError {
                return
            } catch {
                entry.complaintsSummary = "Не удалось проанализировать жалобы: \(error.localizedDescription)"
            }
        }

        // 4) Анализ плюсов
        entry.status = .analyzingPraise
        if !entry.goodReviews.isEmpty, let title = entry.info?.title {
            do {
                try Task.checkCancellation()
                entry.praiseSummary = try await openAIService.summarizePraise(
                    appTitle: title,
                    reviews: entry.goodReviews
                )
            } catch is CancellationError {
                return
            } catch {
                entry.praiseSummary = "Не удалось проанализировать плюсы: \(error.localizedDescription)"
            }
        }

        entry.status = .done
    }

    // MARK: - Meta-analysis
    func runMetaAnalysis() {
        guard hasAnySuccess else { return }
        metaTask?.cancel()
        metaTask = Task { [weak self] in
            guard let self else { return }
            isRunningMeta = true
            metaSummary = ""

            let entriesPayload = entries.compactMap { entry -> MetaAnalysisPayload.AppEntry? in
                guard let info = entry.info, entry.isDone else { return nil }
                return MetaAnalysisPayload.AppEntry(
                    title: info.title,
                    subtitle: info.subtitle,
                    genre: info.primaryGenre,
                    installsEstimate: info.installEstimateMid,
                    ratingsCount: info.ratingsCountTotal,
                    averageRating: info.averageRating,
                    isPaid: info.isPaid,
                    formattedPrice: info.formattedPrice,
                    iaps: info.iaps,
                    complaintsSummary: entry.complaintsSummary,
                    praiseSummary: entry.praiseSummary,
                    revenueMinUSD: info.revenueMin,
                    revenueMaxUSD: info.revenueMax,
                    firstReleaseDate: info.firstReleaseDate,
                    lastUpdateDate: info.lastUpdateDate,
                    description: info.description
                )
            }

            do {
                try Task.checkCancellation()
                let result = try await openAIService.metaAnalysis(
                    payload: MetaAnalysisPayload(apps: entriesPayload)
                )
                try Task.checkCancellation()
                metaSummary = result
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isRunningMeta = false
        }
    }

    // MARK: - Helpers
    private func parseAppIDs(from raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \n\t")
        let tokens = raw.components(separatedBy: separators)
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, Int(cleaned) != nil, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            result.append(cleaned)
        }
        return result
    }
}
