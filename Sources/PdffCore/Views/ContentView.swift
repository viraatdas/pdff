import PDFKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject private var workspace: DocumentWorkspace
    @State private var showingSignatureSheet = false
    @State private var isDroppingPDF = false

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(showingSignatureSheet: $showingSignatureSheet)
                    .frame(width: 340)
                    .background(.background)

                Divider()

                ZStack {
                    if workspace.document == nil {
                        EmptyDocumentView()
                    } else {
                        PDFKitDocumentView(workspace: workspace)
                        DocuSignNextButton()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isDroppingPDF {
                DropOverlayView()
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDroppingPDF,
            perform: workspace.loadDroppedPDF(from:)
        )
        .toolbar {
            ToolbarItemGroup {
                Button {
                    workspace.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "doc.badge.plus")
                }

                Button {
                    workspace.presentExportPanel()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(workspace.document == nil)
            }
        }
        .sheet(isPresented: $showingSignatureSheet) {
            SignatureCreationSheet { name, data in
                workspace.addSignature(name: name, pngData: data)
                showingSignatureSheet = false
            }
        }
        .alert(item: $workspace.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct DropOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 42, weight: .semibold))
                    Text("Drop PDF to Open")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(24)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var workspace: DocumentWorkspace
    @Binding var showingSignatureSheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if workspace.document == nil {
                        Button {
                            workspace.presentOpenPanel()
                        } label: {
                            Label("Open PDF", systemImage: "doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        CurrentFieldEditor()
                        SignatureSection(showingSignatureSheet: $showingSignatureSheet)
                        FieldList()
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var workspace: DocumentWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("pdff")
                .font(.title2.weight(.semibold))
            Text(workspace.documentURL?.lastPathComponent ?? "Native PDF fill and sign")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if workspace.document != nil {
                ProgressView(value: Double(workspace.filledCount), total: Double(max(workspace.fields.count, 1)))
                Text("\(workspace.filledCount) of \(workspace.fields.count) filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CurrentFieldEditor: View {
    @EnvironmentObject private var workspace: DocumentWorkspace
    @FocusState private var fieldInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let field = workspace.currentField {
                HStack {
                    Text(workspace.progressText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(field.source.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(field.label)
                    .font(.headline)
                    .lineLimit(2)

                editor(for: field)

                let suggestions = workspace.memoryStore.suggestions(for: field.label)
                if !suggestions.isEmpty, field.kind != .checkbox, field.kind != .signature {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggestions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                workspace.useSuggestion(suggestion)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    Button {
                        workspace.previousField()
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .disabled(workspace.currentIndex == nil || workspace.currentIndex == 0)

                    Spacer()

                    Button {
                        workspace.nextField()
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            } else {
                Text("No fields detected")
                    .font(.headline)
                Text("This version detects real PDF form fields and common blank-line patterns. OCR for scans is next.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: focusIfEditable)
        .onChange(of: workspace.selectedFieldID) { _, _ in
            focusIfEditable()
        }
    }

    @ViewBuilder
    private func editor(for field: DetectedField) -> some View {
        switch field.kind {
        case .checkbox:
            Toggle("Checked", isOn: Binding(
                get: { workspace.currentField?.boolValue ?? false },
                set: { workspace.updateCurrentBool($0) }
            ))
            .toggleStyle(.checkbox)

        case .choice:
            if field.options.isEmpty {
                TextField("", text: Binding(
                    get: { workspace.currentField?.value ?? "" },
                    set: { workspace.updateCurrentChoice($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($fieldInputFocused)
                .onSubmit { workspace.nextField() }
            } else {
                Picker("Choice", selection: Binding(
                    get: { workspace.currentField?.value ?? field.options.first ?? "" },
                    set: { workspace.updateCurrentChoice($0) }
                )) {
                    ForEach(field.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            }

        case .date:
            TextField("", text: Binding(
                get: { workspace.currentField?.value ?? "" },
                set: { workspace.updateCurrentValue($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .focused($fieldInputFocused)
            .onSubmit { workspace.nextField() }

        case .signature:
            Text("Choose a saved signature below, then place it on this field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .text:
            TextField("", text: Binding(
                get: { workspace.currentField?.value ?? "" },
                set: { workspace.updateCurrentValue($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .focused($fieldInputFocused)
            .onSubmit { workspace.nextField() }
        }
    }

    private func focusIfEditable() {
        let shouldFocus = switch workspace.currentField?.kind {
        case .text, .date, .choice:
            true
        case .checkbox, .signature, nil:
            false
        }
        DispatchQueue.main.async {
            fieldInputFocused = shouldFocus
        }
    }
}

private struct DocuSignNextButton: View {
    @EnvironmentObject private var workspace: DocumentWorkspace

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    workspace.nextField()
                } label: {
                    HStack(spacing: 8) {
                        Text(nextTitle)
                            .font(.headline)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.fields.isEmpty)
                .padding(24)
            }
        }
        .allowsHitTesting(!workspace.fields.isEmpty)
    }

    private var nextTitle: String {
        guard let currentIndex = workspace.currentIndex else { return "Start" }
        return currentIndex == workspace.fields.count - 1 ? "Finish" : "Next"
    }
}

private struct SignatureSection: View {
    @EnvironmentObject private var workspace: DocumentWorkspace
    @Binding var showingSignatureSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Signatures")
                    .font(.headline)
                Spacer()
                Button {
                    showingSignatureSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add signature")
            }

            if workspace.signatureStore.signatures.isEmpty {
                Text("Add a drawn or typed signature once, then reuse it across PDFs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workspace.signatureStore.signatures) { signature in
                    HStack(spacing: 10) {
                        SignaturePreview(data: signature.pngData)
                            .frame(width: 96, height: 34)
                            .background(.white, in: RoundedRectangle(cornerRadius: 4))
                        Text(signature.name)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            workspace.placeSignature(signature)
                        } label: {
                            Image(systemName: "signature")
                        }
                        .help("Place signature")
                    }
                }
            }

            if !workspace.placedSignatures.isEmpty {
                Divider()
                Text("Placed")
                    .font(.subheadline.weight(.medium))

                ForEach(workspace.placedSignatures) { placed in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(signatureName(for: placed))
                                .lineLimit(1)
                            Spacer()
                            Text("Page \(placed.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            Button {
                                workspace.movePlacedSignature(id: placed.id, dx: -8, dy: 0)
                            } label: {
                                Image(systemName: "arrow.left")
                            }
                            .help("Move left")

                            Button {
                                workspace.movePlacedSignature(id: placed.id, dx: 8, dy: 0)
                            } label: {
                                Image(systemName: "arrow.right")
                            }
                            .help("Move right")

                            Button {
                                workspace.movePlacedSignature(id: placed.id, dx: 0, dy: 8)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .help("Move up")

                            Button {
                                workspace.movePlacedSignature(id: placed.id, dx: 0, dy: -8)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .help("Move down")

                            Divider()
                                .frame(height: 20)

                            Button {
                                workspace.scalePlacedSignature(id: placed.id, factor: 0.9)
                            } label: {
                                Image(systemName: "minus.magnifyingglass")
                            }
                            .help("Make smaller")

                            Button {
                                workspace.scalePlacedSignature(id: placed.id, factor: 1.1)
                            } label: {
                                Image(systemName: "plus.magnifyingglass")
                            }
                            .help("Make larger")

                            Spacer()

                            Button(role: .destructive) {
                                workspace.removePlacedSignature(id: placed.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Remove")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func signatureName(for placed: PlacedSignature) -> String {
        workspace.signatureStore.signature(id: placed.assetID)?.name ?? "Signature"
    }
}

private struct FieldList: View {
    @EnvironmentObject private var workspace: DocumentWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fields")
                    .font(.headline)
                Spacer()
                Button {
                    workspace.improveLabelsWithAI()
                } label: {
                    if workspace.isAILabeling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .disabled(workspace.fields.isEmpty || workspace.isAILabeling)
                .help("Improve labels with AI")
            }

            ForEach(workspace.fields) { field in
                Button {
                    workspace.selectField(id: field.id)
                } label: {
                    HStack {
                        Image(systemName: iconName(for: field))
                            .foregroundStyle(field.isFilled ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label)
                                .lineLimit(1)
                            Text("Page \(field.pageIndex + 1) - \(field.kind.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    workspace.selectedFieldID == field.id ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
        }
    }

    private func iconName(for field: DetectedField) -> String {
        switch field.kind {
        case .text: "text.cursor"
        case .date: "calendar"
        case .checkbox: field.boolValue ? "checkmark.square.fill" : "square"
        case .choice: "list.bullet.rectangle"
        case .signature: "signature"
        }
    }
}

private struct EmptyDocumentView: View {
    @EnvironmentObject private var workspace: DocumentWorkspace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Open a PDF to start")
                .font(.title3.weight(.semibold))
            Button {
                workspace.presentOpenPanel()
            } label: {
                Label("Open PDF", systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SignaturePreview: View {
    var data: Data

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "signature")
        }
    }
}
