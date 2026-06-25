import Foundation
import ReadiumShared

enum LocatorCoding {
    static func encode(_ locator: Locator) throws -> Data {
        try Data(locator.jsonString().utf8)
    }

    static func decode(_ data: Data) throws -> Locator {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ReaderAppError.unknown
        }
        let json = try JSONValue(jsonString: string, warnings: nil)
        guard let locator = try Locator(json: json, warnings: nil) else {
            throw ReaderAppError.unknown
        }
        return locator
    }
}

