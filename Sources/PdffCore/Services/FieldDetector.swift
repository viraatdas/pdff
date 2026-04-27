import Foundation
import PDFKit

public enum FieldDetector {
    public static func detect(in document: PDFDocument) -> [DetectedField] {
        var fields: [DetectedField] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            fields.append(contentsOf: detectWidgets(on: page, pageIndex: pageIndex))
            fields.append(contentsOf: detectTextPatterns(on: page, pageIndex: pageIndex, existing: fields))
        }

        return fields
            .sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                let dy = abs($0.bounds.midY - $1.bounds.midY)
                if dy > 8 { return $0.bounds.midY > $1.bounds.midY }
                return $0.bounds.minX < $1.bounds.minX
            }
    }

    private static func detectWidgets(on page: PDFPage, pageIndex: Int) -> [DetectedField] {
        page.annotations.compactMap { annotation in
            guard annotation.type == PDFAnnotationSubtype.widget.rawValue else { return nil }

            let label = cleanWidgetLabel(annotation.fieldName) ?? "Field"
            let widgetType = annotation.widgetFieldType
            let kind: FieldKind
            var options: [String] = []

            switch widgetType {
            case .button:
                kind = annotation.widgetControlType == .checkBoxControl ? .checkbox : .choice
            case .choice:
                kind = .choice
                options = annotation.choices ?? []
            case .signature:
                kind = .signature
            case .text:
                kind = FieldKind.inferred(from: label)
            default:
                kind = FieldKind.inferred(from: label)
            }

            return DetectedField(
                pageIndex: pageIndex,
                bounds: normalized(annotation.bounds),
                kind: kind,
                label: label,
                source: .widget,
                confidence: 1.0,
                options: options,
                value: annotation.widgetStringValue ?? "",
                boolValue: annotation.buttonWidgetStateString.lowercased() == "yes",
                widgetFieldName: annotation.fieldName,
                context: label
            )
        }
    }

    private static func detectTextPatterns(
        on page: PDFPage,
        pageIndex: Int,
        existing: [DetectedField]
    ) -> [DetectedField] {
        guard let text = page.string, !text.isEmpty else { return [] }

        return PDFPatternScanner.scan(text).compactMap { candidate in
            guard let selection = page.selection(for: candidate.fillRange) else { return nil }
            var bounds = normalized(selection.bounds(for: page))
            bounds = fieldBounds(for: candidate.kind, rawBounds: bounds)
            guard bounds.width > 2, bounds.height > 2 else { return nil }
            guard !existing.contains(where: { $0.pageIndex == pageIndex && overlaps($0.bounds, bounds) }) else {
                return nil
            }

            return DetectedField(
                pageIndex: pageIndex,
                bounds: bounds,
                kind: candidate.kind,
                label: candidate.label,
                source: .pattern,
                confidence: candidate.kind == .checkbox ? 0.82 : 0.74,
                context: candidate.context
            )
        }
    }

    private static func fieldBounds(for kind: FieldKind, rawBounds: CGRect) -> CGRect {
        switch kind {
        case .checkbox:
            let side = max(rawBounds.width, rawBounds.height, 10)
            return CGRect(x: rawBounds.minX, y: rawBounds.minY, width: side, height: side).insetBy(dx: -1, dy: -1)
        case .signature:
            return rawBounds.insetBy(dx: -3, dy: -8)
        case .text, .date, .choice:
            let height = max(rawBounds.height + 8, 18)
            return CGRect(
                x: rawBounds.minX,
                y: rawBounds.midY - height / 2,
                width: max(rawBounds.width, 80),
                height: height
            )
        }
    }

    private static func normalized(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: abs(rect.width), height: abs(rect.height))
    }

    private static func overlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard lhs.intersects(rhs) else { return false }
        let intersection = lhs.intersection(rhs)
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else { return false }
        return (intersection.width * intersection.height) / smallerArea > 0.25
    }

    private static func cleanWidgetLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
