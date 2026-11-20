// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
public import LibSignalClient

public struct SigDemoAgentHistoryRecord: Sendable {
    public let id: String
    public let author: String
    public let text: String
    public let isAssistant: Bool
    public let isRequester: Bool
}

/// All response metadata lives alongside the existing SQLCipher messages. It
/// contains no inference credentials and is never an independent agent history.
public enum SigDemoAgentMessages {
    public static let didPersistLocalMessage = Notification.Name("SigDemoDidPersistLocalMessage")
    private static let collection = "SigDemoAgent.responseState"
    private static let store = KeyValueStore(collection: collection)
    private struct Stored: Codable {
        let messageId: String
        let queryTimestamp: UInt64
        let sequence: UInt32
        let status: SigDemoAgentFrame.Status
        let localRunId: UUID?
    }

    public struct InterruptedResponseCursor: Sendable {
        fileprivate let highWaterRowId: Int64
        fileprivate let afterKey: String
    }

    /// Reconcile only metadata that existed at startup, in bounded transactions.
    /// Current-process publishers and responses authored by other accounts are
    /// excluded even if a new job runs while the scan yields between batches.
    public static func reconcileInterruptedLocalResponses(
        accountId: String,
        localRunId: UUID,
        after cursor: InterruptedResponseCursor?,
        tx: DBWriteTransaction
    ) throws -> InterruptedResponseCursor? {
        let manager = DependenciesBridge.shared.tsAccountManager
        guard Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String == "dev.matbalez.sig-demo.ios",
              manager.registrationState(tx: tx).isRegistered,
              let origin = manager.localIdentifiers(tx: tx)?.aci,
              origin.serviceIdUppercaseString == accountId else { return nil }
        let highWaterRowId: Int64
        if let cursor {
            highWaterRowId = cursor.highWaterRowId
        } else {
            highWaterRowId = try Int64.fetchOne(tx.database, sql: "SELECT COALESCE(MAX(rowid), 0) FROM keyvalue") ?? 0
        }
        let keys = try String.fetchAll(tx.database, sql: """
            SELECT key FROM keyvalue
            WHERE collection = ? AND key > ? AND key < 'query0' AND rowid <= ?
            ORDER BY key LIMIT 64
            """, arguments: [collection, cursor?.afterKey ?? "query/", highWaterRowId])
        let interrupted = "Sig's reply was interrupted when the app stopped. Send @sig again to try again."
        let now = NSDate.ows_millisecondTimeStamp()
        for key in keys {
            guard let previous = stored(key, tx: tx), previous.status == .streaming,
                  previous.localRunId != localRunId,
                  previous.queryTimestamp > 0, previous.queryTimestamp < 9_007_199_254_740_991,
                  let message = TSMessage.fetchMessageViaCache(uniqueId: previous.messageId, transaction: tx) as? TSIncomingMessage,
                  message.authorAddress.aci == origin,
                  message.timestamp == previous.queryTimestamp + 1,
                  !message.wasRemotelyDeleted, !message.isViewOnceMessage, !message.isViewOnceComplete,
                  message.expiresAt == 0 || message.expiresAt > now,
                  let mirror = stored("message/" + message.uniqueId, tx: tx),
                  mirror.messageId == previous.messageId, mirror.queryTimestamp == previous.queryTimestamp,
                  mirror.sequence == previous.sequence, mirror.status == .streaming,
                  mirror.localRunId == previous.localRunId,
                  let queryId = key.split(separator: "/").last.map(String.init),
                  UUID(uuidString: queryId) != nil, queryId == queryId.lowercased(),
                  key == "query/\(message.uniqueThreadId)/\(origin.serviceIdUppercaseString)/\(queryId)",
                  let thread = TSThread.fetchViaCache(uniqueId: message.uniqueThreadId, transaction: tx) else { continue }
            if previous.sequence < UInt32.max {
                guard let frame = try? SigDemoAgentFrame(queryId: queryId,
                    queryTimestamp: previous.queryTimestamp, sequence: previous.sequence + 1,
                    status: .error, text: interrupted) else { continue }
                // Reuse the normal one-row update and encrypted durable outbox.
                // Note to Self remains local through publish's existing branch.
                publish(frame, thread: thread, origin: origin, localRunId: localRunId, tx: tx)
            } else {
                // There is no larger wire sequence. Terminate the local indexes
                // without wrapping, and let the terminal status reject updates.
                let terminal = Stored(messageId: previous.messageId, queryTimestamp: previous.queryTimestamp,
                    sequence: previous.sequence, status: .error, localRunId: localRunId)
                guard let data = try? JSONEncoder().encode(terminal) else { continue }
                message.sigDemoUpdateBody(interrupted, tx: tx)
                store.setData(data, key: key, transaction: tx)
                store.setData(data, key: "message/" + message.uniqueId, transaction: tx)
            }
        }
        guard keys.count == 64, let lastKey = keys.last else { return nil }
        return InterruptedResponseCursor(highWaterRowId: highWaterRowId, afterKey: lastKey)
    }

