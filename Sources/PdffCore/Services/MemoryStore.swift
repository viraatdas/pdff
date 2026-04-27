import Combine
import Foundation

@MainActor
public final class MemoryStore: ObservableObject {
    @Published public private(set) var values: [String: String] = [:]

    private let account = "profile-memory"

    public init() {
        do {
            values = try KeychainJSONStore.load([String: String].self, account: account) ?? [:]
        } catch {
            values = [:]
        }
    }

    public func suggestions(for label: String) -> [String] {
        let key = Self.normalizedLabel(label)
        if let exact = values[key], !exact.isEmpty {
            return [exact]
        }

        return values.compactMap { storedKey, storedValue in
            guard !storedValue.isEmpty else { return nil }
            if key.contains(storedKey) || storedKey.contains(key) {
                return storedValue
            }
            return nil
        }
        .prefix(3)
        .map { $0 }
    }

    public func remember(_ field: DetectedField) {
        guard field.kind == .text || field.kind == .date || field.kind == .choice else { return }
        let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        values[Self.normalizedLabel(field.label)] = trimmed
        persist()
    }

    public func clear() {
        values = [:]
        persist()
    }

    nonisolated public static func normalizedLabel(_ label: String) -> String {
        let scalars = label.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func persist() {
        try? KeychainJSONStore.save(values, account: account)
    }
}
