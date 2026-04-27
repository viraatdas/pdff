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
    @Published public var visiblePageIndex = 0

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
        visiblePageIndex = 0
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
        var updated = fields[currentIndex]
        updated.value = value
        fields[currentIndex] = updated
        applyWidgetValue(updated)
    }

    public func updateCurrentBool(_ value: Bool) {
        guard let currentIndex else { return }
        var updated = fields[currentIndex]
        updated.boolValue = value
        fields[currentIndex] = updated
        applyWidgetValue(updated)
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
        guard document != nil else { return }
        let bounds: CGRect
        let pageIndex: Int

        if let target = currentField {
            pageIndex = target.pageIndex
            if target.kind == .signature {
                bounds = signatureBounds(for: asset, fitting: target.bounds)
            } else {
                let height = max(target.bounds.height, 36)
                bounds = signatureBounds(
                    for: asset,
                    fitting: CGRect(
                        x: target.bounds.minX,
                        y: max(0, target.bounds.minY - height - 8),
                        width: max(target.bounds.width, 180),
                        height: height
                    )
                )
            }
        } else {
            pageIndex = min(max(visiblePageIndex, 0), max((document?.pageCount ?? 1) - 1, 0))
            let pageBounds = document?.page(at: pageIndex)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            bounds = signatureBounds(
                for: asset,
                fitting: CGRect(x: pageBounds.midX - 100, y: pageBounds.midY - 32, width: 200, height: 64)
            )
        }

        placedSignatures.append(PlacedSignature(assetID: asset.id, pageIndex: pageIndex, bounds: clamped(bounds, pageIndex: pageIndex)))
        if let currentIndex, fields[currentIndex].kind == .signature {
            var updated = fields[currentIndex]
            updated.value = asset.id.uuidString
            fields[currentIndex] = updated
            nextField()
        }
        Haptics.step()
    }

    public func updateVisiblePageIndex(_ index: Int) {
        visiblePageIndex = index
    }

    private func signatureBounds(for asset: SignatureAsset, fitting target: CGRect) -> CGRect {
        let aspectRatio = signatureAspectRatio(asset) ?? 3.0
        let targetWidth = max(target.width, 150)
        let targetHeight = max(target.height, 42)
        let widthByHeight = targetHeight * aspectRatio
        let width = min(max(targetWidth, widthByHeight), 280)
        let height = min(max(width / aspectRatio, 28), max(targetHeight, 72))
        return CGRect(
            x: target.midX - width / 2,
            y: target.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func signatureAspectRatio(_ asset: SignatureAsset) -> CGFloat? {
        guard let image = NSImage(data: asset.pngData), image.size.height > 0 else { return nil }
        return max(image.size.width / image.size.height, 1.8)
    }

    public func removePlacedSignature(id: UUID) {
        placedSignatures.removeAll { $0.id == id }
    }

    public func movePlacedSignature(id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let index = placedSignatures.firstIndex(where: { $0.id == id }) else { return }
        placedSignatures[index].bounds = clamped(
            placedSignatures[index].bounds.offsetBy(dx: dx, dy: dy),
            pageIndex: placedSignatures[index].pageIndex
        )
        Haptics.step()
    }

    public func scalePlacedSignature(id: UUID, factor: CGFloat) {
        guard let index = placedSignatures.firstIndex(where: { $0.id == id }) else { return }
        let oldBounds = placedSignatures[index].bounds
        let newSize = CGSize(
            width: min(max(oldBounds.width * factor, 48), 360),
            height: min(max(oldBounds.height * factor, 18), 160)
        )
        let newBounds = CGRect(
            x: oldBounds.midX - newSize.width / 2,
            y: oldBounds.midY - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
        placedSignatures[index].bounds = clamped(newBounds, pageIndex: placedSignatures[index].pageIndex)
        Haptics.step()
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

    private func applyWidgetValue(_ field: DetectedField) {
        guard field.source == .widget, let annotation = annotation(for: field) else { return }
        switch field.kind {
        case .checkbox:
            annotation.buttonWidgetStateString = field.boolValue ? "Yes" : "Off"
        case .text, .date, .choice:
            annotation.font = NSFont.systemFont(
                ofSize: PDFFieldTextSizer.exportFontSize(for: field.value, in: field.bounds)
            )
            annotation.widgetStringValue = field.value
        case .signature:
            break
        }
    }

    private func annotation(for field: DetectedField) -> PDFAnnotation? {
        if let fieldName = field.widgetFieldName {
            for pageIndex in 0..<(document?.pageCount ?? 0) {
                guard let page = document?.page(at: pageIndex) else { continue }
                if let annotation = page.annotations.first(where: { $0.fieldName == fieldName }) {
                    return annotation
                }
            }
        }

        guard let page = document?.page(at: field.pageIndex) else { return nil }
        return page.annotations.first { annotation in
            annotation.type == PDFAnnotationSubtype.widget.rawValue && annotation.bounds.intersects(field.bounds)
        }
    }

    private func clamped(_ bounds: CGRect, pageIndex: Int) -> CGRect {
        guard let pageBounds = document?.page(at: pageIndex)?.bounds(for: .mediaBox) else {
            return bounds
        }

        let width = min(bounds.width, pageBounds.width)
        let height = min(bounds.height, pageBounds.height)
        let x = min(max(bounds.minX, pageBounds.minX), pageBounds.maxX - width)
        let y = min(max(bounds.minY, pageBounds.minY), pageBounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
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
