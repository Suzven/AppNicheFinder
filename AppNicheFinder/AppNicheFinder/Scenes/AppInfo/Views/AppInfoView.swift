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

    private func resultSection(_ info: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(info)
            Divider()
            metricsRow(info)
            Divider()
            datesRow(info)
            Divider()
            descriptionBlock(info)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
        HStack(spacing: 16) {
            metric(title: "Оценка", value: String(format: "%.2f", info.averageRating))
            metric(title: "Отзывы", value: formattedNumber(info.reviewsCount))
            if !info.version.isEmpty {
                metric(title: "Версия", value: info.version)
            }
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
}

#Preview {
    AppInfoView()
}
