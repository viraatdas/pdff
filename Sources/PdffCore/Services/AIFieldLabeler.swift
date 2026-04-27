import Foundation

public enum AIProviderChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI GPT-5.5"
        case .anthropic: "Anthropic Opus 4.7"
        }
    }

    public var modelName: String {
        switch self {
        case .openAI: "gpt-5.5"
        case .anthropic: "claude-opus-4-7"
        }
    }
}

public struct AIFieldLabeler: Sendable {
    public init() {}

    public func improveLabels(
        fields: [DetectedField],
        provider: AIProviderChoice,
        apiKey: String
    ) async throws -> [DetectedField] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIFieldLabelerError.missingAPIKey
        }

        let prompt = try makePrompt(fields: fields)
        let text: String
        switch provider {
        case .openAI:
            text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .anthropic:
            text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
        }

        let patches = try decodePatches(from: text)
        var patchedFields = fields
        for patch in patches {
            guard let index = patchedFields.firstIndex(where: { $0.id == patch.id }) else { continue }
            if let label = patch.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                patchedFields[index].label = label
            }
            if let kind = patch.kind {
                patchedFields[index].kind = kind
            }
            if let options = patch.options, !options.isEmpty {
                patchedFields[index].options = options
            }
            patchedFields[index].confidence = max(patchedFields[index].confidence, patch.confidence ?? 0.86)
            patchedFields[index].source = .ai
        }
        return patchedFields
    }

    private func makePrompt(fields: [DetectedField]) throws -> String {
        let payload = fields.map { field in
            FieldPayload(
                id: field.id.uuidString,
                pageIndex: field.pageIndex,
                kind: field.kind.rawValue,
                label: field.label,
                context: field.context
            )
        }
        let payloadData = try JSONEncoder().encode(payload)
        let payloadString = String(decoding: payloadData, as: UTF8.self)

        return """
        You label PDF form fields for a local-first Mac PDF filler. Use only the supplied text snippets.
        Return only a JSON array. Each item must be:
        {"id":"UUID","label":"short user-facing label","kind":"text|date|checkbox|choice|signature","options":["optional"],"confidence":0.0}
        Keep labels short, title case, and specific. Do not invent personal data.

        Fields:
        \(payloadString)
        """
    }

    private func callOpenAI(prompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw AIFieldLabelerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": AIProviderChoice.openAI.modelName,
            "input": prompt
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIResponsesEnvelope.self, from: data)
        if let text = decoded.outputText, !text.isEmpty { return text }
        let contentText = decoded.output?
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
        guard !contentText.isEmpty else { throw AIFieldLabelerError.emptyResponse }
        return contentText
    }

    private func callAnthropic(prompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIFieldLabelerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": AIProviderChoice.anthropic.modelName,
            "max_tokens": 2048,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(AnthropicEnvelope.self, from: data)
        let text = decoded.content.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw AIFieldLabelerError.emptyResponse }
        return text
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(800), as: UTF8.self)
            throw AIFieldLabelerError.requestFailed(http.statusCode, body)
        }
    }

    private func decodePatches(from text: String) throws -> [LabelPatch] {
        guard
            let start = text.firstIndex(of: "["),
            let end = text.lastIndex(of: "]"),
            start <= end
        else {
            throw AIFieldLabelerError.invalidJSON(text)
        }

        let json = String(text[start...end])
        let data = Data(json.utf8)
        return try JSONDecoder().decode([LabelPatch].self, from: data)
    }
}

public enum AIFieldLabelerError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case emptyResponse
    case invalidJSON(String)
    case requestFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an API key before using AI labeling."
        case .invalidURL:
            "The AI provider URL is invalid."
        case .emptyResponse:
            "The AI provider returned an empty response."
        case let .invalidJSON(text):
            "The AI provider did not return valid JSON: \(text.prefix(160))"
        case let .requestFailed(status, body):
            "The AI request failed with HTTP \(status): \(body)"
        }
    }
}

private struct FieldPayload: Encodable {
    var id: String
    var pageIndex: Int
    var kind: String
    var label: String
    var context: String
}

private struct LabelPatch: Decodable {
    var id: UUID
    var label: String?
    var kind: FieldKind?
    var options: [String]?
    var confidence: Double?
}

private struct OpenAIResponsesEnvelope: Decodable {
    var outputText: String?
    var output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    struct OutputItem: Decodable {
        var content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        var text: String?
    }
}

private struct AnthropicEnvelope: Decodable {
    var content: [ContentItem]

    struct ContentItem: Decodable {
        var text: String?
    }
}
