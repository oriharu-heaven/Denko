import Foundation
import Network

/// Tiny HTTP endpoint on 127.0.0.1 so anything local can post to the board:
/// Claude Code hooks, shell scripts, Shortcuts ("Get Contents of URL"), cron jobs…
///
///   POST http://127.0.0.1:<port>/notify/<token>?source=claude-code   (body: hook JSON)
///   POST http://127.0.0.1:<port>/notify/<token>?title=Build%20done   (body: optional text)
///
/// The random token keeps web pages in the browser from posting to it.
@MainActor
final class LocalNotifyServer {
    private let hub: NotificationHub
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    let token: String
    /// Plain posts from scripts / Shortcuts (設定 → 情報連携 → Webhook). Coding agents are always accepted.
    var acceptsWebhook = true

    init(hub: NotificationHub) {
        self.hub = hub
        let d = UserDefaults.standard
        if let t = d.string(forKey: "notifyToken"), t.count >= 16 {
            token = t
        } else {
            token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            d.set(token, forKey: "notifyToken")
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)/notify/\(token)" }

    func start(port: UInt16) {
        stop()
        self.port = port
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handle(conn) }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let request = Self.parse(buf) {
                    let status = self.route(request)
                    self.respond(conn, status: status)
                } else if isComplete || error != nil || buf.count > 256 * 1024 {
                    self.respond(conn, status: 400)
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, status: Int) {
        let text = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 403 ? "Forbidden" : "Bad Request"
        let resp = "HTTP/1.1 \(status) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return Request(method: String(parts[0]), path: comps?.path ?? "", query: query,
                       body: Data(body.prefix(length)))
    }

    private func route(_ r: Request) -> Int {
        guard r.method == "POST" || r.method == "GET", r.path == "/notify/\(token)" else { return 404 }
        let source = r.query["source"] ?? ""
        let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]

        if source == "claude-code" || json?["hook_event_name"] != nil {
            postClaudeCode(json ?? [:])
            return 200
        }
        if source == "codex" {
            postCodex(json ?? [:])
            return 200
        }
        // Any other coding agent: ?source=agent&agent=Gemini&event=waiting|done[&title=…]
        if source == "agent" || r.query["event"] != nil {
            postAgent(name: r.query["agent"] ?? json?["agent"] as? String,
                      event: r.query["event"] ?? json?["event"] as? String ?? "done",
                      title: r.query["title"] ?? json?["title"] as? String,
                      project: r.query["project"] ?? json?["cwd"] as? String)
            return 200
        }
        guard acceptsWebhook else { return 403 }
        let bodyText = String(decoding: r.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = r.query["title"] ?? json?["title"] as? String ?? (bodyText.isEmpty ? nil : bodyText)
        guard let title, !title.isEmpty else { return 400 }
        let body = r.query["body"] ?? json?["message"] as? String ?? json?["body"] as? String
        let url = (r.query["url"] ?? json?["url"] as? String).flatMap(URL.init(string:))
        let priority = (r.query["priority"] ?? json?["priority"] as? String)?.lowercased()
        let urgent = ["high", "urgent", "important"].contains(priority ?? "")
        hub.post(.webhook, kind: .webhook, title: title, body: body == title ? nil : body, url: url, urgent: urgent)
        return 200
    }

    /// Maps Claude Code hook payloads (Notification / Stop / …) to board messages.
    private func postClaudeCode(_ j: [String: Any]) {
        let project = (j["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let where_ = project.map { "（\($0)）" } ?? ""
        switch j["hook_event_name"] as? String {
        case "Notification":
            let raw = j["message"] as? String ?? "通知があります"
            // Waiting for input / permission needs the user: make it stand out.
            hub.post(.claudeCode, kind: .claudeWaiting, title: "\(Self.translate(raw))\(where_)")
        case "Stop":
            // The answer is ready and Claude is waiting on the user: worth the whole bar.
            hub.post(.claudeCode, kind: .claudeDone, title: "応答が完了しました\(where_)")
        case "SubagentStop":
            hub.post(.claudeCode, kind: .claudeDone, title: "サブエージェントが完了しました\(where_)")
        case let other?:
            hub.post(.claudeCode, title: "\(other)\(where_)")
        case nil:
            hub.post(.claudeCode, title: "通知があります\(where_)")
        }
    }

    /// Codex `notify` payload: {"type": "agent-turn-complete", "cwd": …, "last-assistant-message": …}.
    private func postCodex(_ j: [String: Any]) {
        let project = (j["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let where_ = project.map { "（\($0)）" } ?? ""
        let type = j["type"] as? String ?? ""
        if type.contains("approval") || type.contains("input") {
            hub.post(.codex, kind: .claudeWaiting, title: "許可を求めています\(where_)")
        } else {
            hub.post(.codex, kind: .claudeDone, title: "作業が完了しました\(where_)",
                     body: (j["last-assistant-message"] as? String).map { String($0.prefix(120)) })
        }
    }

    /// Generic coding agent (Gemini CLI, Antigravity, Cursor … via their own hooks / scripts).
    private func postAgent(name: String?, event: String, title: String?, project: String?) {
        let source: TickerSource = name?.lowercased().contains("gemini") == true ? .gemini : .agent
        let who = source == .agent ? (name.map { "\($0)：" } ?? "") : ""
        let where_ = project.map { "（\(URL(fileURLWithPath: $0).lastPathComponent)）" } ?? ""
        let waiting = ["waiting", "permission", "input", "approval"].contains { event.lowercased().contains($0) }
        hub.post(source, kind: waiting ? .claudeWaiting : .claudeDone,
                 title: who + (title ?? (waiting ? "許可を求めています" : "作業が完了しました")) + where_)
    }

    private static func translate(_ s: String) -> String {
        if s.localizedCaseInsensitiveContains("waiting for your input") { return "入力待ちです" }
        if s.localizedCaseInsensitiveContains("needs your permission") {
            if let r = s.range(of: "to use ") { return "\(s[r.upperBound...]) の許可を求めています" }
            return "許可を求めています"
        }
        return s
    }
}
