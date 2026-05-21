//
//  AppInfoView.swift
//  AppNicheFinder
//

import SwiftUI

struct AppInfoView: View {
    @State private var viewModel = Factory.shared.appInfoVM()
    @FocusState private var isIDFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputSection
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else if let info = viewModel.info {
                        resultSection(info)
                        badReviewsSection
                    }
                }
                .padding(16)
            }
            .navigationTitle("App Info")
            .scrollDismissesKeyboard(.interactively)
            .alert(viewModel.alertMessage, isPresented: $viewModel.isShowAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: - Sections
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple ID приложения")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("например 284882215", text: $viewModel.appIDInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($isIDFocused)

                TextField("страна", text: $viewModel.country)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                isIDFocused = false
                viewModel.fetch()
            } label: {
                Text("Получить информацию")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.appIDInput.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
        }
    }

    private var badReviewsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Плохие отзывы")
                    .font(.headline)
                Spacer()
                Picker("Порог", selection: $viewModel.maxBadRating) {
                    Text("≤ 1★").tag(1)
                    Text("≤ 2★").tag(2)
                    Text("≤ 3★").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: viewModel.maxBadRating) { _, _ in
                    viewModel.loadBadReviews()
                }
            }

            if viewModel.isLoadingReviews {
                HStack {
                    ProgressView()
                    Text("Загрузка отзывов…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if viewModel.badReviews.isEmpty {
                Text("Плохих отзывов не найдено (RSS-фид Apple отдает до 500 свежих).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Text("Найдено: \(viewModel.badReviews.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.badReviews) { review in
                            reviewCard(review)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 480)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func reviewCard(_ review: AppReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stars(for: review.rating)
                Spacer()
                if !review.version.isEmpty {
                    Text("v\(review.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let d = review.updated {
                    Text(format(d))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !review.title.isEmpty {
                Text(review.title)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.leading)
            }
            Text(review.body)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("— \(review.author)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stars(for rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(i <= rating ? Color.orange : Color.secondary)
            }
        }
    }

    private func resultSection(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(info)
            Divider()
            metricsRow(info)
            Divider()
            installsBlock(info)
            Divider()
            datesRow(info)
            Divider()
            descriptionBlock(info)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func installsBlock(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Примерные установки (\(info.countryCode))")
                .font(.headline)

            HStack(spacing: 16) {
                metric(
                    title: "Низ (review-rate 2%)",
                    value: formattedCompact(info.installEstimateLow)
                )
                metric(
                    title: "Средне (1%)",
                    value: formattedCompact(info.installEstimateMid)
                )
                metric(
                    title: "Верх (0.5%)",
                    value: formattedCompact(info.installEstimateHigh)
                )
            }

            Text("Оценка основана на индустриальных бенчмарках: 0.5–2% активных пользователей оставляют оценку. Реальная конверсия зависит от категории, монетизации и того, как часто приложение запрашивает оценку через SKStoreReviewController. Точных данных Apple не публикует.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sub-views
    private func header(_ info: AppInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.iconURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                default:
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.leading)
                if !info.subtitle.isEmpty {
                    Text(info.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                if !info.sellerName.isEmpty {
                    Text(info.sellerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metricsRow(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                metric(
                    title: "Оценка (всё время)",
                    value: String(format: "%.2f", info.averageRating)
                )
                metric(
                    title: "Оценок (всё время, \(info.countryCode))",
                    value: formattedNumber(info.ratingsCountTotal)
                )
            }
            HStack(spacing: 16) {
                metric(
                    title: "Оценка (тек. версия)",
                    value: String(format: "%.2f", info.averageRatingCurrentVersion)
                )
                metric(
                    title: "Оценок (тек. версия)",
                    value: formattedNumber(info.ratingsCountCurrentVersion)
                )
                if !info.version.isEmpty {
                    metric(title: "Версия", value: info.version)
                }
            }
            Text("Apple возвращает количество оценок (звёзд) только для выбранной страны (\(info.countryCode)). Число написанных отзывов гораздо меньше — их можно увидеть в секции ниже.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func datesRow(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(title: "Первая публикация", value: format(info.firstReleaseDate))
            row(title: "Последнее обновление", value: format(info.lastUpdateDate))
        }
    }

    private func descriptionBlock(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Описание")
                .font(.headline)
            Text(info.description)
                .font(.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers
    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formattedNumber(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formattedCompact(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        let abs = Double(value)
        switch abs {
        case 1_000_000_000...:
            return (f.string(from: NSNumber(value: abs / 1_000_000_000)) ?? "0") + " млрд"
        case 1_000_000...:
            return (f.string(from: NSNumber(value: abs / 1_000_000)) ?? "0") + " млн"
        case 1_000...:
            return (f.string(from: NSNumber(value: abs / 1_000)) ?? "0") + " тыс"
        default:
            return formattedNumber(value)
        }
    }
}

#Preview {
    AppInfoView()
}
