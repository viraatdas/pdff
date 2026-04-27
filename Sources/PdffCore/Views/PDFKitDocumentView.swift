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
        view.pdfView.displaysPageBreaks = true
        view.pdfView.pageBreakMargins = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view.pdfView.backgroundColor = .windowBackgroundColor
        view.overlayView.pdfView = view.pdfView
        return view
    }

    public func updateNSView(_ nsView: PDFCanvasView, context: Context) {
        if context.coordinator.document !== workspace.document {
            nsView.loadDocument(workspace.document)
            context.coordinator.document = workspace.document
            context.coordinator.focusedFieldID = workspace.selectedFieldID
        }

        nsView.overlayView.fields = workspace.fields
        nsView.overlayView.selectedFieldID = workspace.selectedFieldID
        nsView.overlayView.placedSignatures = workspace.placedSignatures
        nsView.overlayView.signatureData = Dictionary(
            uniqueKeysWithValues: workspace.signatureStore.signatures.map { ($0.id, $0.pngData) }
        )
        nsView.overlayView.onSelectField = { [weak workspace] id in
            workspace?.selectField(id: id)
        }
        nsView.onPageChanged = { [weak workspace] index in
            workspace?.updateVisiblePageIndex(index)
        }
        nsView.overlayView.needsDisplay = true

        if context.coordinator.focusedFieldID != workspace.selectedFieldID {
            context.coordinator.focusedFieldID = workspace.selectedFieldID
            focusSelectedField(in: nsView)
        }
    }

    public static func dismantleNSView(_ nsView: PDFCanvasView, coordinator: Coordinator) {
        nsView.prepareForDismantle()
        coordinator.document = nil
        coordinator.focusedFieldID = nil
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
    public let pdfView = PannablePDFView()
    public let overlayView = FieldOverlayView()
    public var onPageChanged: ((Int) -> Void)?
    private weak var observedClipView: NSClipView?
    private var lastPublishedPageIndex: Int?
    private var needsInitialTopScroll = false

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfViewChanged),
            name: .PDFViewVisiblePagesChanged,
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
        observeScrollBoundsIfNeeded()
        scrollToTopIfNeeded()
        overlayView.needsDisplay = true
    }

    @objc private func pdfViewChanged() {
        if let page = pdfView.currentPage, let index = pdfView.document?.index(for: page) {
            if index != lastPublishedPageIndex {
                lastPublishedPageIndex = index
                onPageChanged?(index)
            }
        }
        overlayView.needsDisplay = true
    }

    public func prepareForDismantle() {
        NotificationCenter.default.removeObserver(self)
        onPageChanged = nil
        observedClipView = nil
        needsInitialTopScroll = false
        lastPublishedPageIndex = nil
        overlayView.onSelectField = nil
        overlayView.pdfView = nil
        overlayView.fields = []
        overlayView.placedSignatures = []
        overlayView.signatureData = [:]
        pdfView.document = nil
    }

    public func loadDocument(_ document: PDFDocument?) {
        pdfView.document = document
        pdfView.autoScales = true
        observedClipView = nil
        lastPublishedPageIndex = nil
        needsInitialTopScroll = document != nil
        observeScrollBoundsIfNeeded()
        scheduleInitialTopScroll()
    }

    public func goToTopOfDocument() {
        guard let page = pdfView.document?.page(at: 0) else { return }
        pdfView.layoutDocumentView()
        observeScrollBoundsIfNeeded()

        let pageBounds = page.bounds(for: pdfView.displayBox)
        pdfView.go(
            to: CGRect(x: pageBounds.minX, y: pageBounds.maxY - 1, width: 1, height: 1),
            on: page
        )

        if
            let documentView = pdfView.documentView,
            let clipView = documentView.enclosingScrollView?.contentView
        {
            let pageViewRect = pdfView.convert(pageBounds, from: page)
            let pageDocumentRect = documentView.convert(pageViewRect, from: pdfView)
            let targetY = documentView.isFlipped
                ? pageDocumentRect.minY
                : max(documentView.bounds.minY, pageDocumentRect.maxY - clipView.bounds.height)
            let targetX = min(
                max(pageDocumentRect.minX, documentView.bounds.minX),
                max(documentView.bounds.maxX - clipView.bounds.width, documentView.bounds.minX)
            )
            clipView.scroll(to: CGPoint(x: targetX, y: targetY))
            documentView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        needsInitialTopScroll = false
        overlayView.needsDisplay = true
    }

    private func scrollToTopIfNeeded() {
        guard needsInitialTopScroll else { return }
        scheduleInitialTopScroll()
    }

    private func scheduleInitialTopScroll() {
        DispatchQueue.main.async { [weak self] in
            self?.goToTopOfDocument()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.goToTopOfDocument()
        }
    }

    private func observeScrollBoundsIfNeeded() {
        guard let clipView = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        guard observedClipView !== clipView else { return }

        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }

        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfViewChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }
}

public final class PannablePDFView: PDFView {
    private var lastDragLocation: CGPoint?
    private var didDrag = false
    private var pushedClosedHandCursor = false

    override public func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override public func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        didDrag = false
        NSCursor.closedHand.push()
        pushedClosedHandCursor = true
    }

    override public func mouseDragged(with event: NSEvent) {
        guard
            let lastDragLocation,
            let clipView = documentView?.enclosingScrollView?.contentView,
            let documentView
        else { return }

        let current = event.locationInWindow
        let delta = CGPoint(x: current.x - lastDragLocation.x, y: current.y - lastDragLocation.y)
        guard abs(delta.x) > 0.1 || abs(delta.y) > 0.1 else { return }

        var origin = clipView.bounds.origin
        origin.x -= delta.x
        origin.y += delta.y
        origin.x = min(max(origin.x, documentView.bounds.minX), max(documentView.bounds.maxX - clipView.bounds.width, documentView.bounds.minX))
        origin.y = min(max(origin.y, documentView.bounds.minY), max(documentView.bounds.maxY - clipView.bounds.height, documentView.bounds.minY))

        clipView.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
        self.lastDragLocation = current
        didDrag = true
    }

    override public func mouseUp(with event: NSEvent) {
        popClosedHandCursorIfNeeded()
        lastDragLocation = nil
        didDrag = false
    }

    override public func mouseExited(with event: NSEvent) {
        popClosedHandCursorIfNeeded()
        super.mouseExited(with: event)
    }

    private func popClosedHandCursorIfNeeded() {
        guard pushedClosedHandCursor else { return }
        NSCursor.pop()
        pushedClosedHandCursor = false
    }
}

public final class FieldOverlayView: NSView {
    weak var pdfView: PDFView?
    var fields: [DetectedField] = []
    var selectedFieldID: UUID?
    var placedSignatures: [PlacedSignature] = []
    var signatureData: [UUID: Data] = [:]
    var onSelectField: ((UUID) -> Void)?
    private var signatureImageCache: [UUID: NSImage] = [:]
    private var signatureImageCacheKeys = Set<UUID>()

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
                let image = signatureImage(for: placed.assetID)
            else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
            NSColor.systemTeal.withAlphaComponent(0.85).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4).stroke()
        }
    }

    private func signatureImage(for id: UUID) -> NSImage? {
        let keys = Set(signatureData.keys)
        if keys != signatureImageCacheKeys {
            signatureImageCache = signatureImageCache.filter { keys.contains($0.key) }
            signatureImageCacheKeys = keys
        }

        if let cached = signatureImageCache[id] {
            return cached
        }
        guard let data = signatureData[id], let image = NSImage(data: data) else {
            return nil
        }
        signatureImageCache[id] = image
        return image
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
