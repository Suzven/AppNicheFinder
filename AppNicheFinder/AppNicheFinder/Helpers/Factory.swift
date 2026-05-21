//
//  Factory.swift
//  AppNicheFinder
//

import Foundation

@MainActor
final class Factory {
    static let shared = Factory()
    private init() {}

    // MARK: - Services (created once)
    private(set) lazy var appLookupService: AppLookupServicing = AppLookupService()

    // MARK: - ViewModel factories
    func appInfoVM() -> AppInfoViewModel {
        AppInfoViewModel(appLookupService: appLookupService)
    }
}
