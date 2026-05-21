//
//  SettingsView.swift
//  AppNicheFinder
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var isRevealed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if isRevealed {
                                TextField("sk-proj-…", text: $settings.openAIKey)
                            } else {
                                SecureField("sk-proj-…", text: $settings.openAIKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)

                        Button {
                            isRevealed.toggle()
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)

                        if !settings.openAIKey.isEmpty {
                            Button(role: .destructive) {
                                settings.openAIKey = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("OpenAI API key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Получить ключ: platform.openai.com → API keys → Create new secret key.")
                        Text("Ключ хранится локально в UserDefaults на устройстве. Не передаётся никуда кроме api.openai.com.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !settings.openAIKey.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: keyLooksValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(keyLooksValid ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Текущий ключ: \(maskedKey)").font(.caption)
                                if !keyLooksValid {
                                    Text("Формат подозрительный (ожидается sk-… длиной 50+ символов)")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            settings.openAIKey = ""
                        } label: {
                            Label("Сбросить ключ", systemImage: "trash")
                        }
                    }
                }

                Section {
                    Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                        Label("Получить новый ключ →", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("Если предыдущий ключ был где-то публично засвечен (в чате, в git, в скриншоте) — OpenAI автоматически его отзывает. Создай новый.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var maskedKey: String {
        let key = settings.openAIKey
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let prefix = key.prefix(10)
        let suffix = key.suffix(4)
        return "\(prefix)…\(suffix) (\(key.count) симв.)"
    }

    private var keyLooksValid: Bool {
        let key = settings.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("sk-") && key.count >= 40
    }
}

#Preview {
    SettingsView()
}
