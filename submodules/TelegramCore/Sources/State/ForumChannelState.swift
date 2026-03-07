import Foundation
import Postbox
import SGSimpleSettings
import SGDeletedMessagesStore

enum InternalAccountState {
    static func addMessages(transaction: Transaction, messages: [StoreMessage], location: AddMessagesLocation) -> [Int64 : MessageId] {
        return transaction.addMessages(messages, location: location)
    }
    
    static func deleteMessages(transaction: Transaction, ids: [MessageId], forEachMedia: ((Media) -> Void)?) {
        if SGSimpleSettings.shared.deletedMessagesHistoryEnabled {
            let now = Int32(Date().timeIntervalSince1970)
            for id in ids {
                guard let message = transaction.getMessage(id) else { continue }
                if message.attributes.contains(where: { $0 is DeletedMessageAttribute }) { continue }
                let updatedAttributes = message.attributes + [DeletedMessageAttribute(date: now)]
                transaction.updateMessage(id) { _ -> PostboxUpdateMessage in
                    return .update(StoreMessage(
                        id: message.id,
                        customStableId: nil,
                        globallyUniqueId: message.globallyUniqueId,
                        groupingKey: message.groupingKey,
                        threadId: message.threadId,
                        timestamp: message.timestamp,
                        flags: StoreMessageFlags(message.flags),
                        tags: message.tags,
                        globalTags: message.globalTags,
                        localTags: message.localTags,
                        forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                        authorId: message.author?.id,
                        text: message.text,
                        attributes: updatedAttributes,
                        media: message.media
                    ))
                }
                let chatTitle = transaction.getPeer(id.peerId)?.debugDisplayTitle ?? ""
                DeletedMessagesStore.shared.saveDeletedMessage(
                    messageId: id.id,
                    peerId: id.peerId.toInt64(),
                    authorId: message.author?.id.toInt64() ?? 0,
                    text: message.text,
                    date: message.timestamp,
                    deletedDate: now,
                    isOutgoing: !message.flags.contains(.Incoming),
                    chatTitle: chatTitle
                )
            }
            return
        }
        transaction.deleteMessages(ids, forEachMedia: forEachMedia)
    }
    
    static func invalidateChannelState(peerId: PeerId) {
        
    }
}
