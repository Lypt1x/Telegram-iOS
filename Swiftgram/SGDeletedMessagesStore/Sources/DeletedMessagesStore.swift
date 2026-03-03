import Foundation
import sqlcipher
import SGAppGroupIdentifier
import SGLogging

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DeletedMessage {
    public let id: Int64
    public let messageId: Int32
    public let peerId: Int64
    public let authorId: Int64
    public let text: String
    public let date: Int32
    public let deletedDate: Int32
    public let isOutgoing: Bool
    public let chatTitle: String

    public init(
        id: Int64,
        messageId: Int32,
        peerId: Int64,
        authorId: Int64,
        text: String,
        date: Int32,
        deletedDate: Int32,
        isOutgoing: Bool,
        chatTitle: String
    ) {
        self.id = id
        self.messageId = messageId
        self.peerId = peerId
        self.authorId = authorId
        self.text = text
        self.date = date
        self.deletedDate = deletedDate
        self.isOutgoing = isOutgoing
        self.chatTitle = chatTitle
    }
}

public final class DeletedMessagesStore {
    public static let shared = DeletedMessagesStore()

    private let queue = DispatchQueue(label: "app.swiftgram.deleted-messages-store", qos: .utility)
    private var db: OpaquePointer?

    private init() {
        self.openDatabase()
    }

    deinit {
        if let db = self.db {
            sqlite3_close(db)
        }
    }

    private func databasePath() -> String? {
        let groupId = sgAppGroupIdentifier()
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            SGLogger.shared.log("DeletedMessagesStore", "Failed to get shared container for group: \(groupId)")
            return nil
        }
        let dirURL = containerURL.appendingPathComponent("telegram-data/deleted-messages")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL.appendingPathComponent("deleted_messages.sqlite").path
    }

    private func openDatabase() {
        guard let path = databasePath() else { return }
        if sqlite3_open(path, &self.db) != SQLITE_OK {
            SGLogger.shared.log("DeletedMessagesStore", "Failed to open database at \(path)")
            self.db = nil
            return
        }
        self.createTableIfNeeded()
    }

    private func createTableIfNeeded() {
        guard let db = self.db else { return }
        let sql = """
            CREATE TABLE IF NOT EXISTS deleted_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                messageId INTEGER NOT NULL,
                peerId INTEGER NOT NULL,
                authorId INTEGER NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                date INTEGER NOT NULL,
                deletedDate INTEGER NOT NULL,
                isOutgoing INTEGER NOT NULL DEFAULT 0,
                chatTitle TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_deleted_messages_peerId ON deleted_messages(peerId);
            CREATE INDEX IF NOT EXISTS idx_deleted_messages_deletedDate ON deleted_messages(deletedDate);
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let err = errMsg.map { String(cString: $0) } ?? "unknown"
            SGLogger.shared.log("DeletedMessagesStore", "Failed to create table: \(err)")
            sqlite3_free(errMsg)
        }
    }

    public func saveDeletedMessage(
        messageId: Int32,
        peerId: Int64,
        authorId: Int64,
        text: String,
        date: Int32,
        deletedDate: Int32,
        isOutgoing: Bool,
        chatTitle: String
    ) {
        self.queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = "INSERT INTO deleted_messages (messageId, peerId, authorId, text, date, deletedDate, isOutgoing, chatTitle) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                SGLogger.shared.log("DeletedMessagesStore", "Failed to prepare insert statement")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, messageId)
            sqlite3_bind_int64(stmt, 2, Int64(peerId))
            sqlite3_bind_int64(stmt, 3, Int64(authorId))
            text.withCString { ptr in
                sqlite3_bind_text(stmt, 4, ptr, -1, SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(stmt, 5, date)
            sqlite3_bind_int(stmt, 6, deletedDate)
            sqlite3_bind_int(stmt, 7, isOutgoing ? 1 : 0)
            chatTitle.withCString { ptr in
                sqlite3_bind_text(stmt, 8, ptr, -1, SQLITE_TRANSIENT)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                SGLogger.shared.log("DeletedMessagesStore", "Failed to insert deleted message \(messageId)")
            }
        }
    }

    public func getDeletedMessages(forPeerId peerId: Int64?) -> [DeletedMessage] {
        return self.queue.sync { [weak self] () -> [DeletedMessage] in
            guard let self = self, let db = self.db else { return [] }
            var messages: [DeletedMessage] = []

            let sql: String
            if peerId != nil {
                sql = "SELECT id, messageId, peerId, authorId, text, date, deletedDate, isOutgoing, chatTitle FROM deleted_messages WHERE peerId = ? ORDER BY deletedDate DESC"
            } else {
                sql = "SELECT id, messageId, peerId, authorId, text, date, deletedDate, isOutgoing, chatTitle FROM deleted_messages ORDER BY deletedDate DESC"
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                SGLogger.shared.log("DeletedMessagesStore", "Failed to prepare select statement")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            if let peerId = peerId {
                sqlite3_bind_int64(stmt, 1, peerId)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let msg = DeletedMessage(
                    id: sqlite3_column_int64(stmt, 0),
                    messageId: sqlite3_column_int(stmt, 1),
                    peerId: sqlite3_column_int64(stmt, 2),
                    authorId: sqlite3_column_int64(stmt, 3),
                    text: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                    date: sqlite3_column_int(stmt, 5),
                    deletedDate: sqlite3_column_int(stmt, 6),
                    isOutgoing: sqlite3_column_int(stmt, 7) != 0,
                    chatTitle: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                )
                messages.append(msg)
            }
            return messages
        }
    }

    public func clearAll() {
        self.queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM deleted_messages", nil, nil, nil)
        }
    }

    public func clearForPeer(peerId: Int64) {
        self.queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM deleted_messages WHERE peerId = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, peerId)
            sqlite3_step(stmt)
        }
    }
}
