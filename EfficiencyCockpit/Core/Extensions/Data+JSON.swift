import Foundation

/// Shared JSON encoding/decoding helpers for SwiftData models.
/// Used by ContextSnapshot, Decision, and other models that store JSON-encoded arrays.

extension Array where Element: Encodable {
    /// Encodes the array to JSON Data for storage in SwiftData.
    var jsonData: Data? {
        try? JSONEncoder().encode(self)
    }
}

extension Data {
    /// Decodes JSON Data back to a typed value.
    func decodeJSON<T: Decodable>() -> T? {
        try? JSONDecoder().decode(T.self, from: self)
    }
}
