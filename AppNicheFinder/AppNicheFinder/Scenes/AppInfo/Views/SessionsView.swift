//
//  SessionsView.swift
//  AppNicheFinder
//

import SwiftUI

struct SessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SessionStore.shared
    @Bindable var viewModel: AppInfoViewModel

    @State private var renaming: SessionMeta?
    @State private var renameInput: String = ""

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "Пока пусто",
                        systemImage: "tray",
                        description: Text("После каждого анализа сессия сохраняется автоматически.")
                    )
                } else {
                    ForEach(store.sessions) { meta in
                        sessionRow(meta)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            store.delete(id: store.sessions[i].id)
                        }
                    }
                }
            }
            .navigationTitle("История анализов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.entries.isEmpty {
                        Button {
                            viewModel.newSession()
                            dismiss()
                        } label: {
                            Label("Новый", systemImage: "plus")
                        }
                    }
                }
            }
            .alert("Переименовать", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Название", text: $renameInput)
                Button("Сохранить") {
                    if let target = renaming, !renameInput.isEmpty {
                        store.rename(id: target.id, to: renameInput)
                        if viewModel.currentSessionID == target.id {
                            viewModel.currentSessionName = renameInput
                        }
                    }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
        }
    }

    private func sessionRow(_ meta: SessionMeta) -> some View {
        let isCurrent = meta.id == viewModel.currentSessionID
        return Button {
            viewModel.loadSession(meta.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        }
                        Text(meta.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(meta.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Label(meta.country.uppercased(), systemImage: "globe").font(.caption2)
                        Text("•").font(.caption2)
                        Label("\(meta.appCount) апп", systemImage: "square.grid.2x2").font(.caption2)
                        if meta.hasMeta {
                            Text("•").font(.caption2)
                            Label("Niche", systemImage: "wand.and.stars").font(.caption2).foregroundStyle(.purple)
                        }
                        if meta.hasASO {
                            Text("•").font(.caption2)
                            Label("ASO", systemImage: "doc.text.magnifyingglass").font(.caption2).foregroundStyle(.blue)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(relativeDate(meta.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(id: meta.id)
            } label: { Label("Удалить", systemImage: "trash") }

            Button {
                renaming = meta
                renameInput = meta.name
            } label: { Label("Переименовать", systemImage: "pencil") }
            .tint(.blue)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
