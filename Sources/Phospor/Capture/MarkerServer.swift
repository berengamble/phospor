import Foundation
import Network

/// Lightweight localhost-only HTTP server that accepts marker events from
/// external tools (like Claude Code hooks). Uses `NWListener` from
/// Network.framework — no external dependencies.
///
/// Protocol:
///   POST /marker
///   Body: {"event": "claude_start"|"claude_stop"|"speech_start"|"speech_end"|"manual",
///          "label": "...",       // optional, defaults to event name
///          "ts": "..."}          // optional ISO-8601 or Unix epoch; defaults to now
///
/// Responds 200 on success, 400 on bad request, 405 on wrong method/path.
final class MarkerServer: @unchecked Sendable {
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "phospor.markerserver")
  private let markerStore: MarkerStore

  /// The port the server is listening on, or nil if not started.
  private(set) var port: UInt16?

  /// Fixed well-known port so Claude Code HTTP hooks can target a static URL.
  /// If this port is busy, falls back to a random available port.
  static let preferredPort: UInt16 = 19850

  /// Well-known file where the port is written so hooks can discover it.
  static let portFilePath: String = {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Phospor", isDirectory: true)
    return support.appendingPathComponent("marker-port").path
  }()

  init(markerStore: MarkerStore) {
    self.markerStore = markerStore
  }

  /// Start listening on localhost. Tries the well-known port first, then
  /// falls back to a random available port.
  func start() throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback),
      port: NWEndpoint.Port(rawValue: Self.preferredPort) ?? .any
    )

    let l = try NWListener(using: params)
    l.stateUpdateHandler = { [weak self] state in
      if case .ready = state, let port = l.port {
        self?.port = port.rawValue
        self?.writePortFile(port.rawValue)
        NSLog("[phospor] marker server listening on 127.0.0.1:\(port.rawValue)")
      }
    }
    l.newConnectionHandler = { [weak self] conn in
      self?.handleConnection(conn)
    }
    l.start(queue: queue)
    listener = l
  }

  func stop() {
    listener?.cancel()
    listener = nil
    port = nil
    removePortFile()
    NSLog("[phospor] marker server stopped")
  }

  // MARK: - Connection handling

  private func handleConnection(_ conn: NWConnection) {
    conn.start(queue: queue)
    // Read up to 64 KB — more than enough for a marker POST.
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, _, error in
      defer { conn.cancel() }
      guard let self, let data, error == nil else { return }

      let response = self.processHTTP(data)
      conn.send(content: response, completion: .contentProcessed { _ in })
    }
  }

  private func processHTTP(_ data: Data) -> Data {
    guard let raw = String(data: data, encoding: .utf8) else {
      return httpResponse(status: 400, body: "bad request")
    }

    // Minimal HTTP parsing: first line is "METHOD /path HTTP/1.x"
    let lines = raw.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      return httpResponse(status: 400, body: "bad request")
    }
    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else {
      return httpResponse(status: 400, body: "bad request")
    }

    let method = parts[0]
    let path = parts[1]

    guard method == "POST", path == "/marker" else {
      return httpResponse(status: 405, body: "use POST /marker")
    }

    // Body starts after the first blank line.
    guard let bodyRange = raw.range(of: "\r\n\r\n") else {
      return httpResponse(status: 400, body: "no body")
    }
    let bodyStr = String(raw[bodyRange.upperBound...])

    guard let bodyData = bodyStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    else {
      return httpResponse(status: 400, body: "invalid JSON body")
    }

    // Accept our own format {"event": "claude_start", ...} OR Claude Code's
    // hook format {"hook_event_name": "UserPromptSubmit", ...}.
    let kind: Marker.Kind
    if let eventStr = json["event"] as? String, let k = Marker.Kind(rawValue: eventStr) {
      kind = k
    } else if let hookName = json["hook_event_name"] as? String {
      switch hookName {
      case "UserPromptSubmit": kind = .claudeStart
      case "Stop": kind = .claudeStop
      default:
        return httpResponse(status: 400, body: "unknown hook_event_name: \(hookName)")
      }
    } else {
      return httpResponse(
        status: 400,
        body: "expected 'event' or 'hook_event_name' field"
      )
    }

    // Label: use explicit "label", or Claude Code's "prompt" (truncated), or the event name.
    let label: String
    if let l = json["label"] as? String {
      label = l
    } else if let prompt = json["prompt"] as? String {
      let truncated = prompt.prefix(80)
      label = truncated.count < prompt.count ? "\(truncated)..." : String(truncated)
    } else {
      label = kind.rawValue
    }

    if let ts = json["ts"] as? String {
      markerStore.add(kind: kind, label: label, externalTimestamp: ts)
    } else {
      markerStore.add(kind: kind, label: label)
    }

    return httpResponse(status: 200, body: "ok")
  }

  private func httpResponse(status: Int, body: String) -> Data {
    let statusText: String
    switch status {
    case 200: statusText = "OK"
    case 400: statusText = "Bad Request"
    case 405: statusText = "Method Not Allowed"
    default: statusText = "Error"
    }
    let resp =
      "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    return Data(resp.utf8)
  }

  // MARK: - Port file

  private func writePortFile(_ port: UInt16) {
    let dir = (Self.portFilePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    try? "\(port)".write(toFile: Self.portFilePath, atomically: true, encoding: .utf8)
  }

  private func removePortFile() {
    try? FileManager.default.removeItem(atPath: Self.portFilePath)
  }
}
