//
//  AppSettings.swift
//  AppNicheFinder
//
//  Хранение пользовательских настроек: OpenAI API key и т.п.
//  Используется UserDefaults — для prod лучше переехать на Keychain.
//

import Foundation
import Observation

@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    private enum Keys {
        static let openAIKey = "settings.openAIKey"
    }

    /// UserDefaults thread-safe, доступ откуда угодно безопасен.
    var openAIKey: String {
        didSet {
            UserDefaults.standard.set(openAIKey, forKey: Keys.openAIKey)
        }
    }

    private init() {
        self.openAIKey = UserDefaults.standard.string(forKey: Keys.openAIKey) ?? ""
    }
}
