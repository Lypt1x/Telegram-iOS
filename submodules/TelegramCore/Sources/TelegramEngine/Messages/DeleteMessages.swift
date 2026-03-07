import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import SGSimpleSettings
import SGDeletedMessagesStore

func addMessageMediaResourceIdsToRemove(media: Media, resourceIds: inout [MediaResourceId]) {
    if let image = media as? TelegramMediaImage {
        for representation in image.representations {
            resourceIds.append(representation.resource.id)
        }
    } else if let file = media as? TelegramMediaFile {
        for representation in file.previewRepresentations {
            resourceIds.append(representation.resource.id)
        }
        resourceIds.append(file.resource.id)
    }
}

func addMessageMediaResourceIdsToRemove(message: Message, resourceIds: inout [MediaResourceId]) {
    for media in message.media {
        addMessageMediaResourceIdsToRemove(media: media, resourceIds: &resourceIds)
    }
}

struct RemoteDeleteMessagesResult {
    let isPreserved: Bool
    let displayAlerts: [String]
}

private func storeMessage(_ message: Message, with attributes: [MessageAttribute]) -> StoreMessage {
    return StoreMessage(
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
        attributes: attributes,
        media: message.media
    )
}

private func deletedMessagesAlertText(chatTitle: String, count: Int) -> String {
    let resolvedChatTitle = chatTitle.isEmpty ? "this chat" : chatTitle
    if count == 1 {
        return "A message was deleted in \(resolvedChatTitle)."
    } else {
        return "\(count) messages were deleted in \(resolvedChatTitle)."
    }
}

private func saveDeletedMessage(transaction: Transaction, message: Message, id: MessageId, deletedDate: Int32) {
    let chatTitle = transaction.getPeer(id.peerId)?.debugDisplayTitle ?? ""
    DeletedMessagesStore.shared.saveDeletedMessage(
        messageId: id.id,
        peerId: id.peerId.toInt64(),
        authorId: message.author?.id.toInt64() ?? 0,
        text: message.text,
        date: message.timestamp,
        deletedDate: deletedDate,
        isOutgoing: !message.flags.contains(.Incoming),
        chatTitle: chatTitle
    )
}

public func _internal_deleteMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId], deleteMedia: Bool = true, manualAddMessageThreadStatsDifference: ((MessageThreadKey, Int, Int) -> Void)? = nil) {
    var resourceIds: [MediaResourceId] = []
    if deleteMedia {
        for id in ids {
            if id.peerId.namespace == Namespaces.Peer.SecretChat {
                if let message = transaction.getMessage(id) {
                    addMessageMediaResourceIdsToRemove(message: message, resourceIds: &resourceIds)
                }
            }
        }
    }
    if !resourceIds.isEmpty {
        let _ = mediaBox.removeCachedResources(Array(Set(resourceIds)), force: true).start()
    }
    for id in ids {
        if id.peerId.namespace == Namespaces.Peer.CloudChannel && id.namespace == Namespaces.Message.Cloud {
            if let message = transaction.getMessage(id) {
                if let threadId = message.threadId {
                    let messageThreadKey = MessageThreadKey(peerId: message.id.peerId, threadId: threadId)
                    if id.peerId.namespace == Namespaces.Peer.CloudChannel {
                        if let manualAddMessageThreadStatsDifference = manualAddMessageThreadStatsDifference {
                            manualAddMessageThreadStatsDifference(messageThreadKey, 0, 1)
                        } else {
                            updateMessageThreadStats(transaction: transaction, threadKey: messageThreadKey, removedCount: 1, addedMessagePeers: [])
                        }
                    }
                }
            }
        }
    }
    transaction.deleteMessages(ids, forEachMedia: { _ in
    })
}

