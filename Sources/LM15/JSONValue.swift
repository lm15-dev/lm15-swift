import Foundation

/// A lossless JSON value. Integer and floating-point tokens remain distinct.
@dynamicMemberLookup
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case orderedObject([JSONEntry])
    case null, bool(Bool), int(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public subscript(_ key: String) -> JSONValue { get { o[key] ?? .null } set { var entries = orderedEntries; if let i = entries.firstIndex(where: { $0.key == key }) { entries[i] = JSONEntry(key:key,value:newValue) } else { entries.append(JSONEntry(key:key,value:newValue)) }; self = .orderedObject(entries) } }
    public subscript(dynamicMember key: String) -> JSONValue { self[key] }
    public subscript(_ index: Int) -> JSONValue { a.indices.contains(index) ? a[index] : .null }
    public var o: [String: JSONValue] { switch self { case .object(let x): return x; case .orderedObject(let x): return Dictionary(x.map { ($0.key,$0.value) },uniquingKeysWith:{ _,b in b }); default:return [:] } }
    var orderedEntries: [JSONEntry] { switch self { case .orderedObject(let x):return x; case .object(let x):return x.keys.sorted().map { JSONEntry(key:$0,value:x[$0]!) }; default:return [] } }
    public var a: [JSONValue] { if case let .array(x) = self { return x }; return [] }
    public var s: String { if case let .string(x) = self { return x }; return "" }
    public var i: Int { switch self { case .int(let x): return Int(clamping: x); case .number(let x) where x.isFinite && x >= Double(Int.min) && x < Double(Int.max): return Int(x); default: return 0 } }
    public var d: Double { switch self { case .int(let x): return Double(x); case .number(let x): return x; default: return 0 } }
    public var b: Bool { if case let .bool(x) = self { return x }; return false }
    public var isNull: Bool { self == .null }
    public var isObject: Bool { switch self { case .object,.orderedObject:return true; default:return false } }
    public var isString: Bool { if case .string = self { return true }; return false }
    public var isArray: Bool { if case .array = self { return true }; return false }
    public var isNumber: Bool { switch self { case .int, .number: return true; default: return false } }
    public var empty: Bool { isNull || self == "" || self == [] || self == [:] }
    public var present: Bool { !isNull }
    public func has(_ key: String) -> Bool { o[key] != nil }
    public func or(_ fallback: @autoclosure () -> JSONValue) -> JSONValue { isNull ? fallback() : self }
    public func merging(_ value: JSONValue) -> JSONValue { { var out = self.isObject ? self : J.object([:]); for e in value.orderedEntries { out[e.key] = e.value }; return out }() }
    public func without(_ keys: [String]) -> JSONValue { .orderedObject(orderedEntries.filter { !keys.contains($0.key) }) }
    public func compact() -> JSONValue { .orderedObject(orderedEntries.filter { !$0.value.isNull }) }
    public func with(_ key: String, _ value: JSONValue) -> JSONValue { var r = self; r[key] = value; return r }
    public var stringValue: String { switch self { case .string(let x): return x; case .null: return "None"; case .bool(let x): return x ? "True" : "False"; default: return (try? jsonString()) ?? "" } }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Int64.self) { self = .int(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let x): try c.encode(x); case .int(let x): try c.encode(x); case .number(let x): try c.encode(x); case .string(let x): try c.encode(x); case .array(let x): try c.encode(x); case .object(let x): try c.encode(x); case .orderedObject: try c.encode(o) }
    }
    public static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw ValueError("JSON must be UTF-8") }
        return try parse(text)
    }
    public static func parse(_ text: String) throws -> JSONValue { var p = JSONParser(bytes: Array(text.utf8)); let v = try p.value(); p.space(); guard p.offset == p.bytes.count else { throw ValueError("trailing JSON data") }; return v }
    public func jsonString(sortedKeys: Bool = true) throws -> String {
        switch self {
        case .null: return "null"
        case .bool(let x): return x ? "true" : "false"
        case .int(let x): return String(x)
        case .number(let x): guard x.isFinite else { throw ValueError("JSON numbers must be finite") }; return String(x)
        case .string(let x): return String(decoding: try JSONEncoder().encode(x), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        case .array(let a): return "[" + (try a.map { try $0.jsonString(sortedKeys: sortedKeys) }).joined(separator: ",") + "]"
        case .object, .orderedObject: let o = self.o; let keys = sortedKeys ? o.keys.sorted() : orderedEntries.map(\.key); return "{" + (try keys.map { try JSONValue.string($0).jsonString() + ":" + o[$0]!.jsonString(sortedKeys: sortedKeys) }).joined(separator: ",") + "}"
        }
    }
    public func jsonData(sortedKeys: Bool = false) throws -> Data { Data(try jsonString(sortedKeys:sortedKeys).utf8) }
}
public struct JSONEntry: Sendable, Hashable {
    public let key: String
    public let value: JSONValue
    public init(key: String, value: JSONValue) { self.key = key; self.value = value }
}
extension JSONValue {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.isObject && rhs.isObject { return lhs.o == rhs.o }
        switch (lhs,rhs) {
        case (.null,.null):return true
        case let (.bool(a),.bool(b)):return a == b
        case let (.int(a),.int(b)):return a == b
        case let (.number(a),.number(b)):return a == b
        case let (.string(a),.string(b)):return a == b
        case let (.array(a),.array(b)):return a == b
        default:return false
        }
    }
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:hasher.combine(0)
        case .bool(let x):hasher.combine(1);hasher.combine(x)
        case .int(let x):hasher.combine(2);hasher.combine(x)
        case .number(let x):hasher.combine(3);hasher.combine(x)
        case .string(let x):hasher.combine(4);hasher.combine(x)
        case .array(let x):hasher.combine(5);hasher.combine(x)
        case .object,.orderedObject:hasher.combine(6);for key in o.keys.sorted() { hasher.combine(key);hasher.combine(o[key]) }
        }
    }
}
extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }; public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }; public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }; public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .orderedObject([]); for (k,v) in elements { self[k] = v } }
}
typealias J = JSONValue
func j(_ x: String) -> J { .string(x) }; func j(_ x: Int) -> J { .int(Int64(x)) }; func j(_ x: Double) -> J { .number(x) }; func j(_ x: Bool) -> J { .bool(x) }
func arr(_ x: [J]) -> J { .array(x) }
private struct JSONParser {
    var bytes: [UInt8]; var offset = 0; var depth = 0
    mutating func space() { while offset < bytes.count && [9,10,13,32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ b: UInt8) throws { space(); guard offset < bytes.count && bytes[offset] == b else { throw ValueError("invalid JSON at byte \(offset)") }; offset += 1 }
    mutating func value() throws -> J {
        space(); guard offset < bytes.count && depth < 512 else { throw ValueError("invalid or excessively nested JSON") }
        depth += 1; defer { depth -= 1 }; let start = offset
        switch bytes[offset] {
        case 110,116,102:
            let token = bytes[offset] == 110 ? "null" : bytes[offset] == 116 ? "true" : "false"
            guard bytes.dropFirst(offset).starts(with: token.utf8) else { throw ValueError("invalid JSON literal") }; offset += token.utf8.count
            return token == "null" ? .null : .bool(token == "true")
        case 34:
            offset += 1; var escaped = false
            while offset < bytes.count {
                let c = bytes[offset]; offset += 1
                if c == 34 && !escaped { return .string(try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))) }
                if c < 32 { throw ValueError("control character in JSON") }
                escaped = c == 92 && !escaped
            }; throw ValueError("unterminated JSON string")
        case 91:
            offset += 1; space(); var a: [J] = []
            if offset < bytes.count && bytes[offset] == 93 { offset += 1; return .array(a) }
            while true { a.append(try value()); space(); guard offset < bytes.count else { throw ValueError("unterminated array") }; if bytes[offset] == 93 { offset += 1; return .array(a) }; try take(44) }
        case 123:
            offset += 1; space(); var d: J = [:]
            if offset < bytes.count && bytes[offset] == 125 { offset += 1; return d }
            while true { let k = try value(); guard k.isString else { throw ValueError("JSON keys must be strings") }; try take(58); d[k.s] = try value(); space(); guard offset < bytes.count else { throw ValueError("unterminated object") }; if bytes[offset] == 125 { offset += 1; return d }; try take(44) }
        default:
            while offset < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[offset]) { offset += 1 }
            let token = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw ValueError("invalid JSON number") }
            if !token.contains(".") && !token.lowercased().contains("e"), let i = Int64(token) { return .int(i) }
            guard let d = Double(token), d.isFinite else { throw ValueError("JSON number out of range") }; return .number(d)
        }
    }
}
