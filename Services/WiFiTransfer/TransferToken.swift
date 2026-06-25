import Foundation
import Security

struct TransferToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date

    static func make(now: Date = Date(), ttl: TimeInterval = 10 * 60) -> TransferToken {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        let token = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return TransferToken(value: token, expiresAt: now.addingTimeInterval(ttl))
    }

    func isValid(_ candidate: String, now: Date = Date()) -> Bool {
        now < expiresAt && candidate == value
    }
}
