import Foundation

/// Talks to Lofer's backend for voice. Networking only.
///   POST /api/voice/token   → a single-use speech-to-text token (the ElevenLabs key stays on the server)
///   POST /api/voice/speech  → Lofer's line as streamed audio
struct VoiceBackendClient {
    var baseURL: URL
    /// Sent as "Authorization: Bearer …". Comes from the scheme (never committed); see VoiceConfig.
    var clientKey: String?
    var session: URLSession = .shared

    func transcriptionToken() async throws -> String {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request("api/voice/token", body: Data("{}".utf8), timeout: 10)) }
        catch { throw VoiceProblem.unavailable }
        try Self.check(response)
        struct Token: Decodable { let token: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data).token, !token.isEmpty else { throw VoiceProblem.unavailable }
        return token
    }

    func speechRequest(_ text: String) -> URLRequest {
        let body = try? JSONSerialization.data(withJSONObject: ["text": text])
        return request("api/voice/speech", body: body ?? Data(), timeout: 20)
    }

    static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw VoiceProblem.unavailable }
        if status == 401 { throw VoiceProblem.notConfigured }
        guard (200..<300).contains(status) else { throw VoiceProblem.unavailable }
    }

    private func request(_ path: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let clientKey { r.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization") }
        r.httpBody = body
        return r
    }
}
