//
//  AppEntryCardView.swift
//  AppNicheFinder
//

import SwiftUI

struct AppEntryCardView: View {
    @Bindable var entry: AppEntry
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let info = entry.info {
                shortMetrics(info)
                if isExpanded { fullDetails(info) }
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Label(isExpanded ? "Свернуть" : "Раскрыть детали",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header (always visible)
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: entry.info?.iconURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                default: Color(.tertiarySystemFill)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.info?.title ?? "ID \(entry.appID)")
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let sub = entry.info?.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                statusBadge
            }
            Spacer(minLength: 0)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if !entry.isDone && !entry.isFailed {
                ProgressView().scaleEffect(0.7)
            } else if entry.isFailed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(entry.statusLabel)
                .font(.caption)
                .foregroundStyle(entry.isFailed ? .red : .secondary)
        }
    }

    // MARK: - Short metrics row
    private func shortMetrics(_ info: AppInfo) -> some View {
        HStack(spacing: 12) {
            metric("Оценка", "\(String(format: "%.2f", info.averageRating))")
            metric("Оценок", formatNumber(info.ratingsCountTotal))
            metric("Доход", "\(formatMoneyShort(info.revenueMin)) – \(formatMoneyShort(info.revenueMax))")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Full details (expanded)
    private func fullDetails(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            installsBlock(info)
            Divider()
            iapBlock(info)
            Divider()
            revenueBlock(info)
            Divider()
            datesRow(info)

            if !entry.praiseSummary.isEmpty {
                Divider()
                summaryBlock(title: "✅ Что хвалят (конкретные фичи)", text: entry.praiseSummary, accent: .green)
            }
            if !entry.complaintsSummary.isEmpty {
                Divider()
                summaryBlock(title: "⚠️ На что жалуются", text: entry.complaintsSummary, accent: .orange)
            }
            if !info.description.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Описание").font(.headline)
                    Text(info.description).font(.callout)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    private func installsBlock(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Примерные установки (\(info.countryCode))").font(.headline)
            HStack(spacing: 12) {
                metric("Низ (2%)",   formatNumberShort(info.installEstimateLow))
                metric("Средне (1%)", formatNumberShort(info.installEstimateMid))
                metric("Верх (0.5%)", formatNumberShort(info.installEstimateHigh))
            }
        }
    }

    private func iapBlock(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Покупки и подписки").font(.headline)
                Spacer()
                if !info.iaps.isEmpty {
                    Text("\(info.iaps.count) шт.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if info.iaps.isEmpty {
                Text("Не найдено").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(info.iaps) { iap in
                    HStack {
                        Image(systemName: iap.isSubscription ? "arrow.triangle.2.circlepath.circle.fill" : "cart.fill")
                            .foregroundStyle(iap.isSubscription ? Color.orange : Color.blue)
                            .font(.caption)
                        Text(iap.name).font(.caption)
                        Spacer()
                        Text(iap.priceFormatted).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func revenueBlock(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Доход (lifetime)").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatMoneyShort(info.revenueMin)).font(.title3.bold())
                Text("–").foregroundStyle(.secondary)
                Text(formatMoneyShort(info.revenueMax)).font(.title3.bold()).foregroundStyle(.green)
            }
            Text(info.revenueFormulaDescription)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func datesRow(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Релиз").foregroundStyle(.secondary); Spacer(); Text(formatDate(info.firstReleaseDate)) }.font(.caption)
            HStack { Text("Обновление").foregroundStyle(.secondary); Spacer(); Text(formatDate(info.lastUpdateDate)) }.font(.caption)
        }
    }

    private func summaryBlock(title: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(accent)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatters
    private func formatNumber(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.groupingSeparator = " "
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatNumberShort(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.0fK", v / 1_000)
        default:               return "\(value)"
        }
    }

    private func formatMoneyShort(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "$%.1fB", value / 1_000_000_000)
        case 1_000_000...:     return String(format: "$%.1fM", value / 1_000_000)
        case 1_000...:         return String(format: "$%.0fK", value / 1_000)
        default:               return String(format: "$%.0f", value)
        }
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }
}
