//
//  TrafficBudgetView.swift
//  AppNicheFinder
//
//  Бенчмарки CPI и формула закупки трафика на основе:
//  - Mapendo CPI 2025 by category
//  - Business of Apps CPI Rates 2025
//  - AppTweak Apple Ads benchmarks 2025
//  - RevenueCat State of Subscription Apps 2025
//

import SwiftUI

struct TrafficBudgetView: View {
    let entries: [AppEntry]

    // CPI бенчмарки 2025 (USA iOS) по категориям ($)
    private static let cpiByCategory: [(needle: String, low: Double, high: Double)] = [
        ("game",       3.5, 6.0),
        ("игр",        3.5, 6.0),
        ("finance",    5.0, 8.7),
        ("финанс",     5.0, 8.7),
        ("business",   3.5, 8.0),
        ("dating",     5.0, 6.3),
        ("шопп",       1.0, 1.5),
        ("shopping",   1.0, 1.5),
        ("retail",     1.0, 1.5),
        ("entertain",  0.9, 1.5),
        ("health",     2.5, 5.0),
        ("здоров",     2.5, 5.0),
        ("fitness",    2.5, 5.0),
        ("educat",     2.0, 4.0),
        ("обучен",     2.0, 4.0),
        ("photo",      1.5, 3.5),
        ("утил",       1.5, 3.5),
        ("util",       1.5, 3.5),
        ("product",    2.0, 4.5)
    ]
    private static let defaultCPI: (low: Double, high: Double) = (3.0, 5.0)

    // Industry conversions
    private static let installToTrial: Double = 0.10 // 10% устанавливают триал
    private static let trialToPaid: Double    = 0.40 // 40% доходят до платной (RevenueCat бенчмарк)
    // итого install → paying: 4%

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Бюджет на закупку трафика").font(.headline)
            Text("Расчёт основан на индустриальных CPI 2025 (USA iOS) по категории. Источники в комментариях кода.")
                .font(.caption).foregroundStyle(.secondary)

            let (cpiLow, cpiHigh) = currentCPI()
            HStack(spacing: 14) {
                metric("CPI low",  String(format: "$%.2f", cpiLow))
                metric("CPI high", String(format: "$%.2f", cpiHigh))
                metric("Категория", categoryNameShort())
            }

            Divider()

            // Сценарий "целевой LTV" — берем медиану по доходу/инсталлам конкурентов
            let targetLTV = computeTargetLTV()
            let payingConv = Self.installToTrial * Self.trialToPaid
            HStack(spacing: 14) {
                metric("Целевой LTV/install", String(format: "$%.2f", targetLTV))
                metric("Install→Paying", String(format: "%.1f%%", payingConv * 100))
            }
            Text("LTV/install = revenueMid ÷ installsMid (медиана по конкурентам), с потолком $8 для реализма. Install→Paying = install→trial (10%) × trial→paid (40%) (RevenueCat 2025).")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // Финальные числа
            Group {
                budgetRow(title: "1 000 установок", installs: 1_000, cpiLow: cpiLow, cpiHigh: cpiHigh, ltv: targetLTV)
                budgetRow(title: "10 000 установок", installs: 10_000, cpiLow: cpiLow, cpiHigh: cpiHigh, ltv: targetLTV)
                budgetRow(title: "100 000 установок", installs: 100_000, cpiLow: cpiLow, cpiHigh: cpiHigh, ltv: targetLTV)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Рекомендации").font(.subheadline.bold())
                Text("• Безопасный целевой CPI ≤ LTV × 30% (правило 3:1 LTV:CAC).")
                    .font(.caption).foregroundStyle(.secondary)
                Text("• Apple Search Ads — лучший канал по качеству трафика, CPI обычно близок к нижней границе.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("• Meta/TikTok Ads — больший объём, CPI ближе к верхней границе, нужно тестировать креативы.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("• Стартовый тест: $1 000-2 000 на канал × 7 дней, потом масштабируешь то что окупается.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Sub-views
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func budgetRow(title: String, installs: Int, cpiLow: Double, cpiHigh: Double, ltv: Double) -> some View {
        let budgetLow  = Double(installs) * cpiLow
        let budgetHigh = Double(installs) * cpiHigh
        let revenue    = Double(installs) * ltv
        let romiLow    = revenue / max(budgetHigh, 0.01)
        let romiHigh   = revenue / max(budgetLow, 0.01)

        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack {
                Text("Бюджет").foregroundStyle(.secondary)
                Spacer()
                Text("\(money(budgetLow)) – \(money(budgetHigh))")
            }
            .font(.caption)
            HStack {
                Text("Ожидаемая выручка").foregroundStyle(.secondary)
                Spacer()
                Text(money(revenue)).foregroundStyle(.green)
            }
            .font(.caption)
            HStack {
                Text("ROMI").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "x%.1f – x%.1f", romiLow, romiHigh))
                    .foregroundStyle(romiLow >= 1 ? .green : .red)
            }
            .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers
    private func currentCPI() -> (low: Double, high: Double) {
        let genres = entries.compactMap { $0.info?.primaryGenre.lowercased() }
        for (needle, low, high) in Self.cpiByCategory {
            if genres.contains(where: { $0.contains(needle) }) {
                return (low, high)
            }
        }
        return Self.defaultCPI
    }

    private func categoryNameShort() -> String {
        let genres = Set(entries.compactMap { $0.info?.primaryGenre }.filter { !$0.isEmpty })
        if genres.count == 1 { return genres.first ?? "Mixed" }
        if genres.count <= 3 { return genres.joined(separator: ", ") }
        return "Mixed"
    }

    /// Медианный доход на установку по конкурентам.
    /// Считается по mid-сценарию (revenueMid / installsMid), чтобы числитель
    /// и знаменатель были в одном уровне допущений.
    /// Применяется sanity-cap $8 — выше LTV в индустрии редко встречается даже для топов.
    private func computeTargetLTV() -> Double {
        let successful = entries.compactMap { $0.info }
        guard !successful.isEmpty else { return 0 }
        let perInstall = successful.compactMap { info -> Double? in
            let installs = Double(info.installEstimateMid)
            guard installs > 0 else { return nil }
            return info.revenueMid / installs
        }
        guard !perInstall.isEmpty else { return 0 }
        let sorted = perInstall.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        // sanity-cap: $8 — потолок реалистичного среднего LTV/install в массовых нишах
        return min(median, 8.0)
    }

    private func money(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "$%.1fB", value / 1_000_000_000)
        case 1_000_000...:     return String(format: "$%.1fM", value / 1_000_000)
        case 1_000...:         return String(format: "$%.0fK", value / 1_000)
        default:               return String(format: "$%.0f", value)
        }
    }
}
