import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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
        nsView.overlayView.selectedSignatureID = workspace.selectedSignatureID
        nsView.overlayView.activeTool = workspace.activeTool
        nsView.overlayView.placedSignatures = workspace.placedSignatures
        nsView.overlayView.signatureData = Dictionary(
            uniqueKeysWithValues: workspace.signatureStore.signatures.map { ($0.id, $0.pngData) }
        )
        nsView.overlayView.onSelectField = { [weak workspace] id in
            workspace?.selectField(id: id)
        }
        nsView.overlayView.onToggleCheckbox = { [weak workspace] id in
            workspace?.toggleCheckbox(id: id)
        }
        nsView.overlayView.onAddManualField = { [weak workspace] tool, pageIndex, point in
            workspace?.addManualField(tool: tool, pageIndex: pageIndex, center: point)
        }
        nsView.overlayView.onSelectSignature = { [weak workspace] id in
            workspace?.selectPlacedSignature(id: id)
        }
        nsView.overlayView.onSetSignatureBounds = { [weak workspace] id, bounds in
            workspace?.setPlacedSignatureBounds(id: id, bounds: bounds)
        }
        nsView.onPDFDrop = { [weak workspace] url in
            workspace?.loadPDF(url: url)
        }
        nsView.onPageChanged = { [weak workspace] index in
            workspace?.updateVisiblePageIndex(index)
        }
        nsView.overlayView.needsDisplay = true
        nsView.overlayView.window?.invalidateCursorRects(for: nsView.overlayView)

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
    public var onPDFDrop: ((URL) -> Void)?
    private weak var observedClipView: NSClipView?
    private var lastPublishedPageIndex: Int?
    private var needsInitialTopScroll = false

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(pdfView)
        addSubview(overlayView)
        registerForDraggedTypes([.fileURL])

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
        onPDFDrop = nil
        observedClipView = nil
        needsInitialTopScroll = false
        lastPublishedPageIndex = nil
        overlayView.onSelectField = nil
        overlayView.onToggleCheckbox = nil
        overlayView.onAddManualField = nil
        overlayView.onSelectSignature = nil
        overlayView.onSetSignatureBounds = nil
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

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPDFURL(from: sender) == nil ? [] : .copy
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedPDFURL(from: sender) else { return false }
        onPDFDrop?(url)
        return true
    }

    private func droppedPDFURL(from sender: NSDraggingInfo) -> URL? {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier]
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "pdf" }
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
    var selectedSignatureID: UUID?
    var activeTool: DocumentTool = .select
    var placedSignatures: [PlacedSignature] = []
    var signatureData: [UUID: Data] = [:]
    var onSelectField: ((UUID) -> Void)?
    var onToggleCheckbox: ((UUID) -> Void)?
    var onAddManualField: ((DocumentTool, Int, CGPoint) -> Void)?
    var onSelectSignature: ((UUID) -> Void)?
    var onSetSignatureBounds: ((UUID, CGRect) -> Void)?
    private var signatureImageCache: [UUID: NSImage] = [:]
    private var signatureImageCacheKeys = Set<UUID>()
    private var signatureDrag: SignatureDrag?

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
            let selected = placed.id == selectedSignatureID
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.94)
            drawSignatureFrame(rect: rect, selected: selected)
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
        let point = convert(event.locationInWindow, from: nil)

        if activeTool != .select {
            if let location = pageLocation(at: point) {
                onAddManualField?(activeTool, location.pageIndex, location.pagePoint)
                needsDisplay = true
            }
            return
        }

        if let signatureHit = signature(at: point), let page = pdfView?.document?.page(at: signatureHit.signature.pageIndex) {
            let pagePoint = pdfView?.convert(point, to: page) ?? .zero
            signatureDrag = SignatureDrag(
                id: signatureHit.signature.id,
                pageIndex: signatureHit.signature.pageIndex,
                startBounds: signatureHit.signature.bounds,
                startPoint: pagePoint,
                mode: signatureHit.isResizeHandle ? .resize : .move
            )
            onSelectSignature?(signatureHit.signature.id)
            needsDisplay = true
            return
        }

        guard let field = field(at: point) else {
            super.mouseDown(with: event)
            return
        }

        if field.kind == .checkbox {
            onToggleCheckbox?(field.id)
        } else {
            onSelectField?(field.id)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        guard
            let signatureDrag,
            let pdfView,
            let page = pdfView.document?.page(at: signatureDrag.pageIndex)
        else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let pagePoint = pdfView.convert(point, to: page)
        let dx = pagePoint.x - signatureDrag.startPoint.x
        let dy = pagePoint.y - signatureDrag.startPoint.y

        let updatedBounds: CGRect
        switch signatureDrag.mode {
        case .move:
            updatedBounds = signatureDrag.startBounds.offsetBy(dx: dx, dy: dy)
        case .resize:
            let widthFactor = (signatureDrag.startBounds.width + dx) / max(signatureDrag.startBounds.width, 1)
            let heightFactor = (signatureDrag.startBounds.height + dy) / max(signatureDrag.startBounds.height, 1)
            let factor = min(max(max(widthFactor, heightFactor), 0.35), 2.8)
            updatedBounds = CGRect(
                x: signatureDrag.startBounds.minX,
                y: signatureDrag.startBounds.minY,
                width: max(signatureDrag.startBounds.width * factor, 48),
                height: max(signatureDrag.startBounds.height * factor, 18)
            )
        }

        onSetSignatureBounds?(signatureDrag.id, updatedBounds)
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        signatureDrag = nil
        super.mouseUp(with: event)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        if activeTool != .select, pageLocation(at: point) != nil {
            return self
        }
        if signature(at: point) != nil {
            return self
        }
        return field(at: point) == nil ? nil : self
    }

    override public func resetCursorRects() {
        super.resetCursorRects()
        if activeTool != .select {
            addCursorRect(bounds, cursor: .crosshair)
        }
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

    private func pageLocation(at point: CGPoint) -> (pageIndex: Int, pagePoint: CGPoint)? {
        guard
            let pdfView,
            let page = pdfView.page(for: point, nearest: false),
            let pageIndex = pdfView.document?.index(for: page)
        else { return nil }
        return (pageIndex, pdfView.convert(point, to: page))
    }

    private func signature(at point: CGPoint) -> SignatureHit? {
        guard let pdfView else { return nil }
        for signature in placedSignatures.reversed() {
            guard let rect = rect(pageIndex: signature.pageIndex, bounds: signature.bounds, in: pdfView) else { continue }
            let handle = resizeHandleRect(for: rect)
            if handle.insetBy(dx: -4, dy: -4).contains(point) {
                return SignatureHit(signature: signature, isResizeHandle: true)
            }
            if rect.insetBy(dx: -6, dy: -6).contains(point) {
                return SignatureHit(signature: signature, isResizeHandle: false)
            }
        }
        return nil
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

    private func drawSignatureFrame(rect: CGRect, selected: Bool) {
        let frame = rect.insetBy(dx: -2, dy: -2)
        let color = selected ? NSColor.controlAccentColor : NSColor.systemTeal
        color.withAlphaComponent(selected ? 0.95 : 0.55).setStroke()
        let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        path.lineWidth = selected ? 2 : 1
        path.stroke()

        guard selected else { return }
        let handle = resizeHandleRect(for: rect)
        color.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
    }

    private func resizeHandleRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 10, height: 10)
    }
}

private enum SignatureDragMode {
    case move
    case resize
}

private struct SignatureDrag {
    var id: UUID
    var pageIndex: Int
    var startBounds: CGRect
    var startPoint: CGPoint
    var mode: SignatureDragMode
}

private struct SignatureHit {
    var signature: PlacedSignature
    var isResizeHandle: Bool
}
