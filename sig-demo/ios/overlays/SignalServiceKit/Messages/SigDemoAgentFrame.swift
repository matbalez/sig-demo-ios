// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Desktop's DataMessage field 2000. The pinned iOS protobuf preserves this
/// extension as unknown fields, so no generated Signal protocol code is forked.
public struct SigDemoAgentFrame: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case streaming, complete, error }
    public let queryId: String
    public let queryTimestamp: UInt64
    public let sequence: UInt32
    public let status: Status
    public let text: String

    public init(queryId: String, queryTimestamp: UInt64, sequence: UInt32, status: Status, text: String) throws {
        guard UUID(uuidString: queryId) != nil, queryTimestamp > 0,
              queryTimestamp < 9_007_199_254_740_991, text.utf16.count <= 65_536 else {
            throw FrameError.invalid
        }
        self.queryId = queryId.lowercased()
        self.queryTimestamp = queryTimestamp
        self.sequence = sequence
        self.status = status
        self.text = text
    }

    public enum FrameError: Error { case invalid }
    public enum Decoded { case absent, invalid, frame(SigDemoAgentFrame) }

    public func canReplace(queryTimestamp previousTimestamp: UInt64, sequence previousSequence: UInt32,
                           status previousStatus: Status) -> Bool {
        queryTimestamp == previousTimestamp && previousStatus == .streaming && sequence > previousSequence
    }

    private enum CodingKeys: String, CodingKey { case queryId, queryTimestamp, sequence, status, text }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(queryId: values.decode(String.self, forKey: .queryId),
            queryTimestamp: values.decode(UInt64.self, forKey: .queryTimestamp),
            sequence: values.decode(UInt32.self, forKey: .sequence),
            status: values.decode(Status.self, forKey: .status), text: values.decode(String.self, forKey: .text))
    }

    public static func prompt(in body: String?) -> String? {
        guard let body, let expression = try? NSRegularExpression(pattern: "(^|\\s)@sig(?=$|\\s|[.,!?;:])", options: .caseInsensitive),
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range, in: body), let prefix = Range(match.range(at: 1), in: body) else { return nil }
        return body.replacingCharacters(in: range, with: String(body[prefix])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Produces one complete length-delimited DataMessage field 2000.
    public func encodedDataMessageField() -> Data {
        var nested = Data()
        Self.appendString(queryId, field: 1, into: &nested)
        Self.appendVarint(2 << 3, into: &nested); Self.appendVarint(queryTimestamp, into: &nested)
        Self.appendVarint(3 << 3, into: &nested); Self.appendVarint(UInt64(sequence), into: &nested)
        Self.appendString(status.rawValue, field: 4, into: &nested)
        Self.appendString(text, field: 5, into: &nested)
        var result = Data()
        Self.appendVarint((2000 << 3) | 2, into: &result)
        Self.appendVarint(UInt64(nested.count), into: &result)
        result.append(nested)
        return result
    }

    public static func decodeUnknownFields(_ data: Data) -> Decoded {
        guard data.count <= 256 * 1024 else { return .invalid }
        do {
            let fields = try parseFields(data)
            let matches = fields.filter { $0.number == 2000 }
            guard !matches.isEmpty else { return .absent }
            guard matches.count == 1, let nested = matches.first?.bytes else { return .invalid }
            let values = try parseFields(nested)
            for field in 1...5 where values.filter({ $0.number == field }).count != 1 { return .invalid }
            func string(_ field: Int) -> String? { values.first(where: { $0.number == field })?.bytes.flatMap { String(data: $0, encoding: .utf8) } }
            guard let query = string(1), let timestamp = values.first(where: { $0.number == 2 })?.integer,
                  let sequence = values.first(where: { $0.number == 3 })?.integer, sequence <= UInt64(UInt32.max),
                  let rawStatus = string(4), let status = Status(rawValue: rawStatus), let text = string(5) else { return .invalid }
            return .frame(try .init(queryId: query, queryTimestamp: timestamp, sequence: UInt32(sequence), status: status, text: text))
        } catch { return .invalid }
    }

    private struct Field { let number: Int; let integer: UInt64?; let bytes: Data? }
    private static func parseFields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var cursor = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<10 {
                guard cursor < bytes.count else { throw FrameError.invalid }
                let byte = bytes[cursor]; cursor += 1
                guard offset != 9 || byte <= 1 else { throw FrameError.invalid }
                value |= UInt64(byte & 0x7f) << (offset * 7)
                if byte < 0x80 { return value }
            }
            throw FrameError.invalid
        }
        var result: [Field] = []
        while cursor < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= UInt64(Int32.max) else { throw FrameError.invalid }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0: result.append(Field(number: field, integer: try varint(), bytes: nil))
            case 1, 5:
                let count = tag & 7 == 1 ? 8 : 4
                guard bytes.count - cursor >= count else { throw FrameError.invalid }
                cursor += count
                result.append(Field(number: field, integer: nil, bytes: nil))
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - cursor) else { throw FrameError.invalid }
                let end = cursor + Int(count)
                result.append(Field(number: field, integer: nil, bytes: Data(bytes[cursor..<end])))
                cursor = end
            default: throw FrameError.invalid
            }
        }
        return result
    }
    private static func appendString(_ value: String, field: UInt64, into data: inout Data) {
        appendVarint((field << 3) | 2, into: &data)
        let bytes = Data(value.utf8); appendVarint(UInt64(bytes.count), into: &data); data.append(bytes)
    }
    private static func appendVarint(_ value: UInt64, into data: inout Data) {
        var value = value
        while value >= 0x80 { data.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
        data.append(UInt8(value))
    }
}
