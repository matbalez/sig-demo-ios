// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import SQLCipher

/// GRDB connections belong to the SQLCipher image. Keep this C call in the
/// framework that links SQLCipher, even when the app also embeds plain SQLite.
public enum SigDemoSQLCipherBridge {
    @discardableResult
    @inline(never)
    public static func cacheFlush(_ connection: OpaquePointer) -> Int32 {
        SQLCipher.sqlite3_db_cacheflush(connection)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// An explicit diagnostic uses only a new, private in-memory connection.
    /// It never obtains the account database or its encryption key.
    public static func qualifyInMemoryDatabase() -> Bool {
        do {
            let queue = try DatabaseQueue(path: ":memory:")
            defer { try? queue.close() }
            return try queue.inDatabase { database in
                guard let version = try String.fetchOne(database, sql: "PRAGMA cipher_version"),
                      !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let connection = database.sqliteConnection else { return false }
                try database.execute(sql: "CREATE TABLE sig_demo_sqlcipher_probe (value INTEGER NOT NULL)")
                try database.execute(sql: "INSERT INTO sig_demo_sqlcipher_probe (value) VALUES (1)")
                return cacheFlush(connection) == SQLCipher.SQLITE_OK
            }
        } catch {
            return false
        }
    }
    #endif
}
