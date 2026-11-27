import API
import Core
import Foundation
import Hummingbird
import Logging
import Persistence
public import PostgresNIO

@main
struct PasskeyServerMain {
    static func main() async throws {
        LoggingSystem.bootstrap { label in JSONLogHandler(label: label) }
        var initialLogger = Logger(label: "passkey.server")
        initialLogger.logLevel = .info
        let logger = initialLogger
        let configuration = try ServerConfiguration.load()
        let command = CommandLine.arguments.dropFirst().first ?? "serve"
        let postgresClient = PostgresClient(configuration: configuration.postgresConfiguration)
        let store = PostgresAuthStore(client: postgresClient, logger: logger)

        switch command {
        case "serve":
            let sender: any MailSender = configuration.mailgun.map { MailgunMailSender(configuration: $0) as any MailSender } ?? NullMailSender()
            if configuration.mailgun == nil {
                logger.warning("mailgun_not_configured", metadata: ["effect": "mail is dropped"])
            }
            let core = AuthCore(
                store: store,
                configuration: configuration.auth,
                mailQueue: MailQueue(sender: sender, logger: logger),
                logger: logger
            )
            let router = APIBuilder(core: core).router()
            let app = Application(
                router: router,
                configuration: .init(address: .hostname(configuration.host, port: configuration.port)),
                logger: logger
            )
            try await withPostgresClient(postgresClient) {
                try await app.runService()
            }

        case "migrate":
            try await withPostgresClient(postgresClient) {
                try await Migrations.migrate(client: postgresClient, logger: logger)
                logger.info("migration_completed")
            }

        case "cleanup":
            let sender: any MailSender = configuration.mailgun.map { MailgunMailSender(configuration: $0) as any MailSender } ?? NullMailSender()
            let core = AuthCore(
                store: store,
                configuration: configuration.auth,
                mailQueue: MailQueue(sender: sender, logger: logger),
                logger: logger
            )
            try await withPostgresClient(postgresClient) {
                let counts = try await core.cleanupExpiredRecords()
                logger.info(
                    "cleanup_completed",
                    metadata: [
                        "challenges": "\(counts.challenges)",
                        "email_verifications": "\(counts.emailVerifications)",
                        "sessions": "\(counts.sessions)",
                        "rate_limit_counters": "\(counts.rateLimitCounters)",
                    ]
                )
            }

        default:
            throw ValidationError("unknown command '\(command)'; expected serve, migrate, or cleanup")
        }
    }

    private static func withPostgresClient(_ client: PostgresClient, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await operation() }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

struct ValidationError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}


struct JSONLogHandler: LogHandler {
    let label: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    var metadataProvider: Logger.MetadataProvider?

    init(label: String) {
        self.label = label
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let eventMetadata = event.metadata {
            for (key, value) in eventMetadata { merged[key] = value }
        }
        if let providerMetadata = metadataProvider?.get() {
            for (key, value) in providerMetadata { merged[key] = value }
        }

        var fields: [(String, String)] = [
            ("severity", jsonString(cloudLoggingSeverity(event.level))),
            ("message", jsonString(event.message.description)),
            ("logger", jsonString(label)),
            ("source", jsonString(event.source)),
            ("file", jsonString(event.file)),
            ("function", jsonString(event.function)),
            ("line", String(event.line)),
        ]
        for (key, value) in merged.sorted(by: { $0.key < $1.key }) {
            fields.append((key, jsonMetadataValue(value)))
        }
        if let error = event.error {
            fields.append(("error", jsonString(String(describing: error))))
        }
        let body = "{" + fields.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",") + "}\n"
        if let data = body.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private func cloudLoggingSeverity(_ level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }

    private func jsonMetadataValue(_ value: Logger.Metadata.Value) -> String {
        switch value {
        case .string(let value): return jsonString(value)
        case .stringConvertible(let value): return jsonString(value.description)
        case .array(let values): return "[" + values.map(jsonMetadataValue).joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            return "{" + dictionary.sorted(by: { $0.key < $1.key }).map { "\(jsonString($0.key)):\(jsonMetadataValue($0.value))" }.joined(separator: ",") + "}"
        }
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}
