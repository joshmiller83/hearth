import Foundation

/// Builders for the JSON schemas Hearth hands to structured outputs. Every
/// object closes with `additionalProperties: false`, as the API requires, and
/// every property is required (nullable ones say so with `anyOf … null`).
public enum Schema {
    public static let string: JSONValue = ["type": "string"]
    public static let integer: JSONValue = ["type": "integer"]
    public static let boolean: JSONValue = ["type": "boolean"]

    public static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    public static func enumeration(_ values: [String], _ description: String? = nil) -> JSONValue {
        var object: JSONObject = ["type": "string", "enum": .array(values.map { .string($0) })]
        if let description { object["description"] = .string(description) }
        return .object(object)
    }

    public static func array(_ items: JSONValue, _ description: String? = nil) -> JSONValue {
        var object: JSONObject = ["type": "array", "items": items]
        if let description { object["description"] = .string(description) }
        return .object(object)
    }

    public static func nullable(_ schema: JSONValue) -> JSONValue {
        ["anyOf": [schema, ["type": "null"]]]
    }

    /// An object whose properties (in this order) are all required.
    public static func object(_ properties: KeyValuePairs<String, JSONValue>, _ description: String? = nil) -> JSONValue {
        var props = JSONObject()
        for (name, schema) in properties { props[name] = schema }
        var object: JSONObject = [
            "type": "object",
            "properties": .object(props),
            "required": .array(properties.map { .string($0.key) }),
            "additionalProperties": false,
        ]
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}
