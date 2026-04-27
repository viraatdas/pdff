import AppKit
import PDFKit
import SwiftUI

public struct PDFKitDocumentView: NSViewRepresentable {
    @ObservedObject private var workspace: DocumentWorkspace

    public init(workspace: DocumentWorkspace) {
        self.workspace = workspace
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> PDFCanvasView {
        let view = PDFCanvasView()
        view.pdfView.displayMode = .singlePageContinuous
        view.pdfView.displayDirection = .vertical
        view.pdfView.autoScales = true
        view.pdfView.backgroundColor = .windowBackgroundColor
        view.overlayView.pdfView = view.pdfView
        return view
    }

    public func updateNSView(_ nsView: PDFCanvasView, context: Context) {
        if context.coordinator.document !== workspace.document {
            nsView.pdfView.document = workspace.document
            nsView.pdfView.autoScales = true
            context.coordinator.document = workspace.document
        }

        nsView.overlayView.fields = workspace.fields
        nsView.overlayView.selectedFieldID = workspace.selectedFieldID
        nsView.overlayView.placedSignatures = workspace.placedSignatures
        nsView.overlayView.signatureData = Dictionary(
            uniqueKeysWithValues: workspace.signatureStore.signatures.map { ($0.id, $0.pngData) }
        )
        nsView.overlayView.onSelectField = { id in
            workspace.selectField(id: id)
        }
        nsView.onPageChanged = { index in
            workspace.updateVisiblePageIndex(index)
        }
        nsView.overlayView.needsDisplay = true
        nsView.pdfView.setNeedsDisplay(nsView.pdfView.bounds)

        if context.coordinator.focusedFieldID != workspace.selectedFieldID {
            context.coordinator.focusedFieldID = workspace.selectedFieldID
            focusSelectedField(in: nsView)
        }
    }

    private func focusSelectedField(in view: PDFCanvasView) {
        guard
            let selected = workspace.currentField,
            let page = workspace.document?.page(at: selected.pageIndex)
        else { return }

        let pdfRect = view.pdfView.convert(selected.bounds.insetBy(dx: -24, dy: -36), from: page)
        if let documentView = view.pdfView.documentView {
            let documentRect = documentView.convert(pdfRect, from: view.pdfView)
            let visibleRect = documentView.visibleRect
            if visibleRect.insetBy(dx: 80, dy: 120).contains(documentRect) {
                return
            }
            documentView.scrollToVisible(documentRect.insetBy(dx: -120, dy: -160))
        } else {
            let destination = PDFDestination(
                page: page,
                at: CGPoint(x: selected.bounds.midX, y: selected.bounds.maxY + 48)
            )
            view.pdfView.go(to: destination)
        }
    }

    public final class Coordinator {
        fileprivate weak var document: PDFDocument?
        fileprivate var focusedFieldID: UUID?
    }
}

public final class PDFCanvasView: NSView {
    public let pdfView = PDFView()
    public let overlayView = FieldOverlayView()
    public var onPageChanged: ((Int) -> Void)?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(pdfView)
        addSubview(overlayView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfViewChanged),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfViewChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override public func layout() {
        super.layout()
        pdfView.frame = bounds
        overlayView.frame = bounds
        overlayView.needsDisplay = true
    }

    @objc private func pdfViewChanged() {
        if let page = pdfView.currentPage, let index = pdfView.document?.index(for: page) {
            onPageChanged?(index)
        }
        overlayView.needsDisplay = true
    }
}

public final class FieldOverlayView: NSView {
    weak var pdfView: PDFView?
    var fields: [DetectedField] = []
    var selectedFieldID: UUID?
    var placedSignatures: [PlacedSignature] = []
    var signatureData: [UUID: Data] = [:]
    var onSelectField: ((UUID) -> Void)?

    override public var isOpaque: Bool { false }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pdfView else { return }

        for field in fields {
            guard let rect = rect(for: field, in: pdfView), rect.intersects(dirtyRect) else { continue }
            drawHighlight(rect: rect, selected: field.id == selectedFieldID, kind: field.kind)
        }

        for field in fields where field.source != .widget {
            guard let rect = rect(for: field, in: pdfView), rect.intersects(dirtyRect) else { continue }
            drawValue(for: field, in: rect)
        }

        for placed in placedSignatures {
            guard
                let rect = rect(pageIndex: placed.pageIndex, bounds: placed.bounds, in: pdfView),
                let data = signatureData[placed.assetID],
                let image = NSImage(data: data)
            else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
            NSColor.systemTeal.withAlphaComponent(0.85).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4).stroke()
        }
    }

    override public func mouseDown(with event: NSEvent) {
        guard let field = field(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onSelectField?(field.id)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        field(at: point) == nil ? nil : self
    }

    private func field(at point: CGPoint) -> DetectedField? {
        guard let pdfView else { return nil }
        return fields.first { field in
            guard let rect = rect(for: field, in: pdfView) else { return false }
            return rect.insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    private func rect(for field: DetectedField, in pdfView: PDFView) -> CGRect? {
        rect(pageIndex: field.pageIndex, bounds: field.bounds, in: pdfView)
    }

    private func rect(pageIndex: Int, bounds: CGRect, in pdfView: PDFView) -> CGRect? {
        guard let page = pdfView.document?.page(at: pageIndex) else { return nil }
        return pdfView.convert(bounds, from: page)
    }

    private func drawHighlight(rect: CGRect, selected: Bool, kind: FieldKind) {
        let expanded = rect.insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(roundedRect: expanded, xRadius: 5, yRadius: 5)
        let baseColor: NSColor = kind == .signature ? .systemTeal : .systemBlue
        baseColor.withAlphaComponent(selected ? 0.22 : 0.11).setFill()
        path.fill()
        baseColor.withAlphaComponent(selected ? 0.95 : 0.42).setStroke()
        path.lineWidth = selected ? 2.0 : 1.0
        path.stroke()
    }

    private func drawValue(for field: DetectedField, in rect: CGRect) {
        switch field.kind {
        case .checkbox:
            guard field.boolValue else { return }
            drawCheckbox(in: rect)
        case .text, .date, .choice:
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            drawText(value, in: rect)
        case .signature:
            break
        }
    }

    private func drawText(_ text: String, in rect: CGRect) {
        let bounds = rect.insetBy(dx: 4, dy: 2)
        guard bounds.width > 2, bounds.height > 2 else { return }
        let fontSize = PDFFieldTextSizer.previewFontSize(for: text, in: rect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        let drawRect = CGRect(
            x: bounds.minX,
            y: bounds.midY - measured.height / 2,
            width: bounds.width,
            height: measured.height + 2
        )
        (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }

    private func drawCheckbox(in rect: CGRect) {
        let bounds = rect.insetBy(dx: max(2, rect.width * 0.18), dy: max(2, rect.height * 0.18))
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
