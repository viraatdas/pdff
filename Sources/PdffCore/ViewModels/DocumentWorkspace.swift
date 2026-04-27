import AppKit
import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
public final class DocumentWorkspace: ObservableObject {
    @Published public var document: PDFDocument?
    @Published public var documentURL: URL?
    @Published public var fields: [DetectedField] = []
    @Published public var selectedFieldID: UUID?
    @Published public var placedSignatures: [PlacedSignature] = []
    @Published public var alert: WorkspaceAlert?
    @Published public var isAILabeling = false
    @Published public var aiProvider: AIProviderChoice = .openAI
    @Published public var aiAPIKey = ""

    public let memoryStore: MemoryStore
    public let signatureStore: SignatureStore

    public init(memoryStore: MemoryStore = MemoryStore(), signatureStore: SignatureStore = SignatureStore()) {
        self.memoryStore = memoryStore
        self.signatureStore = signatureStore
    }

    public var currentIndex: Int? {
        guard let selectedFieldID else { return nil }
        return fields.firstIndex { $0.id == selectedFieldID }
    }

    public var currentField: DetectedField? {
        guard let currentIndex else { return nil }
        return fields[currentIndex]
    }

    public var progressText: String {
        guard let currentIndex else {
            return fields.isEmpty ? "No fields" : "Ready"
        }
        return "Field \(currentIndex + 1) of \(fields.count)"
    }

    public var filledCount: Int {
        fields.filter(\.isFilled).count
    }

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open PDF"
        if panel.runModal() == .OK, let url = panel.url {
            loadPDF(url: url)
        }
    }

    public func loadPDF(url: URL) {
        guard let loaded = PDFDocument(url: url) else {
            alert = WorkspaceAlert(title: "Could Not Open PDF", message: "The selected file is not a readable PDF.")
            return
        }

        document = loaded
        documentURL = url
        fields = FieldDetector.detect(in: loaded)
        placedSignatures = []
        selectedFieldID = fields.first?.id

        if fields.isEmpty {
            let hasText = (0..<loaded.pageCount).contains { loaded.page(at: $0)?.string?.isEmpty == false }
            alert = WorkspaceAlert(
                title: hasText ? "No Fillable Spots Found" : "Scanned PDF Detected",
                message: hasText
                    ? "This PDF has selectable text, but no likely fields were detected. OCR and manual field creation are planned for the next pass."
                    : "This looks image-only. OCR field detection is planned for V2."
            )
        }
    }

    public func presentExportPanel() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName()
        panel.title = "Export Filled PDF"
        if panel.runModal() == .OK, let url = panel.url {
            export(document: document, to: url)
        }
    }

    public func export(document: PDFDocument, to url: URL) {
        fields.forEach { memoryStore.remember($0) }

        do {
            try PDFFillWriter.exportFlattened(
                document: document,
                fields: fields,
                signatures: placedSignatures,
                signatureAssets: Dictionary(uniqueKeysWithValues: signatureStore.signatures.map { ($0.id, $0) }),
                to: url
            )
            Haptics.complete()
            alert = WorkspaceAlert(title: "Export Complete", message: url.path)
        } catch {
            alert = WorkspaceAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    public func selectField(id: UUID?) {
        selectedFieldID = id
    }

    public func updateCurrentValue(_ value: String) {
        guard let currentIndex else { return }
        fields[currentIndex].value = value
    }

    public func updateCurrentBool(_ value: Bool) {
        guard let currentIndex else { return }
        fields[currentIndex].boolValue = value
    }

    public func updateCurrentChoice(_ value: String) {
        updateCurrentValue(value)
    }

    public func useSuggestion(_ value: String) {
        updateCurrentValue(value)
        Haptics.step()
    }

    public func nextField() {
        guard let currentIndex else {
            selectedFieldID = fields.first?.id
            return
        }
        memoryStore.remember(fields[currentIndex])

        let nextIndex = fields.index(after: currentIndex)
        if nextIndex < fields.endIndex {
            selectedFieldID = fields[nextIndex].id
            Haptics.step()
        } else {
            Haptics.complete()
        }
    }

    public func previousField() {
        guard let currentIndex, currentIndex > fields.startIndex else { return }
        selectedFieldID = fields[fields.index(before: currentIndex)].id
        Haptics.step()
    }

    public func improveLabelsWithAI() {
        guard !fields.isEmpty else { return }
        let apiKey = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            alert = WorkspaceAlert(title: "API Key Needed", message: "Add an API key in Settings before using AI labeling.")
            return
        }

        isAILabeling = true
        Task {
            do {
                let improved = try await AIFieldLabeler().improveLabels(fields: fields, provider: aiProvider, apiKey: apiKey)
                fields = improved
                Haptics.step()
            } catch {
                alert = WorkspaceAlert(title: "AI Labeling Failed", message: error.localizedDescription)
            }
            isAILabeling = false
        }
    }

    public func addSignature(name: String, pngData: Data) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        signatureStore.add(SignatureAsset(name: trimmed.isEmpty ? "Signature" : trimmed, pngData: pngData))
    }

    public func placeSignature(_ asset: SignatureAsset) {
        guard let target = currentField ?? fields.first else { return }
        let bounds: CGRect
        if target.kind == .signature {
            bounds = target.bounds
        } else {
            let height = max(target.bounds.height, 36)
            bounds = CGRect(
                x: target.bounds.minX,
                y: max(0, target.bounds.minY - height - 8),
                width: max(target.bounds.width, 160),
                height: height
            )
        }

        placedSignatures.append(PlacedSignature(assetID: asset.id, pageIndex: target.pageIndex, bounds: bounds))
        if let currentIndex, fields[currentIndex].kind == .signature {
            fields[currentIndex].value = asset.id.uuidString
            nextField()
        }
        Haptics.step()
    }

    public func removePlacedSignature(id: UUID) {
        placedSignatures.removeAll { $0.id == id }
    }

    public func resetDocumentState() {
        fields = fields.map { field in
            var reset = field
            reset.value = ""
            reset.boolValue = false
            return reset
        }
        placedSignatures = []
        selectedFieldID = fields.first?.id
    }

    private func defaultExportName() -> String {
        let base = documentURL?.deletingPathExtension().lastPathComponent ?? "filled"
        return "\(base)-filled.pdf"
    }
}

public struct WorkspaceAlert: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}
