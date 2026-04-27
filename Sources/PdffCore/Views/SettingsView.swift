import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var workspace: DocumentWorkspace

    public init() {}

    public var body: some View {
        Form {
            Section("AI Labeling") {
                Picker("Provider", selection: $workspace.aiProvider) {
                    ForEach(AIProviderChoice.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                SecureField("API Key", text: $workspace.aiAPIKey)
                Text("AI labeling is opt-in. The app sends detected field labels, page numbers, and nearby extracted text snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Memory") {
                Button("Clear Saved Field Memory") {
                    workspace.memoryStore.clear()
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