    public static func isResponse(_ message: TSMessage, tx: DBReadTransaction) -> Bool {
        store.hasValue("message/" + message.uniqueId, transaction: tx)
    }

    public static func isCompletedResponse(_ message: TSMessage, tx: DBReadTransaction) -> Bool {
        stored("message/" + message.uniqueId, tx: tx)?.status == .complete
    }

    public static func authorName(_ message: TSMessage, tx: DBReadTransaction) -> String {
        if isResponse(message, tx: tx) { return "Sig" }
        let address: SignalServiceAddress?
        if let incoming = message as? TSIncomingMessage { address = incoming.authorAddress }
        else { address = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aciAddress }
        guard let address else { return "Participant" }
        switch SSKEnvironment.shared.contactManagerRef.displayName(for: address, tx: tx) {
        case .phoneNumber, .unknown, .deletedAccount: return "Participant"
        case let name: return name.resolvedValue()
        }
    }

    /// Empty .requester metadata carries only the position of the most recent
    /// outgoing when its content is ineligible. The native context builder
    /// consumes this marker before serializing any model input.
    public static let requesterBoundaryID = "sig-own-message-boundary"

    /// Read the live original for a selected Signal reply. A quote snapshot can survive deletion.
    public static func replyTarget(for query: TSOutgoingMessage, tx: DBReadTransaction) -> SigDemoAgentHistoryRecord? {
        guard let quote = query.quotedMessage, quote.bodySource == .local,
              !quote.isTargetMessageViewOnce, !quote.isGiftBadge, !quote.isPoll,
              let timestamp = quote.timestampValue?.uint64Value, timestamp > 0, timestamp <= query.timestamp,
              let author = quote.authorAddress.aci,
              let matches = try? InteractionFinder.fetchInteractions(timestamp: timestamp, transaction: tx)
        else { return nil }
        let localAuthor = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        let candidates = matches.compactMap { interaction -> TSMessage? in
            guard interaction.uniqueThreadId == query.uniqueThreadId else { return nil }
            if let incoming = interaction as? TSIncomingMessage, incoming.authorAddress.aci == author { return incoming }
            if let outgoing = interaction as? TSOutgoingMessage, localAuthor == author { return outgoing }
            return nil
        }
        guard candidates.count == 1, let original = candidates.first,
              original.sortId < query.sortId, !original.wasRemotelyDeleted else { return nil }

        // Match Signal's own jump-to-quote behavior when the selected original was edited.
        let target: TSMessage
        if original.editState == .pastRevision {
            guard let latest = DependenciesBridge.shared.editMessageStore.findMessage(fromEdit: original, tx: tx)
            else { return nil }
            target = latest
        } else {
            target = original
        }
        guard target.uniqueThreadId == query.uniqueThreadId, target.uniqueId != query.uniqueId else { return nil }
        return eligibleReplyRecord(target, tx: tx)
    }

