public import Foundation
import Logging
public import PostgresNIO

public enum Migrations {
    public static let statements: [String] = [
        "CREATE EXTENSION IF NOT EXISTS citext",
        """
        CREATE TABLE IF NOT EXISTS users (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            user_handle bytea NOT NULL UNIQUE CHECK (octet_length(user_handle) = 64),
            email citext NOT NULL UNIQUE,
            created_at timestamptz NOT NULL DEFAULT now(),
            recovered_at timestamptz
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS email_verifications (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            email citext NOT NULL,
            purpose text NOT NULL CHECK (purpose IN ('signup', 'recovery', 'email_change')),
            session_id uuid,
            client text NOT NULL CHECK (client IN ('web', 'ios')),
            token_hash bytea NOT NULL UNIQUE,
            code_hash bytea NOT NULL,
            secret_hash bytea NOT NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            verified_at timestamptz,
            verified_expires_at timestamptz,
            consumed_at timestamptz,
            invalidated_at timestamptz,
            expires_at timestamptz NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token_hash bytea NOT NULL UNIQUE,
            kind text NOT NULL CHECK (kind IN ('normal', 'recovery')),
            flow_id uuid,
            from_recovery boolean NOT NULL DEFAULT false,
            device_label text NOT NULL,
            reauthenticated_at timestamptz,
            created_at timestamptz NOT NULL DEFAULT now(),
            last_seen_at timestamptz NOT NULL DEFAULT now(),
            expires_at timestamptz NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS passkeys (
            id bytea PRIMARY KEY CHECK (octet_length(id) BETWEEN 1 AND 1023),
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            public_key bytea NOT NULL,
            alg integer NOT NULL,
            sign_count bigint NOT NULL DEFAULT 0,
            sign_count_anomaly_at timestamptz,
            aaguid uuid,
            transports text[] NOT NULL DEFAULT '{}',
            uv_initialized boolean NOT NULL,
            backup_eligible boolean NOT NULL,
            backup_state boolean NOT NULL,
            name text CHECK (name IS NULL OR length(name) BETWEEN 1 AND 64),
            created_at timestamptz NOT NULL DEFAULT now(),
            last_used_at timestamptz
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS webauthn_challenges (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            challenge bytea NOT NULL UNIQUE,
            purpose text NOT NULL CHECK (purpose IN ('signup', 'add_passkey', 'recovery', 'authentication', 'reauthentication')),
            user_id uuid REFERENCES users(id) ON DELETE CASCADE,
            session_id uuid REFERENCES sessions(id) ON DELETE CASCADE,
            flow_id uuid REFERENCES email_verifications(id) ON DELETE CASCADE,
            user_handle bytea,
            expires_at timestamptz NOT NULL,
            CHECK (
                (purpose = 'signup' AND flow_id IS NOT NULL AND user_handle IS NOT NULL)
                OR (purpose IN ('add_passkey', 'recovery', 'reauthentication') AND session_id IS NOT NULL AND user_id IS NOT NULL)
                OR (purpose = 'authentication' AND user_id IS NULL AND session_id IS NULL AND flow_id IS NULL)
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS rate_limit_counters (
            key text NOT NULL,
            window_start timestamptz NOT NULL,
            count integer NOT NULL CHECK (count >= 0),
            PRIMARY KEY (key, window_start)
        )
        """,
        "ALTER TABLE email_verifications ADD CONSTRAINT email_verifications_session_id_fkey FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE",
        "ALTER TABLE sessions ADD CONSTRAINT sessions_flow_id_fkey FOREIGN KEY (flow_id) REFERENCES email_verifications(id) ON DELETE SET NULL",
        "CREATE INDEX IF NOT EXISTS users_email_idx ON users(email)",
        "CREATE INDEX IF NOT EXISTS passkeys_user_id_idx ON passkeys(user_id)",
        "CREATE INDEX IF NOT EXISTS email_verifications_email_idx ON email_verifications(email)",
        "CREATE INDEX IF NOT EXISTS email_verifications_secret_hash_idx ON email_verifications(secret_hash)",
        "CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON sessions(user_id)",
        "CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON sessions(expires_at, last_seen_at)",
        "CREATE INDEX IF NOT EXISTS webauthn_challenges_expiry_idx ON webauthn_challenges(expires_at)",
    ]

    /// PostgreSQL does not allow adding an existing constraint with IF NOT EXISTS. These constraints
    /// are therefore only added by `migrateFresh` on an empty schema; `migrate` checks for their presence.
    public static func migrate(client: PostgresClient, logger: Logger) async throws {
        for (index, statement) in statements.enumerated() {
            if index == 7 || index == 8 {
                let constraintName = index == 7 ? "email_verifications_session_id_fkey" : "sessions_flow_id_fkey"
                let exists = try await constraintExists(constraintName, client: client, logger: logger)
                if exists { continue }
            }
            let rows = try await client.query(PostgresQuery(unsafeSQL: statement), logger: logger)
            _ = try await rows.collect()
        }
    }

    private static func constraintExists(_ name: String, client: PostgresClient, logger: Logger) async throws -> Bool {
        let rows = try await client.query(
            "SELECT count(*)::integer FROM pg_constraint WHERE conname = \(name)",
            logger: logger
        )
        for try await count in rows.decode(Int.self) {
            return count > 0
        }
        return false
    }
}
