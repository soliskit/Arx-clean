//
//  BridgeServer.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import HTTPTypes
import Hummingbird
import Logging

public struct BridgeConfiguration: Sendable {
  public let origin: String
  public let host: String
  public let port: Int
  public init(origin: String, port: Int = 8765) throws {
    guard let url = URL(string: origin), url.scheme == "https", let host = url.host,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/", (1024...65535).contains(port),
      !host.contains(":"), !host.contains("localhost"), host != "127.0.0.1"
    else { throw BridgeFailure.invalid }
    let portSuffix = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
    let authority = host.lowercased() + portSuffix
    self.origin = "https://" + authority
    self.host = authority
    self.port = port
  }
}

public struct BridgeServer: Sendable {
  private static let webContentTypes: [String: String] = [
    "/": "text/html; charset=utf-8",
    "/app.js": "text/javascript; charset=utf-8",
    "/apple-touch-icon.png": "image/png",
    "/favicon-32.png": "image/png",
    "/favicon.svg": "image/svg+xml",
    "/logic.js": "text/javascript; charset=utf-8",
    "/style.css": "text/css; charset=utf-8",
  ]
  let sharing: SharingController
  public let configuration: BridgeConfiguration
  public init(sharing: SharingController, configuration: BridgeConfiguration) {
    self.sharing = sharing
    self.configuration = configuration
  }
  public func application(onRunning: @escaping @Sendable () async -> Void = {})
    -> some ApplicationProtocol
  {
    let router = Router()
    router.add(middleware: EnvelopeMiddleware(server: self))
    for path in Self.webContentTypes.keys.sorted() + ["/api/session", "/api/lists"] {
      router.get(RouterPath(path)) { request, _ in await handle(request) }
    }
    for path in ["/api/pair", "/api/read", "/api/mutate"] {
      router.post(RouterPath(path)) { request, _ in await handle(request) }
    }
    var logger = Logger(label: "ArxBridge")
    logger.logLevel = .critical  // no request/body/auth data in routine logs
    return Application(
      router: router,
      configuration: .init(
        address: .hostname("127.0.0.1", port: configuration.port), backlog: 32, reuseAddress: true),
      onServerRunning: { _ in await onRunning() }, logger: logger)
  }
  public func run(onRunning: @escaping @Sendable () async -> Void = {}) async throws {
    try await application(onRunning: onRunning).runService()
  }
  private struct PairRequest: Decodable { var secret: String }
  private struct ReadRequest: Decodable {
    var listID: String
    var after: String?
    var before: String?
  }
  private struct SessionResponse: Encodable {
    var rights: ClientRights
    var csrf: String
  }
  private struct ErrorResponse: Encodable {
    var error: String
    var code: String
    var writeOutcome: WriteOutcome
  }
  private struct WriteResponse: Encodable { var reminder: SharedReminder? }
  private func header(_ name: String, _ request: Request) -> String? {
    guard let field = HTTPField.Name(name) else { return nil }
    return request.headers[field]
  }
  private func handle(_ request: Request) async -> Response {
    do {
      let path = request.uri.path
      if request.method == .get, let contentType = Self.webContentTypes[path] {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard
          let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Web"),
          let data = try? Data(contentsOf: url)
        else { throw BridgeFailure.unavailable }
        return response(.ok, data: data, contentType: contentType)
      }
      if path == "/api/pair" {
        let pair: PairRequest = try await decode(request)
        let state = try await sharing.exchange(pair.secret)
        var result = try json(
          SessionResponse(
            rights: try await sharing.sessionState(state.token).rights, csrf: state.csrf))
        result.headers[.setCookie] =
          "__Host-arx=\(state.token); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=86400"
        return result
      }
      let cookies =
        header("Cookie", request)?.split(separator: ";").map {
          $0.trimmingCharacters(in: .whitespaces)
        } ?? []
      let matching = cookies.filter { $0.hasPrefix("__Host-arx=") }
      guard matching.count == 1 else { throw BridgeFailure.denied }
      let token = String(matching[0].dropFirst("__Host-arx=".count))
      if path == "/api/session" {
        let state = try await sharing.sessionState(token)
        return try json(SessionResponse(rights: state.rights, csrf: state.csrf))
      }
      if path == "/api/lists" { return try json(try await sharing.sharedLists(token)) }
      // Read is POST so list identifiers don't enter access-log URLs/history.
      if path == "/api/read" {
        guard header("X-CSRF-Token", request) == (try await sharing.sessionState(token)).csrf else {
          throw BridgeFailure.denied
        }
        let input: ReadRequest = try await decode(request)
        return try json(
          try await sharing.read(
            token, list: input.listID, after: input.after, before: input.before))
      }
      if path == "/api/mutate" {
        try await sharing.authorizeMutationEnvelope(
          token, csrf: header("X-CSRF-Token", request) ?? "")
        let command: Mutation = try await decode(request, limit: 1_048_576)
        return try json(
          WriteResponse(
            reminder: try await sharing.mutate(
              token, csrf: header("X-CSRF-Token", request) ?? "", command: command)))
      }
      throw BridgeFailure.denied
    } catch { return failureResponse(error) }
  }
  private func validateEnvelope(_ request: Request) throws {
    guard request.head.authority?.lowercased() == configuration.host,
      header("Host", request) == nil,
      header("X-Forwarded-Proto", request) == "https",
      request.uri.query == nil
    else { throw BridgeFailure.denied }
    if let origin = header("Origin", request), origin != configuration.origin {
      throw BridgeFailure.denied
    }
    if request.method == .post {
      guard header("Origin", request) == configuration.origin,
        header("Content-Type", request)?.lowercased() == "application/json"
      else { throw BridgeFailure.denied }
    }
  }
  private struct EnvelopeMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let server: BridgeServer
    func handle(
      _ request: Request, context: Context,
      next: (Request, Context) async throws -> Response
    ) async throws -> Response {
      var result: Response
      do {
        try server.validateEnvelope(request)
        result = try await next(request, context)
      } catch let error as any HTTPResponseError {
        result = try error.response(from: request, context: context)
      } catch {
        result = server.failureResponse(error)
      }
      for field in server.securityHeaders() { result.headers[field.name] = field.value }
      return result
    }
  }
  private func failureResponse(_ error: any Error) -> Response {
    let status: HTTPResponse.Status
    let message: String
    let writeFailure = error as? WriteFailure
    let failure = writeFailure?.failure ?? (error as? BridgeFailure)
    switch failure ?? .denied {
    case BridgeFailure.conflict:
      status = .conflict
      message = "This reminder changed. Refresh and review before trying again."
    case BridgeFailure.invalid:
      status = .badRequest
      message = "Check the fields and confirmation."
    case BridgeFailure.ambiguous:
      status = .conflict
      message =
        "Result uncertain. Refresh and check Reminders. Do not repeat this operation blindly."
    case BridgeFailure.tooLarge:
      status = .contentTooLarge
      message =
        "This request exceeds its body limit (64 KiB for pairing/reads; 1 MiB for changes)."
    case BridgeFailure.sessionFull:
      status = .tooManyRequests
      message =
        "This session reached its 500-write limit. Pair again from the Mac app to continue writing."
    case BridgeFailure.rateLimited:
      status = .tooManyRequests
      message = "Requests temporarily limited. Try later."
    case BridgeFailure.unavailable:
      status = .serviceUnavailable
      message = "The store or bridge is unavailable."
    default:
      status = .forbidden
      message = "Access unavailable. Refresh or pair again."
    }
    return
      (try? json(
        ErrorResponse(
          error: message, code: failure.map { String(describing: $0) } ?? "unavailable",
          writeOutcome: writeFailure?.outcome ?? .unknown), status: status))
      ?? response(.internalServerError, data: Data())
  }
  private func decode<T: Decodable>(_ request: Request, limit: Int = 65_536) async throws -> T {
    let body: ByteBuffer
    do {
      body = try await request.body.collect(upTo: limit)
    } catch {
      if let error = error as? any HTTPResponseError, error.status == .contentTooLarge {
        throw BridgeFailure.tooLarge
      }
      throw error
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // A body that does not parse is a bad request, not a lost session.
    do { return try decoder.decode(T.self, from: Data(body.readableBytesView)) } catch {
      throw BridgeFailure.invalid
    }
  }
  private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response
  {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return response(status, data: try encoder.encode(value))
  }
  private func response(
    _ status: HTTPResponse.Status, data: Data, contentType: String = "application/json"
  ) -> Response {
    var fields = securityHeaders()
    fields[.contentType] = contentType
    return Response(status: status, headers: fields, body: .init(byteBuffer: .init(bytes: data)))
  }
  private func securityHeaders() -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in [
      ("Cache-Control", "no-store"),
      ("X-Content-Type-Options", "nosniff"),
      (
        "Content-Security-Policy",
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
      ),
      ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
    ] { fields[HTTPField.Name(name)!] = value }
    return fields
  }
}
