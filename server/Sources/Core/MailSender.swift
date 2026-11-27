public import AsyncHTTPClient
public import Foundation
public import Logging
import NIOCore
import NIOHTTP1

public struct MailMessage: Sendable, Equatable {
    public var to: String
    public var subject: String
    public var text: String

    public init(to: String, subject: String, text: String) {
        self.to = to
        self.subject = subject
        self.text = text
    }
}

public protocol MailSender: Sendable {
    func send(_ message: MailMessage) async throws
}

public struct NullMailSender: MailSender {
    public init() {}
    public func send(_ message: MailMessage) async throws {}
}

public struct MailgunConfiguration: Sendable {
    public var apiKey: String
    public var domain: String
    public var apiBaseURL: String
    public var from: String

    public init(apiKey: String, domain: String, apiBaseURL: String, from: String) {
        self.apiKey = apiKey
        self.domain = domain
        self.apiBaseURL = apiBaseURL
        self.from = from
    }
}

public struct MailgunMailSender: MailSender {
    private let configuration: MailgunConfiguration
    private let client: HTTPClient

    public init(configuration: MailgunConfiguration, client: HTTPClient = .shared) {
        self.configuration = configuration
        self.client = client
    }

    public func send(_ message: MailMessage) async throws {
        var request = HTTPClientRequest(url: "\(configuration.apiBaseURL)/v3/\(configuration.domain)/messages")
        request.method = .POST
        let credentials = Data("api:\(configuration.apiKey)".utf8).base64EncodedString()
        request.headers.add(name: "authorization", value: "Basic \(credentials)")
        request.headers.add(name: "content-type", value: "application/x-www-form-urlencoded")
        let fields = [
            "from": configuration.from,
            "to": message.to,
            "subject": message.subject,
            "text": message.text,
            "o:tracking": "no",
            "o:tracking-clicks": "no",
            "o:tracking-opens": "no",
        ]
        let body = fields
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .sorted()
            .joined(separator: "&")
        request.body = .bytes(Array(body.utf8))
        let response = try await client.execute(request, timeout: .seconds(10))
        _ = try await response.body.collect(upTo: 1024 * 1024)
        guard (200..<300).contains(Int(response.status.code)) else {
            throw MailgunError.unexpectedStatus(Int(response.status.code))
        }
    }

    private func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "+", with: "%2B") ?? value
    }
}

public enum MailgunError: Error {
    case unexpectedStatus(Int)
}

public actor MailQueue {
    private let sender: any MailSender
    private let logger: Logger

    public init(sender: any MailSender, logger: Logger) {
        self.sender = sender
        self.logger = logger
    }

    public func enqueue(_ message: MailMessage) {
        let logger = logger
        let sender = sender
        Task {
            await Self.sendWithRetry(sender: sender, message: message, logger: logger)
        }
    }

    public func sendNow(_ message: MailMessage) async {
        await Self.sendWithRetry(sender: sender, message: message, logger: logger)
    }

    private static func sendWithRetry(sender: any MailSender, message: MailMessage, logger: Logger) async {
        for attempt in 0..<3 {
            do {
                try await sender.send(message)
                return
            } catch {
                if attempt == 2 {
                    logger.error(
                        "mail_final_failure",
                        metadata: ["error": "\(String(describing: error))", "subject": "\(message.subject)"]
                    )
                } else {
                    let nanos = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
    }
}