func _internal_handleRemoteDeletedMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId], manualAddMessageThreadStatsDifference: ((MessageThreadKey, Int, Int) -> Void)? = nil) -> RemoteDeleteMessagesResult {
    guard SGSimpleSettings.shared.deletedMessagesHistoryEnabled else {
        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids, manualAddMessageThreadStatsDifference: manualAddMessageThreadStatsDifference)
        return RemoteDeleteMessagesResult(isPreserved: false, displayAlerts: [])
    }

    let now = Int32(Date().timeIntervalSince1970)
    var seenIds = Set<MessageId>()
    var groupedCounts: [PeerId: Int] = [:]
    var groupedTitles: [PeerId: String] = [:]
    var orderedPeerIds: [PeerId] = []

    for id in ids {
        if !seenIds.insert(id).inserted {
            continue
        }
        guard let message = transaction.getMessage(id) else {
            continue
        }
        if message.attributes.contains(where: { $0 is DeletedMessageAttribute }) {
            continue
        }

        transaction.updateMessage(id) { _ -> PostboxUpdateMessage in
            var updatedAttributes = message.attributes
            if updatedAttributes.contains(where: { $0 is DeletedMessageAttribute }) {
                return .skip
            }
            updatedAttributes.append(DeletedMessageAttribute(date: now))
            return .update(storeMessage(message, with: updatedAttributes))
        }

        let chatTitle = transaction.getPeer(id.peerId)?.debugDisplayTitle ?? ""
        if groupedCounts[id.peerId] == nil {
            groupedCounts[id.peerId] = 0
            groupedTitles[id.peerId] = chatTitle
            orderedPeerIds.append(id.peerId)
        }
        groupedCounts[id.peerId, default: 0] += 1

        saveDeletedMessage(transaction: transaction, message: message, id: id, deletedDate: now)
    }

    return RemoteDeleteMessagesResult(
        isPreserved: true,
        displayAlerts: orderedPeerIds.compactMap { peerId -> String? in
            guard let count = groupedCounts[peerId] else {
                return nil
            }
            return deletedMessagesAlertText(chatTitle: groupedTitles[peerId] ?? "", count: count)
        }
    )
}

func _internal_deleteAllMessagesWithAuthor(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, authorId: PeerId, namespace: MessageId.Namespace) {
    var resourceIds: [MediaResourceId] = []
    transaction.removeAllMessagesWithAuthor(peerId, authorId: authorId, namespace: namespace, forEachMedia: { media in
        addMessageMediaResourceIdsToRemove(media: media, resourceIds: &resourceIds)
    })
    if !resourceIds.isEmpty {
        let _ = mediaBox.removeCachedResources(Array(Set(resourceIds))).start()
    }
}

func _internal_deleteAllMessagesWithForwardAuthor(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, forwardAuthorId: PeerId, namespace: MessageId.Namespace) {
    var resourceIds: [MediaResourceId] = []
    transaction.removeAllMessagesWithForwardAuthor(peerId, forwardAuthorId: forwardAuthorId, namespace: namespace, forEachMedia: { media in
        addMessageMediaResourceIdsToRemove(media: media, resourceIds: &resourceIds)
    })
    if !resourceIds.isEmpty {
        let _ = mediaBox.removeCachedResources(Array(Set(resourceIds)), force: true).start()
    }
}

func _internal_clearHistory(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, threadId: Int64?, namespaces: MessageIdNamespaces) {
    if peerId.namespace == Namespaces.Peer.SecretChat {
        var resourceIds: [MediaResourceId] = []
        transaction.withAllMessages(peerId: peerId, { message in
            addMessageMediaResourceIdsToRemove(message: message, resourceIds: &resourceIds)
            return true
        })
        if !resourceIds.isEmpty {
            let _ = mediaBox.removeCachedResources(Array(Set(resourceIds)), force: true).start()
        }
    }
    transaction.clearHistory(peerId, threadId: threadId, minTimestamp: nil, maxTimestamp: nil, namespaces: namespaces, forEachMedia: { _ in
    })
}

func _internal_clearHistoryInRange(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, threadId: Int64?, minTimestamp: Int32, maxTimestamp: Int32, namespaces: MessageIdNamespaces) {
    if peerId.namespace == Namespaces.Peer.SecretChat {
        var resourceIds: [MediaResourceId] = []
        transaction.withAllMessages(peerId: peerId, { message in
            if message.timestamp >= minTimestamp && message.timestamp <= maxTimestamp {
                addMessageMediaResourceIdsToRemove(message: message, resourceIds: &resourceIds)
            }
            return true
        })
        if !resourceIds.isEmpty {
            let _ = mediaBox.removeCachedResources(Array(Set(resourceIds)), force: true).start()
        }
    }
    transaction.clearHistory(peerId, threadId: threadId, minTimestamp: minTimestamp, maxTimestamp: maxTimestamp, namespaces: namespaces, forEachMedia: { _ in
    })
}

