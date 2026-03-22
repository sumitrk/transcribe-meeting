import Foundation

struct ClaudeClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let claudeModel = "claude-sonnet-4-5"

    // MARK: - Summarise

    func summarise(transcript: String, apiKey: String) async throws -> SummariseResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let prompt = """
        You are a meeting assistant. Clean up the following raw transcript (fix grammar, \
        remove filler words, preserve meaning) and produce a structured summary.

        Return ONLY a JSON object with exactly these two fields:
        {
          "cleaned_transcript": "<cleaned up transcript as plain text>",
          "summary": "<markdown with ## Topics, ## Decisions, ## Next Steps sections>"
        }

        Raw transcript:
        \(transcript)
        """

        let body: [String: Any] = [
            "model": claudeModel,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClaudeError.apiError(msg)
        }

        // Unwrap the Anthropic response envelope
        let envelope = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = envelope.content.first?.text else {
            throw ClaudeError.emptyResponse
        }

        // Claude returns a JSON object — decode it
        if let jsonData = text.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(SummariseResponse.self, from: jsonData) {
            return parsed
        }

        // Fallback: use raw text as cleaned transcript, no summary
        return SummariseResponse(cleaned_transcript: text, summary: "")
    }
}

// MARK: - Response types

struct SummariseResponse: Decodable {
    let cleaned_transcript: String
    let summary: String
}

private struct ClaudeResponse: Decodable {
    struct ContentBlock: Decodable { let text: String }
    let content: [ContentBlock]
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case apiError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Claude API error: \(msg)"
        case .emptyResponse:     return "Claude returned an empty response"
        }
    }
}
