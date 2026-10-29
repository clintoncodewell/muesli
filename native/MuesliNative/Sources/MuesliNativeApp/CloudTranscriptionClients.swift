import Foundation

enum CloudTranscriptionError: LocalizedError {
    case missingConfiguration(String)
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let message): return message
        case .invalidResponse: return "The transcription service returned an invalid response."
        case .requestFailed(let status, let message):
            return "Transcription request failed (HTTP \(status)): \(message)"
        }
    }
}

private enum MultipartFormData {
    static func make(
        fields: [(String, String)],
        fileField: String,
        fileURL: URL
    ) throws -> (body: Data, contentType: String) {
        let boundary = "Muesli-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}

struct ElevenLabsSpeechToTextClient: Sendable {
    private struct Response: Decodable {
        let text: String
        let words: [Word]?
    }

    private struct Word: Decodable {
        let text: String
        let start: Double?
        let end: Double?
        let speakerId: String?

        enum CodingKeys: String, CodingKey {
            case text, start, end
            case speakerId = "speaker_id"
        }
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(fileURL: URL, apiKey: String, keyterms: [String]) async throws -> SpeechTranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CloudTranscriptionError.missingConfiguration("Add your ElevenLabs API key in Settings before using Scribe.")
        }
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var fields = [
            ("model_id", "scribe_v2"),
            ("diarize", "true"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "true"),
        ]
        for term in Array(keyterms.prefix(100)) where !term.isEmpty {
            fields.append(("keyterms", term))
        }
        let multipart = try MultipartFormData.make(fields: fields, fileField: "file", fileURL: fileURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = multipart.body
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudTranscriptionError.requestFailed(http.statusCode, Self.errorMessage(from: data))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Self.result(from: decoded)
    }

    private static func result(from response: Response) -> SpeechTranscriptionResult {
        let timedWords = (response.words ?? []).filter { $0.start != nil && $0.end != nil }
        let speakers = Set(timedWords.compactMap(\.speakerId))
        guard speakers.count > 1 else {
            let segments = timedWords.map {
                SpeechSegment(start: $0.start ?? 0, end: $0.end ?? 0, text: $0.text)
            }
            return SpeechTranscriptionResult(text: response.text, segments: segments)
        }

        var grouped: [(speaker: String, start: Double, end: Double, text: String)] = []
        for word in timedWords {
            let speaker = word.speakerId ?? "speaker_0"
            if let last = grouped.indices.last, grouped[last].speaker == speaker {
                grouped[last].end = word.end ?? grouped[last].end
                grouped[last].text += word.text
            } else {
                grouped.append((speaker, word.start ?? 0, word.end ?? 0, word.text))
            }
        }
        let speakerOrder = Dictionary(uniqueKeysWithValues: speakers.sorted().enumerated().map { ($1, $0 + 1) })
        let segments = grouped.map { group in
            let label = "Speaker \(speakerOrder[group.speaker] ?? 1)"
            return SpeechSegment(start: group.start, end: group.end, text: "\(label): \(group.text.trimmingCharacters(in: .whitespaces))")
        }
        return SpeechTranscriptionResult(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
        }
        return object["detail"] as? String ?? object["message"] as? String ?? "Unknown error"
    }
}

struct OpenAICompatibleSpeechToTextClient: Sendable {
    private struct Response: Decodable {
        struct Segment: Decodable { let start: Double; let end: Double; let text: String }
        let text: String
        let segments: [Segment]?
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(fileURL: URL, endpoint: String, apiKey: String, model: String) async throws -> SpeechTranscriptionResult {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw CloudTranscriptionError.missingConfiguration("Enter a valid Qwen3-ASR transcription endpoint in Settings.")
        }
        let multipart = try MultipartFormData.make(
            fields: [("model", model), ("response_format", "verbose_json")],
            fileField: "file",
            fileURL: fileURL
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = multipart.body
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
            throw CloudTranscriptionError.requestFailed(http.statusCode, message)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return SpeechTranscriptionResult(
            text: decoded.text,
            segments: (decoded.segments ?? []).map { SpeechSegment(start: $0.start, end: $0.end, text: $0.text) }
        )
    }
}
