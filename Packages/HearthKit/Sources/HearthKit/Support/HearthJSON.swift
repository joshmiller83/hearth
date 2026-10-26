import Foundation

/// The JSON settings every relay DTO uses, on both ends: dates as RFC 3339 text
/// (`2026-10-29T23:00:00Z`), read leniently (offsets, missing seconds, fractions).
public enum HearthJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(RFC3339.format(date))
        }
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = RFC3339.date(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an RFC 3339 date: \(text)")
            }
            return date
        }
        return d
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(T.self, from: data)
    }
}
