import Foundation

/// A JSON value that keeps object keys in the order they arrived and numbers
/// exactly as they were written.
///
/// Claude's content blocks and tool inputs travel as these. Preserved thinking
/// makes the API reject a conversation whose earlier turns changed, so the
/// history Hearth sends back has to be the history the API gave it, including
/// blocks the app doesn't model (thinking signatures, new block types). Swift
/// dictionaries reorder keys and `Double` rounds numbers; this type does neither.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number's text as written: "3", "-0.5", "1e3".
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// An object's members in order. Lookups are linear, which suits the small
/// objects the API sends.
public struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
    }

    public private(set) var members: [Member]

    public init(_ members: [Member] = []) {
        self.members = members
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        members = elements.map { Member(key: $0.0, value: $0.1) }
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }

    /// Reading returns the first member with `key`. Writing replaces it in place,
    /// appends a new member, or (with nil) removes it.
    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[Member]> { members.makeIterator() }
}

// MARK: - Reading

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int? {
        if case .number(let text) = self { return Int(text) ?? Double(text).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var isNull: Bool { self == .null }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public typealias Key = String
    public typealias Value = JSONValue

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(floatLiteral value: Double) { self = .number(JSONValue.numberText(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { JSONObject.Member(key: $0.0, value: $0.1) }))
    }
    public init(nilLiteral: ()) { self = .null }

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    public static func double(_ value: Double) -> JSONValue { .number(numberText(value)) }

    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var offset: Int
    public var description: String { "JSON: \(message) at byte \(offset)" }
}

extension JSONValue {
    /// Parses one JSON document. Keys keep their order; numbers keep their text.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        return try parser.document()
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.document()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func document() throws -> JSONValue {
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard i == bytes.count else { throw fail("unexpected data after the value") }
            return value
        }

        func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: i) }

        mutating func skipWhitespace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw fail("nested too deeply") }
            skipWhitespace()
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw fail("unexpected character")
            }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw fail("expected \(word)") }
            i += w.count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1
            var members: [JSONObject.Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(JSONObject(members))
            }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                let value = try parseValue(depth: depth + 1)
                members.append(JSONObject.Member(key: key, value: value))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end in an object") }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                if bytes[i] == UInt8(ascii: "}") {
                    i += 1
                    return .object(JSONObject(members))
                }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(items)
            }
            while true {
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end in an array") }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                if bytes[i] == UInt8(ascii: "]") {
                    i += 1
                    return .array(items)
                }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            i += 1  // opening quote
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    break
                }
                if b < 0x20 { throw fail("control character in a string") }
                if b != UInt8(ascii: "\\") {
                    out.append(b)
                    i += 1
                    continue
                }
                i += 1
                guard i < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // A high surrogate must be followed by \u and a low surrogate.
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw fail("lone surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("bad surrogate pair") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw fail("lone surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw fail("bad unicode escape") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw fail("short unicode escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[i]
                let digit: UInt32
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A") + 10)
                default: throw fail("bad hex digit")
                }
                value = value * 16 + digit
                i += 1
            }
            return value
        }

        mutating func parseNumber() throws -> String {
            let start = i
            func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad number") }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
            } else {
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad fraction") }
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad exponent") }
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
    }
}

// MARK: - Writing

extension JSONValue {
    /// Compact JSON with keys in their stored order.
    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public var data: Data { Data(serialized().utf8) }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let text): out += text
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (n, member) in object.members.enumerated() {
                if n > 0 { out += "," }
                JSONValue.writeString(member.key, into: &out)
                out += ":"
                member.value.write(into: &out)
            }
            out += "}"
        }
    }

    static let hexDigits = Array("0123456789abcdef")

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let v = Int(scalar.value)
                    out += "\\u00"
                    out.append(hexDigits[v >> 4])
                    out.append(hexDigits[v & 0xF])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Codable bridges

extension JSONValue {
    /// Any `Encodable` as a JSON value (via `HearthJSON`'s encoder).
    public init(encoding value: some Encodable) throws {
        self = try JSONValue.parse(HearthJSON.encoder().encode(value))
    }

    /// Decodes this value into `T` with `HearthJSON`'s decoder.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try HearthJSON.decoder().decode(T.self, from: data)
    }
}

/// `Codable` support for embedding a value in an ordinary DTO. Order survives
/// encoding; decoding goes through `JSONDecoder`, which may not keep key order,
/// so Claude transcripts are parsed with `JSONValue.parse` instead.
extension JSONValue: Codable {
    private struct MemberKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: MemberKey.self) {
            var members: [JSONObject.Member] = []
            for key in object.allKeys {
                members.append(.init(key: key.stringValue, value: try object.decode(JSONValue.self, forKey: key)))
            }
            self = .object(JSONObject(members))
            return
        }
        if var array = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !array.isAtEnd { items.append(try array.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Int64.self) {
            self = .number(String(n))
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .number(let text):
            var c = encoder.singleValueContainer()
            if let n = Int64(text) { try c.encode(n) } else { try c.encode(Double(text) ?? 0) }
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .array(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        case .object(let object):
            var c = encoder.container(keyedBy: MemberKey.self)
            for member in object.members { try c.encode(member.value, forKey: MemberKey(stringValue: member.key)) }
        }
    }
}
