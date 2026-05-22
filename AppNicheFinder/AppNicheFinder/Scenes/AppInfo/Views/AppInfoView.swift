//
//  AppInfoView.swift
//  AppNicheFinder
//

import SwiftUI

struct AppInfoView: View {
    @State private var viewModel = Factory.shared.appInfoVM()
    @State private var settings = AppSettings.shared
    @State private var isSettingsPresented: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modePicker
                    if viewModel.mode == .byIDs {
                        inputSection
                    } else {
                        DiscoveryView(viewModel: viewModel)
                    }
                    if !viewModel.entries.isEmpty {
                        progressSection
                        ForEach(viewModel.entries) { entry in
                            AppEntryCardView(
                                entry: entry,
                                keywordPositions: viewModel.keywordPositions(for: entry)
                            )
                        }
                        if viewModel.allDone && viewModel.hasAnySuccess {
                            KeywordCheckView(viewModel: viewModel)
                            metaAnalysisSection
                            if !viewModel.metaSummary.isEmpty {
                                asoAnalysisSection
                                trafficBudgetSection
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Niche Finder")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: settings.openAIKey.isEmpty ? "key.slash" : "gearshape")
                            .foregroundStyle(settings.openAIKey.isEmpty ? .orange : .primary)
                    }
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
            }
            .alert(viewModel.alertMessage, isPresented: $viewModel.isShowAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: - Mode picker
    private var modePicker: some View {
        Picker("Режим", selection: $viewModel.mode) {
            ForEach(AppInfoViewModel.AnalysisMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Input
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple ID приложений").font(.headline)
            Text("Один ID на строку, через запятую или пробел. Все будут проверены параллельно.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $viewModel.appIDsInput)
                .focused($isInputFocused)
                .scrollContentBackground(.hidden)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 80, maxHeight: 140)
                .font(.callout)

            HStack(spacing: 8) {
                TextField("страна", text: $viewModel.country)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)

                Button {
                    isInputFocused = false
                    viewModel.startAnalysis()
                } label: {
                    Label("Запустить анализ", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.appIDsInput.trimmingCharacters(in: .whitespaces).isEmpty)

                if !viewModel.entries.isEmpty {
                    Button(role: .destructive) {
                        viewModel.reset()
                    } label: {
                        Image(systemName: "trash")
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Progress
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let p = viewModel.progress
            HStack {
                Text("Прогресс").font(.headline)
                Spacer()
                Text("\(p.done) / \(p.total)").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .tint(.accentColor)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Meta analysis section
    private var metaAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Итоговый анализ ниши").font(.headline)
                Spacer()
                if viewModel.isRunningMeta {
                    ProgressView().scaleEffect(0.8)
                }
            }
            Text("Сведёт жалобы и плюсы по всем приложениям, подскажет идею продукта, рекомендуемые цены подписок и стратегию запуска.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                viewModel.runMetaAnalysis()
            } label: {
                Label(viewModel.metaSummary.isEmpty ? "Summarize All" : "Перегенерировать",
                      systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunningMeta)

            if !viewModel.metaSummary.isEmpty {
                CopyableTextBlock(text: viewModel.metaSummary, maxHeight: 600)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - ASO analysis section
    private var asoAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ASO Аналитика").font(.headline)
                Spacer()
                if viewModel.isRunningASO {
                    ProgressView().scaleEffect(0.8)
                }
            }
            Text("На основе резюме ниши и позиций конкурентов GPT сгенерирует готовые title / subtitle / description / keywords / шаблоны отзывов для App Store Connect.")
                .font(.caption).foregroundStyle(.secondary)

            Button {
                viewModel.runASOAnalysis()
            } label: {
                Label(viewModel.asoSummary.isEmpty ? "ASO Аналитика" : "Перегенерировать",
                      systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunningASO)

            if !viewModel.asoSummary.isEmpty {
                CopyableTextBlock(text: viewModel.asoSummary, maxHeight: 700)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Traffic budget (показываем после meta-summary)
    private var trafficBudgetSection: some View {
        TrafficBudgetView(entries: viewModel.entries)
    }
}

#Preview {
    AppInfoView()
}