public enum ClearCallHistoryError {
    case generic
}

func _internal_clearCallHistory(account: Account, forEveryone: Bool) -> Signal<Never, ClearCallHistoryError> {
    return account.postbox.transaction { transaction -> Signal<Void, NoError> in
        var flags: Int32 = 0
        if forEveryone {
            flags |= 1 << 0
        }

        let signal = account.network.request(Api.functions.messages.deletePhoneCallHistory(flags: flags))
        |> map { result -> Api.messages.AffectedFoundMessages? in
            return result
        }
        |> `catch` { _ -> Signal<Api.messages.AffectedFoundMessages?, Bool> in
            return .fail(false)
        }
        |> mapToSignal { result -> Signal<Void, Bool> in
            if let result = result {
                switch result {
                case let .affectedFoundMessages(affectedFoundMessagesData):
                    let (pts, ptsCount, offset) = (affectedFoundMessagesData.pts, affectedFoundMessagesData.ptsCount, affectedFoundMessagesData.offset)
                    account.stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                    if offset == 0 {
                        return .fail(true)
                    } else {
                        return .complete()
                    }
                }
            } else {
                return .fail(true)
            }
        }
        return (signal
        |> restart)
        |> `catch` { success -> Signal<Void, NoError> in
            if success {
                return account.postbox.transaction { transaction -> Void in
                    transaction.removeAllMessagesWithGlobalTag(tag: GlobalMessageTags.Calls)
                }
            } else {
                return .complete()
            }
        }
    }
    |> switchToLatest
    |> ignoreValues
    |> castError(ClearCallHistoryError.self)
}

public enum SetChatMessageAutoremoveTimeoutError {
    case generic
}

func _internal_setChatMessageAutoremoveTimeoutInteractively(account: Account, peerId: PeerId, timeout: Int32?) -> Signal<Never, SetChatMessageAutoremoveTimeoutError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> castError(SetChatMessageAutoremoveTimeoutError.self)
    |> mapToSignal { inputPeer -> Signal<Never, SetChatMessageAutoremoveTimeoutError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }
        return account.network.request(Api.functions.messages.setHistoryTTL(peer: inputPeer, period: timeout ?? 0))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.Updates?, NoError> in
            return .single(nil)
        }
        |> castError(SetChatMessageAutoremoveTimeoutError.self)
        |> mapToSignal { result -> Signal<Never, SetChatMessageAutoremoveTimeoutError> in
            if let result = result {
                account.stateManager.addUpdates(result)

                return account.postbox.transaction { transaction -> Void in
                    transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                        let updatedTimeout: CachedPeerAutoremoveTimeout
                        if let timeout = timeout {
                            updatedTimeout = .known(CachedPeerAutoremoveTimeout.Value(peerValue: timeout))
                        } else {
                            updatedTimeout = .known(nil)
                        }

                        if peerId.namespace == Namespaces.Peer.CloudUser {
                            let current = (current as? CachedUserData) ?? CachedUserData()
                            return current.withUpdatedAutoremoveTimeout(updatedTimeout)
                        } else if peerId.namespace == Namespaces.Peer.CloudChannel {
                            let current = (current as? CachedChannelData) ?? CachedChannelData()
                            return current.withUpdatedAutoremoveTimeout(updatedTimeout)
                        } else if peerId.namespace == Namespaces.Peer.CloudGroup {
                            let current = (current as? CachedGroupData) ?? CachedGroupData()
                            return current.withUpdatedAutoremoveTimeout(updatedTimeout)
                        } else {
                            return current
                        }
                    })
                }
                |> castError(SetChatMessageAutoremoveTimeoutError.self)
                |> ignoreValues
            } else {
                return .fail(.generic)
            }
        }
        |> `catch` { _ -> Signal<Never, SetChatMessageAutoremoveTimeoutError> in
            return .complete()
        }
    }
}
