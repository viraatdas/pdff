import CoreGraphics
import Foundation

public enum FieldKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case date
    case checkbox
    case choice
    case signature

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .date: "Date"
        case .checkbox: "Checkbox"
        case .choice: "Choice"
        case .signature: "Signature"
        }
    }
}

public enum FieldSource: String, Codable, Hashable, Sendable {
    case widget
    case pattern
    case ai
    case user

    public var displayName: String {
        switch self {
        case .widget: "PDF form"
        case .pattern: "Detected"
        case .ai: "AI labeled"
        case .user: "Manual"
        }
    }
}

public struct DetectedField: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var bounds: CGRect
    public var kind: FieldKind
    public var label: String
    public var source: FieldSource
    public var confidence: Double
    public var options: [String]
    public var value: String
    public var boolValue: Bool
    public var widgetFieldName: String?
    public var context: String

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        bounds: CGRect,
        kind: FieldKind,
        label: String,
        source: FieldSource,
        confidence: Double,
        options: [String] = [],
        value: String = "",
        boolValue: Bool = false,
        widgetFieldName: String? = nil,
        context: String = ""
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.kind = kind
        self.label = label
        self.source = source
        self.confidence = confidence
        self.options = options
        self.value = value
        self.boolValue = boolValue
        self.widgetFieldName = widgetFieldName
        self.context = context
    }

    public var isFilled: Bool {
        switch kind {
        case .checkbox:
            boolValue
        case .signature:
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text, .date, .choice:
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public extension FieldKind {
    static func inferred(from label: String) -> FieldKind {
        let normalized = label.lowercased()
        if normalized.contains("signature") || normalized.contains("sign here") || normalized.contains("initial") {
            return .signature
        }
        if normalized.contains("date") || normalized.contains("dob") || normalized.contains("birth") {
            return .date
        }
        return .text
    }
}
