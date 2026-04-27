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
    @Published public var selectedSignatureID: UUID?
    @Published public var placedSignatures: [PlacedSignature] = []
    @Published public var alert: WorkspaceAlert?
    @Published public var exportResult: ExportResult?
    @Published public var isAILabeling = false
    @Published public var aiProvider: AIProviderChoice = .openAI
    @Published public var aiAPIKey = ""
    @Published public var visiblePageIndex = 0
    @Published public var activeTool: DocumentTool = .select

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
        selectedSignatureID = nil
        visiblePageIndex = 0
        activeTool = .select
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

    public func loadDroppedPDF(from providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let url = Self.fileURL(from: item), url.pathExtension.lowercased() == "pdf" else {
                    return
                }
                Task { @MainActor in
                    self?.loadPDF(url: url)
                }
            }
            return true
        }

        return false
    }

    public func presentExportPanel() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName()
        panel.title = "Save Filled PDF As"
        if panel.runModal() == .OK, let url = panel.url {
            export(document: document, to: url)
        }
    }

    public func presentOverwriteConfirmation() {
        guard let document, let documentURL else { return }

        let panel = NSAlert()
        panel.messageText = "Overwrite Original PDF?"
        panel.informativeText = documentURL.path
        panel.alertStyle = .warning
        panel.addButton(withTitle: "Overwrite")
        panel.addButton(withTitle: "Cancel")

        if panel.runModal() == .alertFirstButtonReturn {
            export(document: document, to: documentURL)
        }
    }

    public func export(document: PDFDocument, to url: URL) {
        fields.forEach { memoryStore.remember($0) }

        do {
            try writeFlattened(document: document, to: url)
            Haptics.complete()
            exportResult = ExportResult(url: url)
        } catch {
            alert = WorkspaceAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    public func selectField(id: UUID?) {
        selectedFieldID = id
        selectedSignatureID = nil
        activeTool = .select
    }

    public func selectPlacedSignature(id: UUID?) {
        selectedSignatureID = id
        selectedFieldID = nil
        activeTool = .select
    }

    public func setActiveTool(_ tool: DocumentTool) {
        activeTool = tool
        if tool != .select {
            selectedFieldID = nil
            selectedSignatureID = nil
        }
    }

    public func toggleActiveTool(_ tool: DocumentTool) {
        setActiveTool(activeTool == tool ? .select : tool)
    }

    public func addManualField(tool: DocumentTool, pageIndex: Int, center: CGPoint) {
        guard let kind = tool.fieldKind else { return }
        let bounds = manualFieldBounds(kind: kind, pageIndex: pageIndex, center: center)
        var field = DetectedField(
            pageIndex: pageIndex,
            bounds: bounds,
            kind: kind,
            label: kind == .checkbox ? "Checkbox" : "Text",
            source: .user,
            confidence: 1,
            boolValue: kind == .checkbox,
            context: "Manually added"
        )

        field.bounds = clamped(field.bounds, pageIndex: pageIndex)
        fields.append(field)
        fields = sortedFields(fields)
        selectedFieldID = field.id
        selectedSignatureID = nil
        activeTool = .select
        Haptics.step()
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

    public func toggleCheckbox(id: UUID) {
        guard let index = fields.firstIndex(where: { $0.id == id && $0.kind == .checkbox }) else { return }
        fields[index].boolValue.toggle()
        applyWidgetValue(fields[index])
        selectedFieldID = id
        selectedSignatureID = nil
        activeTool = .select
        Haptics.step()
    }

    public func updateCurrentChoice(_ value: String) {
        updateCurrentValue(value)
    }

    public func updateCurrentFieldKind(_ kind: FieldKind) {
        guard let currentIndex else { return }
        updateFieldKind(id: fields[currentIndex].id, kind: kind)
    }

    public func updateFieldKind(id: UUID, kind: FieldKind) {
        guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
        var updated = editableCopy(of: fields[index])
        let oldKind = updated.kind
        guard oldKind != kind else { return }

        let refinedBounds = document.flatMap { FieldDetector.refinedBounds(for: updated, as: kind, in: $0) }
        updated.kind = kind
        updated.options = []
        updated.bounds = refinedBounds ?? boundsForKindChange(from: oldKind, to: kind, bounds: updated.bounds, pageIndex: updated.pageIndex)

        switch kind {
        case .checkbox:
            updated.value = ""
            updated.boolValue = true
        case .signature:
            updated.value = ""
            updated.boolValue = false
        case .text, .date, .choice:
            if oldKind == .signature || oldKind == .checkbox {
                updated.value = ""
            }
            updated.boolValue = false
        }

        if updated.label == oldKind.displayName || updated.label == "Field" || updated.label == "Signature" || updated.label == "Checkbox" {
            updated.label = kind.displayName
        }

        fields[index] = updated
        selectedFieldID = updated.id
        selectedSignatureID = nil
        activeTool = .select
        Haptics.step()
    }

    public func setFieldBounds(id: UUID, bounds: CGRect) {
        guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
        var updated = editableCopy(of: fields[index])
        updated.bounds = clamped(normalized(bounds, kind: updated.kind), pageIndex: updated.pageIndex)
        fields[index] = updated
    }

    public func moveCurrentField(dx: CGFloat, dy: CGFloat) {
        guard let currentField else { return }
        setFieldBounds(id: currentField.id, bounds: currentField.bounds.offsetBy(dx: dx, dy: dy))
        Haptics.step()
    }

    public func scaleCurrentField(factor: CGFloat) {
        guard let currentField else { return }
        let oldBounds = currentField.bounds
        let minimum = minimumSize(for: currentField.kind)
        let maximum = maximumSize(for: currentField.kind)
        let newSize = CGSize(
            width: min(max(oldBounds.width * factor, minimum.width), maximum.width),
            height: min(max(oldBounds.height * factor, minimum.height), maximum.height)
        )
        setFieldBounds(
            id: currentField.id,
            bounds: CGRect(
                x: oldBounds.midX - newSize.width / 2,
                y: oldBounds.midY - newSize.height / 2,
                width: newSize.width,
                height: newSize.height
            )
        )
        Haptics.step()
    }

    public func removeCurrentField() {
        guard let currentIndex else { return }
        fields.remove(at: currentIndex)

        if fields.indices.contains(currentIndex) {
            selectedFieldID = fields[currentIndex].id
        } else if let last = fields.last {
            selectedFieldID = last.id
        } else {
            selectedFieldID = nil
        }
        Haptics.step()
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

        let placed = PlacedSignature(assetID: asset.id, pageIndex: pageIndex, bounds: clamped(bounds, pageIndex: pageIndex))
        placedSignatures.append(placed)
        selectedSignatureID = placed.id
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
        if selectedSignatureID == id {
            selectedSignatureID = nil
        }
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

    public func setPlacedSignatureBounds(id: UUID, bounds: CGRect) {
        guard let index = placedSignatures.firstIndex(where: { $0.id == id }) else { return }
        placedSignatures[index].bounds = clamped(bounds, pageIndex: placedSignatures[index].pageIndex)
    }

    public func resetDocumentState() {
        fields = fields.map { field in
            var reset = field
            reset.value = ""
            reset.boolValue = false
            return reset
        }
        placedSignatures = []
        selectedSignatureID = nil
        selectedFieldID = fields.first?.id
        activeTool = .select
    }

    private func defaultExportName() -> String {
        let base = documentURL?.deletingPathExtension().lastPathComponent ?? "filled"
        return "\(base)-filled.pdf"
    }

    private func writeFlattened(document: PDFDocument, to url: URL) throws {
        let signatureAssets = Dictionary(uniqueKeysWithValues: signatureStore.signatures.map { ($0.id, $0) })
        let target = url.standardizedFileURL
        let original = documentURL?.standardizedFileURL

        if target == original {
            let temporaryURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-pdff-\(UUID().uuidString).pdf")
            do {
                try PDFFillWriter.exportFlattened(
                    document: document,
                    fields: fields,
                    signatures: placedSignatures,
                    signatureAssets: signatureAssets,
                    to: temporaryURL
                )
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        } else {
            try PDFFillWriter.exportFlattened(
                document: document,
                fields: fields,
                signatures: placedSignatures,
                signatureAssets: signatureAssets,
                to: url
            )
        }
    }

    nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
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

    private func editableCopy(of field: DetectedField) -> DetectedField {
        var copy = field
        copy.source = .user
        copy.widgetFieldName = nil
        return copy
    }

    private func boundsForKindChange(from oldKind: FieldKind, to newKind: FieldKind, bounds: CGRect, pageIndex: Int) -> CGRect {
        guard oldKind != newKind else { return bounds }
        let pageBounds = document?.page(at: pageIndex)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)

        let newSize: CGSize
        switch newKind {
        case .checkbox:
            let side = min(max(min(bounds.width, bounds.height), 12), 22)
            newSize = CGSize(width: side, height: side)
        case .signature:
            newSize = CGSize(
                width: min(max(bounds.width, pageBounds.width * 0.28), 280),
                height: min(max(bounds.height, 36), 72)
            )
        case .text, .date, .choice:
            newSize = CGSize(
                width: min(max(bounds.width, 96), min(pageBounds.width * 0.45, 280)),
                height: min(max(bounds.height * 0.55, 18), 28)
            )
        }

        return clamped(
            CGRect(
                x: bounds.midX - newSize.width / 2,
                y: bounds.midY - newSize.height / 2,
                width: newSize.width,
                height: newSize.height
            ),
            pageIndex: pageIndex
        )
    }

    private func normalized(_ bounds: CGRect, kind: FieldKind) -> CGRect {
        if kind == .checkbox {
            let side = max(abs(bounds.width), abs(bounds.height), minimumSize(for: kind).width)
            return CGRect(x: bounds.minX, y: bounds.minY, width: side, height: side)
        }

        let minimumSize = minimumSize(for: kind)
        let width = max(abs(bounds.width), minimumSize.width)
        let height = max(abs(bounds.height), minimumSize.height)
        return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: height)
    }

    private func minimumSize(for kind: FieldKind) -> CGSize {
        switch kind {
        case .checkbox:
            CGSize(width: 10, height: 10)
        case .signature:
            CGSize(width: 72, height: 22)
        case .text, .date, .choice:
            CGSize(width: 42, height: 12)
        }
    }

    private func maximumSize(for kind: FieldKind) -> CGSize {
        switch kind {
        case .checkbox:
            CGSize(width: 48, height: 48)
        case .signature:
            CGSize(width: 420, height: 180)
        case .text, .date, .choice:
            CGSize(width: 520, height: 80)
        }
    }

    private func manualFieldBounds(kind: FieldKind, pageIndex: Int, center: CGPoint) -> CGRect {
        let pageBounds = document?.page(at: pageIndex)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let size: CGSize
        switch kind {
        case .checkbox:
            let side = min(max(pageBounds.width * 0.026, 13), 19)
            size = CGSize(width: side, height: side)
        case .signature:
            size = CGSize(width: min(max(pageBounds.width * 0.32, 160), 240), height: min(max(pageBounds.height * 0.05, 36), 52))
        case .text, .date, .choice:
            size = CGSize(width: min(max(pageBounds.width * 0.28, 130), 220), height: min(max(pageBounds.height * 0.028, 18), 26))
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func sortedFields(_ fields: [DetectedField]) -> [DetectedField] {
        fields.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            let dy = abs($0.bounds.midY - $1.bounds.midY)
            if dy > 8 { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
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

public struct ExportResult: Identifiable, Equatable {
    public let id = UUID()
    public var url: URL

    public init(url: URL) {
        self.url = url
    }
}
