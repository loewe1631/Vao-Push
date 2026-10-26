import CSQLite
import Foundation

public enum SnapshotWriteResult: Equatable, Sendable { case inserted, updated, unchanged, ignoredOlder }

/// Each connection is serialized by a lock. WAL and write transactions coordinate processes.
public final class SharedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw CoreError.database("无法打开共享数据库")
        }
        do {
            sqlite3_busy_timeout(database, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                let version = try scalarInteger("PRAGMA user_version")
                guard version <= 2 else { throw CoreError.unsupportedDatabaseVersion(version) }
                if version == 0 {
                    try execute("CREATE TABLE snapshots (owner TEXT NOT NULL, stream_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner, stream_id))")
                    try execute("CREATE TABLE cards (owner TEXT NOT NULL, card_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner, card_id))")
                    try execute("CREATE TABLE interactions (owner TEXT NOT NULL, card_id TEXT NOT NULL, family TEXT NOT NULL, mode TEXT NOT NULL, PRIMARY KEY(owner, card_id, family))")
                    try execute("CREATE TABLE messages (owner TEXT NOT NULL, message_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(owner, message_id))")
                    try execute("PRAGMA user_version=1")
                }
                if version < 2 {
                    try execute("CREATE TABLE servers (connection_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                    try execute("PRAGMA user_version=2")
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    @discardableResult
    public func apply(_ snapshot: StateSnapshot, owner: String) throws -> SnapshotWriteResult {
        try ProtocolRules.validate(snapshot); try validateOwner(owner)
        return try lock.withLock { try transaction { try applyLocked(snapshot, owner: owner) } }
    }

    private func applyLocked(_ snapshot: StateSnapshot, owner: String) throws -> SnapshotWriteResult {
        let previous: StateSnapshot? = try readOne("SELECT payload FROM snapshots WHERE owner=? AND stream_id=?", [.text(owner), .text(snapshot.streamID)])
        if let previous {
            guard previous.dataID == snapshot.dataID else { throw CoreError.streamIdentityChanged }
            let current = try ProtocolRules.revision(previous.revision), incoming = try ProtocolRules.revision(snapshot.revision)
            if incoming < current { return .ignoredOlder }
            if incoming == current { guard snapshot == previous else { throw CoreError.conflictingRevision }; return .unchanged }
        }
        try execute("INSERT INTO snapshots VALUES (?,?,?) ON CONFLICT(owner,stream_id) DO UPDATE SET payload=excluded.payload", [.text(owner), .text(snapshot.streamID), .blob(try encoder.encode(snapshot))])
        return previous == nil ? .inserted : .updated
    }

    /// Read the latest local adjustments and merge within the same SQLite transaction.
    /// The App and Widget may receive a reply after the user has saved a newer edit.
    @discardableResult
    public func acceptCard(_ info: SubscribedCard, owner: String) throws -> Bool {
        try info.design.validate(); try ProtocolRules.validate(info.snapshot); try validateOwner(owner)
        return try lock.withLock {
            try transaction {
                let existing: [CardConfiguration] = try readAll("SELECT payload FROM cards WHERE owner=?", [.text(owner)])
                let matches = existing.filter { $0.remote?.id == info.cardID }
                var changed = false
                for previous in matches.isEmpty ? [CardConfiguration?.none] : matches.map(Optional.some) {
                    let card = try info.configuration(previous: previous)
                    try ProtocolRules.validate(card)
                    let write = try applyLocked(info.snapshot, owner: owner)
                    if previous != card || write != .unchanged { changed = true }
                    try execute("INSERT INTO cards VALUES (?,?,?) ON CONFLICT(owner,card_id) DO UPDATE SET payload=excluded.payload", [.text(owner), .text(card.id), .blob(try encoder.encode(card))])
                }
                return changed
            }
        }
    }

    @discardableResult
    public func markCard(_ remoteID: String, owner: String, unavailable: Bool, issue: String) throws -> Bool {
        try lock.withLock {
            try transaction {
                let all: [CardConfiguration] = try readAll("SELECT payload FROM cards WHERE owner=?", [.text(owner)])
                var changed = false
                for var card in all where card.remote?.id == remoteID {
                    let old = card
                    if unavailable { card.remote?.available = false }
                    card.remote?.issue = issue
                    if card != old {
                        changed = true
                        try execute("UPDATE cards SET payload=? WHERE owner=? AND card_id=?", [.blob(try encoder.encode(card)), .text(owner), .text(card.id)])
                    }
                }
                return changed
            }
        }
    }

    public func snapshot(streamID: String, owner: String) throws -> StateSnapshot? {
        try lock.withLock {
            try readOne("SELECT payload FROM snapshots WHERE owner=? AND stream_id=?", [.text(owner), .text(streamID)])
        }
    }

    public func snapshots(owner: String) throws -> [StateSnapshot] {
        try lock.withLock { try readAll("SELECT payload FROM snapshots WHERE owner=? ORDER BY stream_id", [.text(owner)]) }
    }

    public func save(_ card: CardConfiguration, owner: String) throws {
        try validateOwner(owner); try ProtocolRules.validate(card)
        try lock.withLock {
            try transaction {
                var updated = card
                let latest: CardConfiguration? = try readOne("SELECT payload FROM cards WHERE owner=? AND card_id=?", [.text(owner), .text(card.id)])
                if var base = latest?.remote, let edited = card.remote {
                    guard base.id == edited.id else { throw CoreError.streamIdentityChanged }
                    let oldTypes = Dictionary(uniqueKeysWithValues: edited.design.nodes.map { ($0.id, $0.type) })
                    let newTypes = Dictionary(uniqueKeysWithValues: base.design.nodes.map { ($0.id, $0.type) })
                    for (id, value) in edited.adjustments.nodes where value != NodeAdjustment() && oldTypes[id] != newTypes[id] {
                        throw CoreError.invalid("Web设计已变化，保留当前草稿；请恢复该组件跟随Web后重试。")
                    }
                    base.adjustments = edited.adjustments; updated.remote = base
                    updated.name = base.adjustments.name ?? base.design.name
                    updated.theme = CardConfiguration.Theme(rawValue: base.adjustments.theme ?? base.design.theme ?? "system")
                }
                try ProtocolRules.validate(updated)
                try execute("INSERT INTO cards VALUES (?,?,?) ON CONFLICT(owner,card_id) DO UPDATE SET payload=excluded.payload", [.text(owner), .text(card.id), .blob(try encoder.encode(updated))])
            }
        }
    }

    public func card(id: String, owner: String) throws -> CardConfiguration? {
        try lock.withLock { try readOne("SELECT payload FROM cards WHERE owner=? AND card_id=?", [.text(owner), .text(id)]) }
    }

    public func cards(owner: String) throws -> [CardConfiguration] {
        try lock.withLock { try readAll("SELECT payload FROM cards WHERE owner=? ORDER BY card_id", [.text(owner)]) }
    }

    public func deleteCard(id: String, owner: String) throws {
        try lock.withLock {
            try transaction {
                try execute("DELETE FROM cards WHERE owner=? AND card_id=?", [.text(owner), .text(id)])
                try execute("DELETE FROM interactions WHERE owner=? AND card_id=?", [.text(owner), .text(id)])
            }
        }
    }

    public func mode(cardID: String, family: String, owner: String) throws -> CardDisplayMode {
        try lock.withLock {
            let statement = try prepare("SELECT mode FROM interactions WHERE owner=? AND card_id=? AND family=?",
                                        [.text(owner), .text(cardID), .text(family)])
            defer { sqlite3_finalize(statement) }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let pointer = sqlite3_column_text(statement, 0),
                      let value = CardDisplayMode(rawValue: String(cString: pointer)) else { throw CoreError.database("交互状态无效") }
                return value
            case SQLITE_DONE: return .summary
            default: throw failure()
            }
        }
    }

    public func setMode(_ mode: CardDisplayMode, cardID: String, family: String, owner: String) throws {
        try lock.withLock {
            try execute("INSERT INTO interactions VALUES (?,?,?,?) ON CONFLICT(owner,card_id,family) DO UPDATE SET mode=excluded.mode",
                        [.text(owner), .text(cardID), .text(family), .text(mode.rawValue)])
        }
    }

    public func archive(_ message: ArchivedMessage, owner: String) throws {
        try validateOwner(owner)
        guard !message.id.isEmpty, ProtocolRules.date(message.receivedAt) != nil else { throw CoreError.invalid("无效消息身份或时间") }
        try lock.withLock {
            try execute("INSERT INTO messages VALUES (?,?,?) ON CONFLICT(owner,message_id) DO NOTHING",
                        [.text(owner), .text(message.id), .blob(try encoder.encode(message))])
        }
    }

    public func messages(owner: String) throws -> [ArchivedMessage] {
        try lock.withLock { try readAll("SELECT payload FROM messages WHERE owner=? ORDER BY rowid DESC LIMIT 100", [.text(owner)]) }
    }

    public func deleteMessage(id: String, owner: String) throws {
        try lock.withLock { try execute("DELETE FROM messages WHERE owner=? AND message_id=?", [.text(owner), .text(id)]) }
    }

    public func removeAccount(_ owner: String) throws {
        try lock.withLock {
            try transaction {
                for table in ["snapshots", "cards", "interactions", "messages"] {
                    try execute("DELETE FROM \(table) WHERE owner=?", [.text(owner)])
                }
            }
        }
    }

    public func connections() throws -> [ServerConnection] {
        try lock.withLock { try readAll("SELECT payload FROM servers ORDER BY rowid", []) }
    }

    public func saveConnection(_ connection: ServerConnection) throws {
        try connection.validate()
        try lock.withLock {
            try transaction {
                let all: [ServerConnection] = try readAll("SELECT payload FROM servers", [])
                guard !all.contains(where: { $0.id != connection.id && $0.baseURL == connection.baseURL }) else {
                    throw CoreError.invalid("该服务器已存在，可直接管理已有连接。")
                }
                if let previous = all.first(where: { $0.id == connection.id }) {
                    // Address changes must create a new connection; never carry bindings to a new host.
                    guard previous.baseURL == connection.baseURL, previous.accountID == connection.accountID,
                          previous.serverID == nil || previous.serverID == connection.serverID,
                          previous.bindingID == connection.bindingID else { throw CoreError.invalid("连接身份变化，请新增服务器并重新绑定。") }
                }
                try execute("INSERT INTO servers VALUES (?,?) ON CONFLICT(connection_id) DO UPDATE SET payload=excluded.payload",
                            [.text(connection.id), .blob(try encoder.encode(connection))])
            }
        }
    }

    public func deleteConnection(id: String) throws {
        try lock.withLock {
            try transaction {
                let connection: ServerConnection? = try readOne("SELECT payload FROM servers WHERE connection_id=?", [.text(id)])
                if let owner = connection?.owner {
                    for table in ["snapshots", "cards", "interactions", "messages"] {
                        try execute("DELETE FROM \(table) WHERE owner=?", [.text(owner)])
                    }
                }
                try execute("DELETE FROM servers WHERE connection_id=?", [.text(id)])
            }
        }
    }

    /// Only an initial pairing may attach an account to an existing connection.
    public func bindConnection(id: String, credentials: DeviceCredentials) throws {
        try lock.withLock {
            try transaction {
                guard var connection: ServerConnection = try readOne("SELECT payload FROM servers WHERE connection_id=?", [.text(id)]),
                      !connection.isDemo, connection.accountID == nil, connection.bindingID == nil,
                      connection.serverID == credentials.serverID, !credentials.accountID.isEmpty,
                      !credentials.bindingID.isEmpty else { throw CoreError.invalid("服务器身份已变化或已绑定，请重新添加。") }
                connection.accountID = credentials.accountID; connection.bindingID = credentials.bindingID
                try execute("UPDATE servers SET payload=? WHERE connection_id=?", [.blob(try encoder.encode(connection)), .text(id)])
            }
        }
    }

    public func saveSyncCursor(connectionID: String, bindingID: String, cursor: String) throws {
        try lock.withLock {
            try transaction {
                guard var connection: ServerConnection = try readOne("SELECT payload FROM servers WHERE connection_id=?", [.text(connectionID)]),
                      connection.bindingID == bindingID, connection.isEnabled else { throw CoreError.invalid("来源已停用或移除") }
                connection.messageCursor = cursor
                connection.syncedAt = ISO8601DateFormatter().string(from: .now)
                try execute("UPDATE servers SET payload=? WHERE connection_id=?", [.blob(try encoder.encode(connection)), .text(connectionID)])
            }
        }
    }

    public func clearMessages(owner: String) throws {
        try lock.withLock { try execute("DELETE FROM messages WHERE owner=?", [.text(owner)]) }
    }

    private enum Binding { case text(String), blob(Data) }

    private func validateOwner(_ owner: String) throws {
        guard !owner.isEmpty else { throw CoreError.invalid("缺少本地账号作用域") }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                guard !text.utf8.contains(0) else { sqlite3_finalize(statement); throw CoreError.invalid("身份字符串不可含空字符") }
                result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
    }

    private func readAll<T: Decodable>(_ sql: String, _ bindings: [Binding]) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var output: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0), size > 0 else { throw CoreError.database("共享数据为空") }
            output.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: size)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return output
    }

    private func readOne<T: Decodable>(_ sql: String, _ bindings: [Binding]) throws -> T? {
        try readAll(sql, bindings).first
    }

    private func scalarInteger(_ sql: String) throws -> Int {
        let statement = try prepare(sql, [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func failure() -> CoreError {
        guard let text = sqlite3_errmsg(database) else { return .database(VaoL10n.text("SQLite 操作失败")) }
        return .database(String(cString: text))
    }
}
