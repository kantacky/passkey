import Core
public import Foundation
public import PostgresNIO

struct ServerConfiguration: Sendable {
    var auth: AuthConfiguration
    var host: String
    var port: Int
    var databaseHost: String
    var databasePort: Int
    var databaseName: String
    var databaseUser: String
    var databasePassword: String?
    var mailgun: MailgunConfiguration?

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfiguration {
        let rpID = environment["RP_ID"] ?? "localhost"
        let origin = environment["ORIGIN"] ?? "https://\(rpID)"
        let mailgun: MailgunConfiguration?
        if let apiKey = environment["MAILGUN_API_KEY"], !apiKey.isEmpty,
           let domain = environment["MAILGUN_DOMAIN"], !domain.isEmpty {
            mailgun = MailgunConfiguration(
                apiKey: apiKey,
                domain: domain,
                apiBaseURL: environment["MAILGUN_API_BASE_URL"] ?? "https://api.mailgun.net",
                from: environment["MAIL_FROM"] ?? "no-reply@mail.\(rpID)"
            )
        } else {
            mailgun = nil
        }
        return ServerConfiguration(
            auth: AuthConfiguration(rpID: rpID, origin: origin),
            host: environment["HOST"] ?? "0.0.0.0",
            port: Int(environment["PORT"] ?? "8080") ?? 8080,
            databaseHost: environment["DATABASE_HOST"] ?? "127.0.0.1",
            databasePort: Int(environment["DATABASE_PORT"] ?? "5432") ?? 5432,
            databaseName: environment["DATABASE_NAME"] ?? "passkey",
            databaseUser: environment["DATABASE_USER"] ?? "passkey",
            databasePassword: environment["DATABASE_PASSWORD"],
            mailgun: mailgun
        )
    }

    var postgresConfiguration: PostgresClient.Configuration {
        var configuration = PostgresClient.Configuration(
            host: databaseHost,
            port: databasePort,
            username: databaseUser,
            password: databasePassword,
            database: databaseName,
            tls: .disable
        )
        configuration.options.maximumConnections = 10
        return configuration
    }
}