    public static func eligibleReplyRecord(_ target: TSMessage, tx: DBReadTransaction) -> SigDemoAgentHistoryRecord? {
        guard target is TSIncomingMessage || target is TSOutgoingMessage,
              !(target is TransientOutgoingMessage), (target as? TSOutgoingMessage)?.messageState != .failed
        else { return nil }
        return eligibleRecord(target, isAssistant: isResponse(target, tx: tx),
            at: NSDate.ows_millisecondTimeStamp(), tx: tx)
    }

    private static func eligibleRecord(_ message: TSMessage, isAssistant assistant: Bool, at now: UInt64,
                                       tx: DBReadTransaction) -> SigDemoAgentHistoryRecord? {
        guard !message.wasRemotelyDeleted, !message.isViewOnceMessage, !message.isViewOnceComplete,
              !message.isPoll, message.storyTimestamp == nil, message.contactShare == nil,
              message.messageSticker == nil, message.giftBadge == nil,
              !message.hasBodyAttachments(transaction: tx),
              message.expiresAt == 0 || message.expiresAt > now,
              let text = message.body, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !assistant || isCompletedResponse(message, tx: tx) else { return nil }
        return .init(id: message.uniqueId, author: authorName(message, tx: tx), text: text,
            isAssistant: assistant, isRequester: message is TSOutgoingMessage && !assistant)
    }

    public static func history(before query: TSMessage, forLocalModel: Bool = false, tx: DBReadTransaction) -> [SigDemoAgentHistoryRecord] {
        guard let queryRowId = query.grdbId?.int64Value else { return [] }
        var records: [SigDemoAgentHistoryRecord] = []
        var visited = 0
        var eligibleCount = 0
        var foundRequester = false
        var bytes = 0
        let now = NSDate.ows_millisecondTimeStamp()
        try? InteractionFinder(threadUniqueId: query.uniqueThreadId).enumerateInteractionsForConversationView(rowIdFilter: .before(queryRowId), tx: tx) { interaction in
            guard interaction.sortId < query.sortId, interaction.timestamp <= query.timestamp else { return true }
            visited += 1
            guard visited <= (forLocalModel ? 1000 : 60) else { return false }
            guard let message = interaction as? TSMessage,
                  message is TSIncomingMessage || message is TSOutgoingMessage else { return true }
            let outgoing = message as? TSOutgoingMessage
            guard !(message is TransientOutgoingMessage), outgoing?.messageState != .failed else { return true }
            let assistant = isResponse(message, tx: tx)
            let isRequester = outgoing != nil && !assistant
            let newestOutgoing = isRequester && !foundRequester
            if newestOutgoing { foundRequester = true }
            var recordedText = false
            defer {
                if newestOutgoing && !recordedText {
                    records.append(.init(id: requesterBoundaryID, author: "", text: "", isAssistant: false, isRequester: true))
                }
            }
            guard let record = eligibleRecord(message, isAssistant: assistant, at: now, tx: tx) else { return true }
            let size = record.author.utf8.count + record.text.utf8.count
            guard bytes + size <= 3 * 1024 * 1024 else { return false }
            records.append(record)
            recordedText = true
            bytes += size
            eligibleCount += 1
            return eligibleCount < (forLocalModel ? 100 : 60)
        }
        return records.reversed()
    }

