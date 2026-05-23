//
//  AppInfoViewModel.swift
//  AppNicheFinder
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class AppInfoViewModel {

    // MARK: - Mode
    enum AnalysisMode: String, CaseIterable, Identifiable {
        case byIDs = "По Apple ID"
        case byKeywords = "По ключам"
        var id: String { rawValue }
    }
    var mode: AnalysisMode = .byIDs

    // MARK: - Input
    /// Многострочный ввод: один ID на строку или через запятую/пробел.
    var appIDsInput: String = ""
    var country: String = "us"

    // MARK: - Discovery state (для режима byKeywords)
    var discoveryKeywordsInput: String = ""
    var discoveredApps: [DiscoveredApp] = []
    var selectedDiscoveredIDs: Set<Int> = []
    var isRunningDiscovery: Bool = false
    var lastDiscoveryKeywords: [String] = [] // для отображения колонок матрицы

    // MARK: - Entries (один на каждое введенное приложение)
    var entries: [AppEntry] = []

    // MARK: - Meta-analysis state
    var metaSummary: String = ""
    var isRunningMeta: Bool = false

    // MARK: - ASO state
    var asoSummary: String = ""
    var isRunningASO: Bool = false

    // MARK: - Visual analysis state
    var visualsSummary: String = ""
    var isRunningVisuals: Bool = false

    // MARK: - Keyword search state
    var keywordsInput: String = ""
    var keywordResults: [KeywordResult] = []
    var isRunningKeywords: Bool = false
    var keywordsProgress: (done: Int, total: Int) = (0, 0)

    // MARK: - Errors
    var isShowAlert: Bool = false
    var alertMessage: LocalizedStringResource = ""

    // MARK: - Session linkage
    /// id текущей открытой сессии. Если nil — анализ ещё не сохранён.
    var currentSessionID: UUID?
    var currentSessionName: String = ""

    // MARK: - Dependencies
    @ObservationIgnored
    private var appLookupService: AppLookupServicing
    @ObservationIgnored
    private var openAIService: OpenAIServicing

    @ObservationIgnored
    private var orchestratorTask: Task<Void, Never>?
    @ObservationIgnored
    private var metaTask: Task<Void, Never>?
    @ObservationIgnored
    private var keywordsTask: Task<Void, Never>?
    @ObservationIgnored
    private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored
    private var asoTask: Task<Void, Never>?
    @ObservationIgnored
    private var visualsTask: Task<Void, Never>?

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

    /// Позиции конкретного приложения по проверенным keyword-ам (discovery + KeywordCheck).
    /// Объединяет данные из discoveredApps и keywordResults.
    func keywordPositions(for entry: AppEntry) -> [(keyword: String, position: Int)] {
        guard let trackId = Int(entry.appID) else { return [] }
        var merged: [String: Int] = [:]
        // 1) discovery
        if let disc = discoveredApps.first(where: { $0.id == trackId }) {
            for (kw, pos) in disc.positions { merged[kw] = pos }
        }
        // 2) keyword check (постфактумный)
        for kr in keywordResults {
            if let pos = kr.positions[trackId] { merged[kr.keyword] = pos }
        }
        return merged.sorted { $0.value < $1.value }.map { (keyword: $0.key, position: $0.value) }
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
        asoSummary = ""
        visualsSummary = ""
        // Новый набор приложений → начинаем новую сессию
        currentSessionID = nil
        currentSessionName = ""

        orchestratorTask = Task { [weak self] in
            await self?.runAll()
        }
    }

    func cancelAll() {
        orchestratorTask?.cancel()
        metaTask?.cancel()
        keywordsTask?.cancel()
        discoveryTask?.cancel()
        asoTask?.cancel()
        visualsTask?.cancel()
        orchestratorTask = nil
        metaTask = nil
        keywordsTask = nil
        discoveryTask = nil
        asoTask = nil
        visualsTask = nil
    }

    func reset() {
        cancelAll()
        entries = []
        metaSummary = ""
        asoSummary = ""
        visualsSummary = ""
        appIDsInput = ""
        discoveryKeywordsInput = ""
        discoveredApps = []
        selectedDiscoveredIDs = []
        lastDiscoveryKeywords = []
        keywordsInput = ""
        keywordResults = []
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
        // Все завершились — авто-сохраняем сессию
        if hasAnySuccess { saveCurrentSession() }
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

    // MARK: - Keyword discovery (поиск конкурентов по ключам)
    func runDiscovery() {
        discoveryTask?.cancel()
        let keywords = parseKeywords(from: discoveryKeywordsInput)
        guard !keywords.isEmpty else {
            alertMessage = "Введите хотя бы один ключ."
            isShowAlert = true
            return
        }
        let countryLower = country.isEmpty ? "us" : country.lowercased()

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            isRunningDiscovery = true
            discoveredApps = []
            selectedDiscoveredIDs = []
            lastDiscoveryKeywords = keywords

            do {
                let found = try await appLookupService.discoverByKeywords(
                    keywords, country: countryLower, perKeywordLimit: 30
                )
                discoveredApps = found
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isRunningDiscovery = false
        }
    }

    /// Запускает полный анализ для отмеченных приложений из discovery.
    func startAnalysisFromDiscovery() {
        guard !selectedDiscoveredIDs.isEmpty else {
            alertMessage = "Отметьте хотя бы одно приложение."
            isShowAlert = true
            return
        }
        // Записываем ID в appIDsInput (чтобы был согласованный input) и стартуем
        appIDsInput = selectedDiscoveredIDs.map(String.init).joined(separator: "\n")
        startAnalysis()
    }

    func toggleDiscoveredSelection(_ trackId: Int) {
        if selectedDiscoveredIDs.contains(trackId) {
            selectedDiscoveredIDs.remove(trackId)
        } else {
            selectedDiscoveredIDs.insert(trackId)
        }
    }

    func selectAllDiscovered() {
        selectedDiscoveredIDs = Set(discoveredApps.map(\.id))
    }

    func deselectAllDiscovered() {
        selectedDiscoveredIDs = []
    }

    // MARK: - Keyword check
    func runKeywordCheck() {
        keywordsTask?.cancel()
        let keywords = parseKeywords(from: keywordsInput)
        guard !keywords.isEmpty else {
            alertMessage = "Введите хотя бы один ключ."
            isShowAlert = true
            return
        }
        let trackedIDs: Set<Int> = Set(entries.compactMap { Int($0.appID) })
        let countryLower = country.isEmpty ? "us" : country.lowercased()

        keywordsTask = Task { [weak self] in
            guard let self else { return }
            isRunningKeywords = true
            keywordResults = []
            keywordsProgress = (0, keywords.count)

            // Параллельно, но с лимитом по 4 одновременных (rate-limit для iTunes API)
            var results: [KeywordResult] = []
            let lock = NSLock()

            await withTaskGroup(of: KeywordResult?.self) { group in
                let semaphore = AsyncSemaphore(limit: 4)
                for kw in keywords {
                    group.addTask { [weak self] in
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }
                        guard let self else { return nil }
                        do {
                            return try await self.appLookupService.searchKeyword(
                                kw, country: countryLower, trackedAppIDs: trackedIDs
                            )
                        } catch {
                            return KeywordResult(keyword: kw, topResults: [], positions: [:])
                        }
                    }
                }
                for await result in group {
                    if let result {
                        lock.lock()
                        results.append(result)
                        lock.unlock()
                        keywordsProgress.done += 1
                    }
                }
            }

            // сохраняем в порядке введённых ключей
            let order = Dictionary(uniqueKeysWithValues: keywords.enumerated().map { ($1, $0) })
            keywordResults = results.sorted {
                (order[$0.keyword] ?? 0) < (order[$1.keyword] ?? 0)
            }
            isRunningKeywords = false
        }
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

            let kwPayload: [MetaAnalysisPayload.KeywordEntry] = keywordResults.map { kr in
                MetaAnalysisPayload.KeywordEntry(
                    keyword: kr.keyword,
                    positions: kr.positions,
                    topTitles: kr.topResults.map { $0.title }
                )
            }

            do {
                try Task.checkCancellation()
                let result = try await openAIService.metaAnalysis(
                    payload: MetaAnalysisPayload(apps: entriesPayload, keywords: kwPayload)
                )
                try Task.checkCancellation()
                metaSummary = result
                saveCurrentSession()
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isRunningMeta = false
        }
    }

    // MARK: - ASO analysis
    func runASOAnalysis() {
        guard hasAnySuccess else { return }
        guard !metaSummary.isEmpty else {
            alertMessage = "Сначала запусти Summarize All — нужен анализ ниши."
            isShowAlert = true
            return
        }
        asoTask?.cancel()
        asoTask = Task { [weak self] in
            guard let self else { return }
            isRunningASO = true
            asoSummary = ""

            // Сборка конкурентов
            let competitors: [ASOAnalysisPayload.CompetitorEntry] = entries.compactMap { entry in
                guard let info = entry.info, entry.isDone else { return nil }
                let trackId = Int(entry.appID) ?? -1

                // Объединяем позиции из discovery и keyword check
                var positions: [String: Int] = [:]
                if let disc = discoveredApps.first(where: { $0.id == trackId }) {
                    for (kw, pos) in disc.positions { positions[kw] = pos }
                }
                for kr in keywordResults {
                    if let pos = kr.positions[trackId] { positions[kr.keyword] = pos }
                }

                return ASOAnalysisPayload.CompetitorEntry(
                    title: info.title,
                    subtitle: info.subtitle,
                    description: info.description,
                    genre: info.primaryGenre,
                    installsEstimate: info.installEstimateMid,
                    ratingsCount: info.ratingsCountTotal,
                    averageRating: info.averageRating,
                    keywordPositions: positions
                )
            }

            // Собираем уникальный список всех ключей которые мы исследовали
            var kwSet = Set<String>()
            for kr in keywordResults { kwSet.insert(kr.keyword) }
            for d in discoveredApps {
                for kw in d.positions.keys { kwSet.insert(kw) }
            }
            let allKeywords = Array(kwSet).sorted()

            let payload = ASOAnalysisPayload(
                nicheSummary: metaSummary,
                competitors: competitors,
                allKeywords: allKeywords
            )

            do {
                try Task.checkCancellation()
                let result = try await openAIService.asoAnalysis(payload: payload)
                try Task.checkCancellation()
                asoSummary = result
                saveCurrentSession()
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isRunningASO = false
        }
    }

    // MARK: - Visual analysis
    func runVisualsAnalysis() {
        guard hasAnySuccess else { return }
        visualsTask?.cancel()
        visualsTask = Task { [weak self] in
            guard let self else { return }
            isRunningVisuals = true
            visualsSummary = ""

            let visuals: [VisualAnalysisPayload.AppVisual] = entries.compactMap { entry in
                guard let info = entry.info, entry.isDone else { return nil }
                return VisualAnalysisPayload.AppVisual(
                    title: info.title,
                    ratingsCount: info.ratingsCountTotal,
                    averageRating: info.averageRating,
                    iconURL: info.iconURL,
                    screenshotURLs: Array(info.screenshotURLs.prefix(4))
                )
            }

            do {
                try Task.checkCancellation()
                let result = try await openAIService.analyzeVisuals(
                    payload: VisualAnalysisPayload(apps: visuals)
                )
                try Task.checkCancellation()
                visualsSummary = result
                saveCurrentSession()
            } catch is CancellationError {
                // ignore
            } catch {
                alertMessage = "\(error.localizedDescription)"
                isShowAlert = true
            }
            isRunningVisuals = false
        }
    }

    // MARK: - Session persistence
    /// Сохраняет текущее состояние как сессию. Если сессия уже была загружена/создана —
    /// обновляет её, иначе создаёт новую.
    @discardableResult
    func saveCurrentSession(name customName: String? = nil) -> AnalysisSession? {
        guard !entries.isEmpty else { return nil }

        let id = currentSessionID ?? UUID()
        let name = customName ?? (currentSessionName.isEmpty ? defaultSessionName() : currentSessionName)
        let now = Date()

        let session = AnalysisSession(
            id: id,
            name: name,
            createdAt: now, // если сессия уже была — пересохраним createdAt ниже
            updatedAt: now,
            country: country,
            mode: mode.rawValue,
            appIDsInput: appIDsInput,
            discoveryKeywordsInput: discoveryKeywordsInput,
            keywordsInput: keywordsInput,
            entries: entries.map { $0.toDTO() },
            discoveredApps: discoveredApps.map { $0.toDTO() },
            keywordResults: keywordResults.map { $0.toDTO() },
            metaSummary: metaSummary,
            asoSummary: asoSummary,
            visualsSummary: visualsSummary
        )

        // Сохраняем createdAt от исходной версии, если есть
        var toSave = session
        if let existing = SessionStore.shared.load(id: id) {
            toSave.createdAt = existing.createdAt
        }
        let saved = SessionStore.shared.save(toSave)
        currentSessionID = saved.id
        currentSessionName = saved.name
        return saved
    }

    /// Загружает сессию по ID. Заменяет всё текущее состояние.
    func loadSession(_ id: UUID) {
        guard let session = SessionStore.shared.load(id: id) else { return }
        cancelAll()

        currentSessionID = session.id
        currentSessionName = session.name
        country = session.country
        mode = AnalysisMode(rawValue: session.mode) ?? .byIDs
        appIDsInput = session.appIDsInput
        discoveryKeywordsInput = session.discoveryKeywordsInput
        keywordsInput = session.keywordsInput

        entries = session.entries.map { AppEntry.fromDTO($0) }
        discoveredApps = session.discoveredApps.map(DiscoveredApp.init)
        keywordResults = session.keywordResults.map(KeywordResult.init)
        metaSummary = session.metaSummary
        asoSummary = session.asoSummary
        visualsSummary = session.visualsSummary ?? ""

        // последний снимок исследованных keyword-ов
        lastDiscoveryKeywords = Array(Set(discoveredApps.flatMap { $0.positions.keys })).sorted()
        selectedDiscoveredIDs = []
    }

    /// Очищает текущее состояние и отключает связь с сессией (для нового анализа).
    func newSession() {
        reset()
        currentSessionID = nil
        currentSessionName = ""
    }

    private func defaultSessionName() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        let date = f.string(from: Date())
        if let firstTitle = entries.compactMap({ $0.info?.title }).first {
            return "\(firstTitle) — \(date)"
        }
        return "Сессия \(date)"
    }

    // MARK: - Helpers
    private func parseKeywords(from raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n\t")
        let tokens = raw.components(separatedBy: separators)
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
        }
        return result
    }

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
