import AppKit
import Foundation
import PDFKit

public enum PDFFillWriter {
    public static func exportFlattened(
        document: PDFDocument,
        fields: [DetectedField],
        signatures: [PlacedSignature],
        signatureAssets: [UUID: SignatureAsset],
        to url: URL
    ) throws {
        guard let data = document.dataRepresentation(), let workingDocument = PDFDocument(data: data) else {
            throw PDFFillWriterError.cannotCopyDocument
        }

        applyWidgetValues(fields: fields, to: workingDocument)

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFillWriterError.cannotCreateOutput
        }
        guard let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFFillWriterError.cannotCreateOutput
        }

        for pageIndex in 0..<workingDocument.pageCount {
            guard let page = workingDocument.page(at: pageIndex) else { continue }
            var mediaBox = page.bounds(for: .mediaBox)
            let mediaBoxData = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBoxData] as CFDictionary)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawOverlayFields(fields.filter { $0.pageIndex == pageIndex }, on: mediaBox)
            drawSignatures(
                signatures.filter { $0.pageIndex == pageIndex },
                signatureAssets: signatureAssets,
                on: mediaBox
            )
            NSGraphicsContext.restoreGraphicsState()

            context.endPDFPage()
        }

        context.closePDF()
    }

    private static func applyWidgetValues(fields: [DetectedField], to document: PDFDocument) {
        for field in fields where field.source == .widget {
            guard let annotation = annotation(for: field, in: document) else { continue }
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
    }

    private static func annotation(for field: DetectedField, in document: PDFDocument) -> PDFAnnotation? {
        if let fieldName = field.widgetFieldName {
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                if let annotation = page.annotations.first(where: { $0.fieldName == fieldName }) {
                    return annotation
                }
            }
        }

        guard let page = document.page(at: field.pageIndex) else { return nil }
        return page.annotations.first { annotation in
            annotation.type == PDFAnnotationSubtype.widget.rawValue && annotation.bounds.intersects(field.bounds)
        }
    }

    private static func drawOverlayFields(_ fields: [DetectedField], on mediaBox: CGRect) {
        for field in fields where field.source != .widget {
            switch field.kind {
            case .checkbox:
                drawCheckbox(field)
            case .signature:
                continue
            case .text, .date, .choice:
                let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                drawText(trimmed, in: field.bounds.intersection(mediaBox))
            }
        }
    }

    private static func drawText(_ text: String, in bounds: CGRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let insetBounds = bounds.insetBy(dx: 2, dy: 2)
        let fontSize = PDFFieldTextSizer.exportFontSize(for: text, in: bounds)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let textHeight = (text as NSString).size(withAttributes: attributes).height
        let y = insetBounds.midY - textHeight / 2
        (text as NSString).draw(
            in: CGRect(x: insetBounds.minX, y: y, width: insetBounds.width, height: textHeight + 4),
            withAttributes: attributes
        )
    }

    private static func drawCheckbox(_ field: DetectedField) {
        guard field.boolValue else { return }
        let bounds = field.bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.lineWidth = 1.8
        NSColor.labelColor.setStroke()
        path.stroke()
    }

    private static func drawSignatures(
        _ signatures: [PlacedSignature],
        signatureAssets: [UUID: SignatureAsset],
        on mediaBox: CGRect
    ) {
        for placed in signatures {
            guard
                let asset = signatureAssets[placed.assetID],
                let image = NSImage(data: asset.pngData)
            else { continue }

            let bounds = placed.bounds.intersection(mediaBox)
            guard bounds.width > 1, bounds.height > 1 else { continue }
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

}

public enum PDFFillWriterError: LocalizedError {
    case cannotCopyDocument
    case cannotCreateOutput

    public var errorDescription: String? {
        switch self {
        case .cannotCopyDocument:
            "The PDF could not be prepared for export."
        case .cannotCreateOutput:
            "The destination PDF could not be created."
        }
    }
}