    @discardableResult
    public static func apply(_ frame: SigDemoAgentFrame, thread: TSThread, origin: Aci,
                             expiresInSeconds: UInt32 = 0, expireTimerVersion: UInt32? = nil,
                             localRunId: UUID? = nil, showLocalThinking: Bool = false,
                             tx: DBWriteTransaction) -> TSIncomingMessage? {
        let key = "query/\(thread.uniqueId)/\(origin.serviceIdUppercaseString)/\(frame.queryId)"
        let previous = stored(key, tx: tx)
        let pendingLabel = showLocalThinking ? "Sig is thinking…" : "Sig is responding…"
        let body = frame.status == .streaming && frame.text.isEmpty ? pendingLabel : frame.text
        let message: TSIncomingMessage
        if let previous {
            guard frame.canReplace(queryTimestamp: previous.queryTimestamp, sequence: previous.sequence, status: previous.status),
                  let existing = TSMessage.fetchMessageViaCache(uniqueId: previous.messageId, transaction: tx) as? TSIncomingMessage,
                  !existing.wasRemotelyDeleted, !existing.isViewOnceComplete,
                  existing.expiresAt == 0 || existing.expiresAt > NSDate.ows_millisecondTimeStamp() else { return nil }
            message = existing
        } else {
            let placeholder = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: body, ranges: .empty), tx: tx)
            let local = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
            let builder = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread, timestamp: frame.queryTimestamp + 1, authorAci: origin,
                messageBody: placeholder, expiresInSeconds: expiresInSeconds,
                expireTimerVersion: expireTimerVersion, read: origin == local)
            message = builder.build()
            message.anyInsert(transaction: tx)
        }
        message.sigDemoUpdateBody(body, tx: tx)
        let value = Stored(messageId: message.uniqueId, queryTimestamp: frame.queryTimestamp,
                           sequence: frame.sequence, status: frame.status, localRunId: localRunId)
        if let data = try? JSONEncoder().encode(value) {
            store.setData(data, key: key, transaction: tx)
            store.setData(data, key: "message/" + message.uniqueId, transaction: tx)
        }
        return message
    }

    @discardableResult
    public static func publish(_ frame: SigDemoAgentFrame, thread: TSThread, origin: Aci,
                               localRunId: UUID, showLocalThinking: Bool = false, tx: DBWriteTransaction) -> String? {
        let configuration = DependenciesBridge.shared.disappearingMessagesConfigurationStore.fetchOrBuildDefault(for: .thread(thread), tx: tx)
        guard let message = apply(frame, thread: thread, origin: origin, expiresInSeconds: configuration.durationSeconds,
                    expireTimerVersion: configuration.timerVersion, localRunId: localRunId,
                    showLocalThinking: showLocalThinking, tx: tx) else { return nil }
        if thread.isNoteToSelf { return message.uniqueId }
        let outgoing = SigDemoOutgoingAgentResponse(frame: frame, thread: thread,
            expiresInSeconds: configuration.durationSeconds, expireTimerVersion: configuration.timerVersion, tx: tx)
        SSKEnvironment.shared.messageSenderJobQueueRef.add(
            message: .preprepared(transientMessageWithoutAttachments: outgoing), transaction: tx)
        return message.uniqueId
    }

    private static func stored(_ key: String, tx: DBReadTransaction) -> Stored? {
        guard let data = store.getData(key, transaction: tx) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}

@objc(SigDemoOutgoingAgentResponse)
final class SigDemoOutgoingAgentResponse: TransientOutgoingMessage {
    private let frame: SigDemoAgentFrame

    init(frame: SigDemoAgentFrame, thread: TSThread, expiresInSeconds: UInt32,
         expireTimerVersion: UInt32, tx: DBReadTransaction) {
        self.frame = frame
        let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread)
        builder.timestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()
        builder.expiresInSeconds = expiresInSeconds
        builder.expireTimerVersion = NSNumber(value: expireTimerVersion)
        super.init(outgoingMessageWith: builder, additionalRecipients: [], explicitRecipients: [], skippedRecipients: [], transaction: tx)
    }

    override class var supportsSecureCoding: Bool { true }
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(try? JSONEncoder().encode(frame), forKey: "sigDemoFrame")
    }
    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "sigDemoFrame") as Data?,
              let frame = try? JSONDecoder().decode(SigDemoAgentFrame.self, from: data) else { return nil }
        self.frame = frame
        super.init(coder: coder)
    }
    override func dataMessageBuilder(with thread: TSThread, transaction tx: DBReadTransaction) -> SSKProtoDataMessageBuilder? {
        guard let builder = super.dataMessageBuilder(with: thread, transaction: tx),
              let field = try? SSKProtoDataMessage(serializedData: frame.encodedDataMessageField()),
              let unknown = field.unknownFields else { return nil }
        builder.setUnknownFields(unknown)
        return builder
    }
}
