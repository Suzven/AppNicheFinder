//
//  DiscoveryView.swift
//  AppNicheFinder
//

import SwiftUI

struct DiscoveryView: View {
    @Bindable var viewModel: AppInfoViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Ключи для поиска конкурентов").font(.headline)
                Text("Один ключ на строку или через запятую. По каждому соберу top-30 из App Store.")
                    .font(.caption).foregroundStyle(.secondary)

                TextEditor(text: $viewModel.discoveryKeywordsInput)
                    .focused($isInputFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 70, maxHeight: 120)
                    .font(.callout)

                HStack(spacing: 8) {
                    TextField("страна", text: $viewModel.country)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        isInputFocused = false
                        viewModel.runDiscovery()
                    } label: {
                        Label(viewModel.isRunningDiscovery ? "Ищу…" : "Найти конкурентов",
                              systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunningDiscovery
                              || viewModel.discoveryKeywordsInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Results list
            if viewModel.isRunningDiscovery {
                HStack {
                    ProgressView()
                    Text("Сканирую App Store…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if !viewModel.discoveredApps.isEmpty {
                resultsSection
            }
        }
    }

    // MARK: - Results
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + bulk actions
            HStack {
                Text("Найдено: \(viewModel.discoveredApps.count) приложений")
                    .font(.headline)
                Spacer()
                Text("Отмечено: \(viewModel.selectedDiscoveredIDs.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Выделить все") { viewModel.selectAllDiscovered() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                Button("Снять выделение") { viewModel.deselectAllDiscovered() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                Spacer()
                Button {
                    viewModel.startAnalysisFromDiscovery()
                } label: {
                    Label("Анализ выбранных (\(viewModel.selectedDiscoveredIDs.count))",
                          systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedDiscoveredIDs.isEmpty)
            }
            Text("Колонка «Ключи» показывает на скольких из введённых ключей нашлось приложение.")
                .font(.caption2).foregroundStyle(.secondary)

            // List
            LazyVStack(spacing: 6) {
                ForEach(viewModel.discoveredApps) { app in
                    discoveryRow(app)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func discoveryRow(_ app: DiscoveredApp) -> some View {
        let isSelected = viewModel.selectedDiscoveredIDs.contains(app.id)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                viewModel.toggleDiscoveredSelection(app.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let img): img.resizable()
                default: Color(.tertiarySystemFill)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !app.sellerName.isEmpty {
                    Text(app.sellerName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                // chip-row: ключи
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(app.positions.sorted(by: { $0.value < $1.value }), id: \.key) { kw, pos in
                            HStack(spacing: 3) {
                                Text(kw).font(.caption2).lineLimit(1)
                                Text("#\(pos)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(positionColor(pos))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                if app.keywordCount > 1 {
                    Label("\(app.keywordCount)", systemImage: "tag.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                if app.ratingCount > 0 {
                    Text(String(format: "★%.1f", app.averageRating))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(formatNumber(app.ratingCount) + " оц.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("~\(formatNumberShort(app.installsEstimate)) DL")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleDiscoveredSelection(app.id) }
    }

    private func positionColor(_ pos: Int) -> Color {
        switch pos {
        case 1...3:   return .green
        case 4...10:  return .blue
        case 11...30: return .orange
        default:      return .secondary
        }
    }

    private func formatNumber(_ value: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "
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
}
