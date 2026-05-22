//
//  SessionStore.swift
//  AppNicheFinder
//
//  Хранение сессий локально в Documents/sessions/{id}.json + индекс sessions/index.json.
//

import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    /// Метаданные сессий (без тяжёлого payload — только для списка).
    private(set) var sessions: [SessionMeta] = []

    private let fm = FileManager.default
    private lazy var rootURL: URL = {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        rebuildIndex()
    }

    // MARK: - List
    func rebuildIndex() {
        var metas: [SessionMeta] = []
        let urls = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension == "json" {
            if url.lastPathComponent == "_index.json" { continue }
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(AnalysisSession.self, from: data)
            else { continue }
            metas.append(SessionMeta(
                id: session.id,
                name: session.name,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                country: session.country,
                appCount: session.entries.count,
                subtitle: session.subtitle,
                hasMeta: !session.metaSummary.isEmpty,
                hasASO: !session.asoSummary.isEmpty
            ))
        }
        sessions = metas.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Save
    @discardableResult
    func save(_ session: AnalysisSession) -> AnalysisSession {
        var updated = session
        updated.updatedAt = Date()
        let url = rootURL.appendingPathComponent("\(updated.id.uuidString).json")
        if let data = try? encoder.encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
        rebuildIndex()
        return updated
    }

    // MARK: - Load full session
    func load(id: UUID) -> AnalysisSession? {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AnalysisSession.self, from: data)
    }

    // MARK: - Delete
    func delete(id: UUID) {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        try? fm.removeItem(at: url)
        rebuildIndex()
    }

    // MARK: - Rename
    func rename(id: UUID, to newName: String) {
        guard var session = load(id: id) else { return }
        session.name = newName
        save(session)
    }
}

/// Лёгкая метадата для списка.
struct SessionMeta: Identifiable, Hashable {
    let id: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let country: String
    let appCount: Int
    let subtitle: String
    let hasMeta: Bool
    let hasASO: Bool
}
