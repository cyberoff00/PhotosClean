//
//  CoachMarkOverLay.swift
//  PhotosClean
//
//  Created by Claire Yang on 09/01/2026.
//

import SwiftUI

struct CoachMarkOverlay: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let primaryText: LocalizedStringKey
    let secondaryText: LocalizedStringKey?
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    if let secondaryText, let onSecondary {
                        Button(secondaryText) { onSecondary() }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(primaryText) { onPrimary() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }
}
