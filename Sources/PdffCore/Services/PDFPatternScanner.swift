import Foundation

public struct PatternCandidate: Equatable {
    public var fullRange: NSRange
    public var fillRange: NSRange
    public var kind: FieldKind
    public var label: String
    public var context: String

    public init(fullRange: NSRange, fillRange: NSRange, kind: FieldKind, label: String, context: String) {
        self.fullRange = fullRange
        self.fillRange = fillRange
        self.kind = kind
        self.label = label
        self.context = context
    }
}

public enum PDFPatternScanner {
    public static func scan(_ text: String) -> [PatternCandidate] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return [] }

        var candidates: [PatternCandidate] = []
        candidates.append(contentsOf: scanLabelledBlanks(in: nsText, fullRange: fullRange))
        candidates.append(contentsOf: scanCheckboxes(in: nsText, fullRange: fullRange))
        candidates.append(contentsOf: scanStandaloneBlanks(in: nsText, fullRange: fullRange, existing: candidates))

        return candidates
            .sorted { $0.fillRange.location < $1.fillRange.location }
            .uniquedByFillRange()
    }

    private static func scanLabelledBlanks(in nsText: NSString, fullRange: NSRange) -> [PatternCandidate] {
        let pattern = #"(?im)([A-Za-z][A-Za-z0-9 /,&.'()#-]{0,56})\s*[:\-]?\s*(_{3,}|\.{4,})"#
        return matches(pattern: pattern, in: nsText, range: fullRange).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let label = cleanLabel(nsText.substring(with: match.range(at: 1)))
            let fillRange = match.range(at: 2)
            let finalLabel = label.isEmpty ? labelBefore(fillRange, in: nsText) : label
            return PatternCandidate(
                fullRange: match.range,
                fillRange: fillRange,
                kind: FieldKind.inferred(from: finalLabel),
                label: finalLabel.isEmpty ? "Field" : finalLabel,
                context: context(around: match.range, in: nsText)
            )
        }
    }

    private static func scanCheckboxes(in nsText: NSString, fullRange: NSRange) -> [PatternCandidate] {
        let pattern = #"(?im)(\x{2610}|\[\s?\]|\(\s?\))\s*([A-Za-z][^\n]{1,56})"#
        return matches(pattern: pattern, in: nsText, range: fullRange).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let label = cleanLabel(nsText.substring(with: match.range(at: 2)))
            return PatternCandidate(
                fullRange: match.range,
                fillRange: match.range(at: 1),
                kind: .checkbox,
                label: label.isEmpty ? "Checkbox" : label,
                context: context(around: match.range, in: nsText)
            )
        }
    }

    private static func scanStandaloneBlanks(
        in nsText: NSString,
        fullRange: NSRange,
        existing: [PatternCandidate]
    ) -> [PatternCandidate] {
        let pattern = #"(?m)(_{5,}|\.{6,})"#
        return matches(pattern: pattern, in: nsText, range: fullRange).compactMap { match in
            guard !existing.contains(where: { NSIntersectionRange($0.fillRange, match.range).length > 0 }) else {
                return nil
            }

            let label = labelBefore(match.range, in: nsText)
            return PatternCandidate(
                fullRange: match.range,
                fillRange: match.range,
                kind: FieldKind.inferred(from: label),
                label: label.isEmpty ? "Field" : label,
                context: context(around: match.range, in: nsText)
            )
        }
    }

    private static func matches(pattern: String, in nsText: NSString, range: NSRange) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: nsText as String, options: [], range: range)
    }

    private static func labelBefore(_ range: NSRange, in nsText: NSString) -> String {
        let lineRange = nsText.lineRange(for: NSRange(location: max(0, range.location - 1), length: 0))
        let start = lineRange.location
        let length = max(0, range.location - start)
        guard length > 0 else { return "" }
        let prefix = nsText.substring(with: NSRange(location: start, length: min(length, 72)))
        return cleanLabel(prefix)
    }

    private static func cleanLabel(_ raw: String) -> String {
        let withoutFillers = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let collapsed = withoutFillers
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return collapsed
            .trimmingCharacters(in: CharacterSet(charactersIn: " :-,.;()[]{}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func context(around range: NSRange, in nsText: NSString) -> String {
        let start = max(0, range.location - 120)
        let end = min(nsText.length, range.location + range.length + 120)
        guard end > start else { return "" }
        return nsText.substring(with: NSRange(location: start, length: end - start))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

private extension Array where Element == PatternCandidate {
    func uniquedByFillRange() -> [PatternCandidate] {
        var result: [PatternCandidate] = []
        for candidate in self {
            let overlaps = result.contains { existing in
                NSIntersectionRange(existing.fillRange, candidate.fillRange).length > 0
            }
            if !overlaps {
                result.append(candidate)
            }
        }
        return result
    }
}
