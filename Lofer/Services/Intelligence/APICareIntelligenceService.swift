import Foundation

/// Where Care Intelligence comes from in this build.
///
///   local    on-device only (no network)
///   backend  Lofer's backend (POST /api/care). In this phase that's the LOCAL Lofer backend
///            running MockCareIntelligenceProvider, not an external LLM.
///
/// Choose with launch arguments (Xcode: Product › Scheme › Edit Scheme › Arguments):
///   -LoferIntelligence local|backend      (default: backend in Debug builds, local otherwise)
///   -LoferBackendURL http://127.0.0.1:8787
///   -LoferClientKey …   (or LOFER_CLIENT_KEY) when the backend requires one. Set it only in your
///                       local scheme (Edit Scheme › Run › Environment Variables); never commit it.
/// If the backend can't be reached, CareFlowModel falls back to the on-device service.
struct CareIntelligenceConfig: Equatable {
    enum Mode: String { case local, backend }
    var mode: Mode
    var backendURL: URL
    var timeout: TimeInterval = 25        // an LLM turn takes a few seconds; after this the app falls back on-device
    var clientKey: String? = nil          // sent as "Authorization: Bearer …" to the backend

    static let defaultBackendURL = URL(string: "http://127.0.0.1:8787")!

    static func fromLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments,
                                    environment env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        func value(_ name: String) -> String? {
            if let i = args.firstIndex(of: "-\(name)"), i + 1 < args.count { return args[i + 1] }
            return env[name.uppercased()]
        }
        #if DEBUG
        let fallbackMode = Mode.backend
        #else
        let fallbackMode = Mode.local
        #endif
        let mode = value("LoferIntelligence").flatMap(Mode.init(rawValue:)) ?? fallbackMode
        let url = value("LoferBackendURL").flatMap(URL.init(string:)) ?? defaultBackendURL
        let key = value("LoferClientKey") ?? env["LOFER_CLIENT_KEY"]
        return .init(mode: mode, backendURL: url, clientKey: key.flatMap { $0.isEmpty ? nil : $0 })
    }

    func makeService() -> CareIntelligenceService {
        mode == .backend ? APICareIntelligenceService(baseURL: backendURL, timeout: timeout, clientKey: clientKey) : LocalCareIntelligenceService()
    }
}

/// Why a backend call failed. The care flow never shows these: it falls back.
enum CareIntelligenceError: Error, Equatable {
    case unavailable(String)          // no connection, refused, timed out
    case badStatus(Int)               // the backend answered with an error
    case malformed(String)            // not valid JSON for the schema
    case schemaMismatch(Int)          // a different schema version
    case mismatchedRequest            // an answer to a different request (stale or duplicated)
}

/// Talks to Lofer's backend. Networking only: no care logic lives here.
struct APICareIntelligenceService: CareIntelligenceService {
    var baseURL: URL
    var timeout: TimeInterval = 25
    var clientKey: String? = nil
    var session: URLSession = .shared

    func respond(to request: CareRequest) async throws -> CareIntelligenceResponse {
        var http = URLRequest(url: baseURL.appendingPathComponent("api/care"), timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let clientKey { http.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization") }
        http.httpBody = try CareSchema.encoder().encode(request)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: http) }
        catch { throw CareIntelligenceError.unavailable(error.localizedDescription) }

        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CareIntelligenceError.unavailable("No HTTP response") }
        guard (200..<300).contains(status) else { throw CareIntelligenceError.badStatus(status) }

        let decoded: CareIntelligenceResponse
        do { decoded = try CareSchema.decoder().decode(CareIntelligenceResponse.self, from: data) }
        catch { throw CareIntelligenceError.malformed(String(describing: error).prefix(200).description) }

        guard decoded.schemaVersion == CareSchema.version else { throw CareIntelligenceError.schemaMismatch(decoded.schemaVersion) }
        guard decoded.requestId == request.requestId else { throw CareIntelligenceError.mismatchedRequest }
        return decoded
    }
}
