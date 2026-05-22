//
//  KeywordCheckView.swift
//  AppNicheFinder
//

import SwiftUI

struct KeywordCheckView: View {
    @Bindable var viewModel: AppInfoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Проверка позиций по ключам").font(.headline)
                Spacer()
                if viewModel.isRunningKeywords {
                    ProgressView().scaleEffect(0.8)
                }
            }
            Text("Введи ключи через запятую или с новой строки. Источник: iTunes Search API (≈ App Store search). Регион — \(viewModel.country.uppercased()).")
                .font(.caption).foregroundStyle(.secondary)

            TextField("plant identifier, flower scanner, ai garden…", text: $viewModel.keywordsInput, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button {
                viewModel.runKeywordCheck()
            } label: {
                Label(viewModel.isRunningKeywords ? "Проверка…" : "Проверить позиции",
                      systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunningKeywords || viewModel.keywordsInput.trimmingCharacters(in: .whitespaces).isEmpty)

            if viewModel.isRunningKeywords {
                let p = viewModel.keywordsProgress
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
            }

            if !viewModel.keywordResults.isEmpty {
                Divider()
                positionsMatrix
                Divider()
                topResultsBlock
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Matrix
    private var positionsMatrix: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Позиции по ключам").font(.subheadline.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    // header
                    HStack(spacing: 6) {
                        Text("Приложение")
                            .font(.caption.bold())
                            .frame(width: 160, alignment: .leading)
                        ForEach(viewModel.keywordResults) { kr in
                            Text(kr.keyword)
                                .font(.caption2)
                                .frame(width: 80, alignment: .center)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    // rows
                    ForEach(viewModel.entries) { entry in
                        HStack(spacing: 6) {
                            Text(entry.info?.title ?? entry.appID)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 160, alignment: .leading)
                            ForEach(viewModel.keywordResults) { kr in
                                let trackId = Int(entry.appID) ?? -1
                                positionCell(kr.positions[trackId])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func positionCell(_ pos: Int?) -> some View {
        Group {
            if let pos {
                Text("#\(pos)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: pos))
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, alignment: .center)
    }

    private func color(for pos: Int) -> Color {
        switch pos {
        case 1...3:   return .green
        case 4...10:  return .blue
        case 11...30: return .orange
        default:      return .secondary
        }
    }

    // MARK: - Top-10 results
    private var topResultsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Топ-10 по каждому ключу").font(.subheadline.bold())
            ForEach(viewModel.keywordResults) { kr in
                VStack(alignment: .leading, spacing: 4) {
                    Text("«\(kr.keyword)»")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(kr.topResults) { hit in
                        HStack(spacing: 8) {
                            Text("#\(hit.position)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(color(for: hit.position))
                                .frame(width: 32, alignment: .leading)
                            AsyncImage(url: hit.iconURL) { phase in
                                switch phase {
                                case .success(let img): img.resizable()
                                default: Color(.tertiarySystemFill)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).font(.caption).lineLimit(1)
                                Text(hit.sellerName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if hit.ratingCount > 0 {
                                Text(String(format: "★ %.1f", hit.averageRating))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Button {
                                addToAnalysis(trackId: hit.id)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.entries.contains(where: { $0.appID == String(hit.id) }))
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func addToAnalysis(trackId: Int) {
        let asString = String(trackId)
        guard !viewModel.entries.contains(where: { $0.appID == asString }) else { return }
        // дописываем в input через перевод строки и запускаем анализ
        if !viewModel.appIDsInput.contains(asString) {
            viewModel.appIDsInput.append(viewModel.appIDsInput.isEmpty ? asString : "\n\(asString)")
        }
        viewModel.startAnalysis()
    }
}
