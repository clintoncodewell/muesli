import Foundation
import os

// Fork-owned (Cue coach port). OpenAI-compatible streaming chat client. Renamed with a
// Coach prefix so it never collides with anything upstream adds.

struct CoachChatMessage: Sendable {
    let role: String      // "system" | "user" | "assistant"
    let content: String
}

enum CoachLLMError: LocalizedError {
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "HTTP \(code): \(CoachLLMError.message(from: body) ?? String(body.prefix(300)))"
        case .badResponse: return "Bad response from provider"
        }
    }

    private static func message(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

/// Streams chat completions from any OpenAI-compatible endpoint (OpenAI, Groq, GLM,
/// OpenRouter, Ollama, …). Cancel the consuming task to abort a superseded generation.
struct CoachLLMClient: Sendable {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "Coach")
    let baseURL: String
    let model: String
    let apiKey: String
    var temperature: Double? = nil
    var seed: Int? = nil
    var reasoningEffort: String? = nil

    func stream(_ messages: [CoachChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let root = baseURL.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard let url = URL(string: root + "/chat/completions") else {
                        throw CoachLLMError.badResponse
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    if let temperature { body["temperature"] = temperature }
                    if let seed { body["seed"] = seed }
                    if let reasoningEffort, !reasoningEffort.isEmpty { body["reasoning_effort"] = reasoningEffort }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw CoachLLMError.badResponse }
                    guard 200 ..< 300 ~= http.statusCode else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        Self.logger.error("coach llm error \(http.statusCode): \(errBody.prefix(300), privacy: .public)")
                        throw CoachLLMError.http(http.statusCode, errBody)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(CoachStreamChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

private struct CoachStreamChunk: Decodable {
    struct Choice: Decodable { let delta: Delta }
    struct Delta: Decodable { let content: String? }
    let choices: [Choice]
}
