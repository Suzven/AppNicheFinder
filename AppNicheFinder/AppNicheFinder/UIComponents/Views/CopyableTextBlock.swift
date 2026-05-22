//
//  CopyableTextBlock.swift
//  AppNicheFinder
//
//  Скроллируемый блок текста с кнопкой "Копировать" и фидбеком "Скопировано".
//

import SwiftUI
import UIKit

struct CopyableTextBlock: View {
    let text: String
    let maxHeight: CGFloat

    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                UIPasteboard.general.string = text
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Label(copied ? "Скопировано" : "Копировать",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? .green : .accentColor)

            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxHeight: maxHeight)
        }
    }
}
