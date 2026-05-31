//
//  FeedbackView.swift
//  PhotosClean
//
//  In-app feedback page shown when the user says they're not enjoying the app.
//  Collects a free-text message and hands it off to the user's mail client,
//  prefilled with app/device diagnostics so we can act on it.
//

import SwiftUI
import UIKit

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Where feedback is delivered. Change this to your support inbox.
    private let supportEmail = "yinterestingy@gmail.com"

    @State private var message = ""
    @State private var contactEmail = ""
    @State private var showNoMailAlert = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("feedback.intro".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("feedback.message.label".localized) {
                    TextEditor(text: $message)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("feedback.message.placeholder".localized)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("feedback.contact.label".localized) {
                    TextField("feedback.contact.placeholder".localized, text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("feedback.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("feedback.send".localized) { send() }
                        .disabled(trimmedMessage.isEmpty)
                }
            }
            .alert("feedback.nomail.title".localized, isPresented: $showNoMailAlert) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(L10n.fmt("feedback.nomail.message", supportEmail))
            }
        }
    }

    private func send() {
        guard let url = mailtoURL() else { return }
        openURL(url) { accepted in
            if accepted {
                dismiss()
            } else {
                showNoMailAlert = true
            }
        }
    }

    private func mailtoURL() -> URL? {
        let subject = "TastyTidy Feedback"
        var lines = [trimmedMessage, "", "---"]
        if !contactEmail.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Contact: \(contactEmail)")
        }
        lines.append("App: \(Self.appVersion)")
        lines.append("Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        let body = lines.joined(separator: "\n")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
