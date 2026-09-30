// API.swift — the Aloud Remote Voice protocol, as the phone speaks it.
//
// Everything goes to the Mac through Tailscale Serve (HTTPS, tailnet only) and
// carries the device token from pairing. The Mac side is engine/remote.py.

import Foundation

struct RemoteSession: Codable, Identifiable, Hashable {
    let session_id: String
    let project: String
    let cwd: String?
    let title: String?
    let entrypoint: String
    let state: String
    let can_reply: Bool
    var id: String { session_id }

    /// "aloud — fix the flaky test", so two sessions in one project differ.
    var label: String {
        guard let t = title, !t.isEmpty else { return project }
        return "\(project) — \(t)"
    }

    var surface: String {
        switch entrypoint {
        case "cli": return "Terminal"
        case "claude-desktop", "desktop": return "Claude Desktop"
        case "claude-vscode": return "VS Code"
        default: return entrypoint
        }
    }
}

/// One spoken piece of a response: the phone highlights it while it plays.
struct Segment: Codable, Equatable {
    let text: String
    let duration: Double
}

struct RemoteEvent: Codable {
    let seq: Int
    let type: String
    let ts: Double?
    let session_id: String?
    // response
    let id: String?
    let project: String?
    let text: String?
    // clip
    let event_id: String?
    let clip: String?
    let duration: Double?
    let error: String?
    let index: Int?          // clip_part: which sentence
    let segments: [Segment]? // clip: what each part says, in order
    // reply
    let reply_id: String?
    let status: String?
    let detail: String?
    // session
    let state: String?
}

struct EventsPage: Codable {
    let events: [RemoteEvent]
    let seq: Int
    let log_id: String
    let reset: Bool
}

struct MacStatus: Codable {
    let mac: String
    let enabled: Bool
    let destination: String
    let seq: Int
    let log_id: String
}

struct ReplyRecord: Codable {
    let id: String
    let session_id: String?
    let status: String
    let error: String?
    let detail: String?
}

struct PairResponse: Codable {
    let token: String
    let device_id: String
}

private struct ErrorBody: Codable {
    let error: String
    let message: String
}

enum APIError: LocalizedError, Equatable {
    /// No answer at all: Tailscale off on either end, the Mac asleep, or no network.
    case unreachable(String)
    /// The Mac answered and said Remote Voice is turned off.
    case remoteOff
    /// The token is unknown: this phone was removed on the Mac.
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): return why
        case .remoteOff: return "Remote Voice is turned off on the Mac."
        case .unauthorized: return "This iPhone isn't paired with the Mac any more."
        case .server(let msg): return msg
        }
    }
}

final class API {
    let base: URL
    var token: String?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 40      // long polls wait up to 25s
        c.waitsForConnectivity = false        // fail fast, so the UI can say why
        return URLSession(configuration: c)
    }()

    init(base: URL, token: String?) {
        self.base = base
        self.token = token
    }

    /// Normalize what someone types: "mac.tailnet.ts.net:8443" -> https URL.
    static func serverURL(from text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if t.isEmpty { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), url.host != nil else { return nil }
        return url
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil,
                      contentType: String? = nil, headers: [String: String] = [:],
                      timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: base.absoluteString + path) else { throw APIError.server("bad address") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw APIError.unreachable(Self.explain(e))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        case 503: throw APIError.remoteOff
        default:
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            // A proxy error from Tailscale Serve means the Mac is up but Aloud isn't listening.
            if code == 502 { throw APIError.unreachable("The Mac is reachable, but Aloud isn't answering — is the engine running?") }
            throw APIError.server(msg ?? "HTTP \(code)")
        }
    }

    private static func explain(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No network connection."
        case .cannotFindHost, .dnsLookupFailed:
            return "Can't find the Mac — is Tailscale connected on this iPhone?"
        case .timedOut, .cannotConnectToHost:
            return "The Mac isn't answering — it may be asleep, or Tailscale is off on one side."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "Secure connection failed — use the https address from Tailscale Serve."
        default:
            return e.localizedDescription
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.server("Unexpected answer from the Mac.")
        }
    }

    func pair(code: String, name: String) async throws -> PairResponse {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        return try decode(PairResponse.self,
                          try await send("/v1/pair", method: "POST", body: body, contentType: "application/json"))
    }

    func status() async throws -> MacStatus {
        try decode(MacStatus.self, try await send("/v1/status"))
    }

    func sessions() async throws -> [RemoteSession] {
        struct Wrap: Codable { let sessions: [RemoteSession] }
        return try decode(Wrap.self, try await send("/v1/sessions")).sessions
    }

    func events(after: Int, logID: String?, wait: Int = 25) async throws -> EventsPage {
        var path = "/v1/events?after=\(after)&wait=\(wait)"
        if let logID { path += "&log_id=\(logID)" }
        return try decode(EventsPage.self, try await send(path, timeout: TimeInterval(wait + 15)))
    }

    func clip(_ name: String) async throws -> Data {
        try await send("/v1/clips/\(name)", timeout: 60)
    }

    func transcribe(audio: Data, locale: String?) async throws -> String {
        struct Out: Codable { let text: String }
        var headers: [String: String] = [:]
        if let locale { headers["X-Locale"] = locale }
        let data = try await send("/v1/transcribe", method: "POST", body: audio,
                                  contentType: "audio/mp4", headers: headers, timeout: 120)
        return try decode(Out.self, data).text
    }

    func reply(id: String, sessionID: String, text: String, inReplyTo: String?) async throws -> ReplyRecord {
        var obj: [String: Any] = ["reply_id": id, "session_id": sessionID, "text": text]
        if let inReplyTo { obj["in_reply_to"] = inReplyTo }
        let body = try JSONSerialization.data(withJSONObject: obj)
        return try decode(ReplyRecord.self,
                          try await send("/v1/replies", method: "POST", body: body, contentType: "application/json"))
    }
}
