import Foundation
import Testing

@testable import HearthKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func keysKeepTheirOrderAndNumbersTheirText() throws {
        let text = #"{"z":1,"a":{"y":2.50,"b":[true,false,null]},"m":"x","n":-0.0,"e":1e3}"#
        let value = try JSONValue.parse(text)
        #expect(value.serialized() == text)
        #expect(value.objectValue?.keys == ["z", "a", "m", "n", "e"])
        #expect(value["a"]?["y"]?.doubleValue == 2.5)
        #expect(value["z"]?.intValue == 1)
    }

    @Test(arguments: [
        (#""a\"b\\c\/d\n\t""#, "a\"b\\c/d\n\t"),
        (#""\u00e9\u2014""#, "é—"),
        (#""\ud83d\ude00""#, "😀"),
        ("\"日本\"", "日本"),
    ])
    func stringsDecodeEscapes(json: String, expected: String) throws {
        #expect(try JSONValue.parse(json).stringValue == expected)
    }

    @Test func stringsRoundTrip() throws {
        let original = JSONValue.string("quote \" backslash \\ newline \n tab \t bell \u{07} emoji 😀")
        let again = try JSONValue.parse(original.serialized())
        #expect(again == original)
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "tru", "\"\\x\"", "\"\\ud83d\"", "{} {}", "-"])
    func malformedJSONIsRejected(text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
    }

    @Test func subscriptSetReplacesInPlaceAndAppends() {
        var object: JSONObject = ["a": 1, "b": 2]
        object["a"] = "one"
        object["c"] = 3
        object["b"] = nil
        #expect(JSONValue.object(object).serialized() == #"{"a":"one","c":3}"#)
    }

    @Test func codableBridgeRoundTrips() throws {
        struct Box: Codable, Equatable {
            var when: Date
            var tags: [String]
        }
        let box = Box(when: Date(timeIntervalSince1970: 1_700_000_000), tags: ["x"])
        let value = try JSONValue(encoding: box)
        #expect(value["when"]?.stringValue == "2023-11-14T22:13:20Z")
        #expect(try value.decode(Box.self) == box)
    }
}
