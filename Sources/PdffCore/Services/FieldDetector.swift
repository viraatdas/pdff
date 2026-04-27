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

    public static func refinedBounds(for field: DetectedField, as kind: FieldKind, in document: PDFDocument) -> CGRect? {
        guard
            let page = document.page(at: field.pageIndex),
            let text = page.string,
            !text.isEmpty
        else { return nil }

        let candidates = PDFPatternScanner.scan(text).compactMap { candidate -> RefinementCandidate? in
            guard let selection = page.selection(for: candidate.fillRange) else { return nil }
            let rawBounds = normalized(selection.bounds(for: page))
            let existingBounds = candidate.isLabelOnly
                ? fieldBoundsToRightOfLabel(candidate.kind, labelBounds: rawBounds, page: page)
                : fieldBounds(for: candidate.kind, rawBounds: rawBounds)
            let refinedBounds = candidate.isLabelOnly
                ? fieldBoundsToRightOfLabel(kind, labelBounds: rawBounds, page: page)
                : fieldBounds(for: kind, rawBounds: rawBounds)
            guard refinedBounds.width > 2, refinedBounds.height > 2 else { return nil }
            let score = refinementScore(field: field, candidate: candidate, existingBounds: existingBounds)
            return RefinementCandidate(bounds: refinedBounds, score: score)
        }

        guard let best = candidates.max(by: { $0.score < $1.score }), best.score >= 24 else {
            return nil
        }
        return best.bounds
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
            bounds = candidate.isLabelOnly
                ? fieldBoundsToRightOfLabel(candidate.kind, labelBounds: bounds, page: page)
                : fieldBounds(for: candidate.kind, rawBounds: bounds)
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
                confidence: candidate.isLabelOnly ? 0.58 : (candidate.kind == .checkbox ? 0.82 : 0.74),
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

    private static func fieldBoundsToRightOfLabel(_ kind: FieldKind, labelBounds: CGRect, page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let height = max(labelBounds.height + 6, 18)
        let minimumWidth: CGFloat = kind == .signature ? 160 : 90
        let preferredWidth: CGFloat = kind == .signature ? 220 : 180
        let x = labelBounds.maxX + 8
        let maxX = pageBounds.maxX - 36
        let availableWidth = maxX - x
        guard availableWidth >= minimumWidth else { return .zero }

        let width = min(max(availableWidth, minimumWidth), preferredWidth)
        return CGRect(
            x: x,
            y: labelBounds.midY - height / 2,
            width: width,
            height: kind == .signature ? max(height, 34) : height
        )
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

    private static func refinementScore(
        field: DetectedField,
        candidate: PatternCandidate,
        existingBounds: CGRect
    ) -> Double {
        let centerDistance = hypot(existingBounds.midX - field.bounds.midX, existingBounds.midY - field.bounds.midY)
        let verticalDistance = abs(existingBounds.midY - field.bounds.midY)
        let overlap = overlapRatio(existingBounds, field.bounds)
        let labelScore = labelSimilarity(candidate.label, field.label)
        let contextScore = contextSimilarity(candidate.context, field.context)

        var score = labelScore + contextScore + overlap * 140 + max(0, 90 - centerDistance * 0.8)
        if verticalDistance > 72, overlap < 0.04, labelScore < 35 {
            score -= 80
        }
        return score
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        guard lhs.intersects(rhs) else { return 0 }
        let intersection = lhs.intersection(rhs)
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else { return 0 }
        return Double((intersection.width * intersection.height) / smallerArea)
    }

    private static func labelSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedLabel(lhs)
        let right = normalizedLabel(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 80 }
        if left.contains(right) || right.contains(left) { return 48 }
        return 0
    }

    private static func contextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedLabel(lhs)
        let right = normalizedLabel(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 32 }
        if left.contains(right) || right.contains(left) { return 18 }
        return 0
    }

    private static func normalizedLabel(_ label: String) -> String {
        label
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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

private struct RefinementCandidate {
    var bounds: CGRect
    var score: Double
}
