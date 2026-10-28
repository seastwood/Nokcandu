import Foundation

/// Merge only explicitly owned setting commands. Suitable for .con commands and INI keys;
/// unrelated lines and the current file's newline style remain under the game's control.
enum TextSettings {
    static func read(_ url: URL) throws -> String { try decode(Data(contentsOf: url)) }
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 4_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw NokError("Unrecognised settings file format.") }
        return text
    }
    static func encode(_ text: String, like data: Data) throws -> Data {
        let encoding: String.Encoding = String(data: data, encoding: .utf8) == nil ? .isoLatin1 : .utf8
        guard let result = text.data(using: encoding) else { throw NokError("Settings could not be saved in their original format.") }
        return result
    }
    static func key(_ line: String) -> String? {
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.hasPrefix(";"), !clean.hasPrefix("#"), !clean.lowercased().hasPrefix("rem ") else { return nil }
        return String(clean.prefix { !$0.isWhitespace && $0 != "=" }).lowercased()
    }
    static func lines(_ text: String) -> [String] { text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }
    static func merge(current: String, valuesFrom saved: String, keys: [String]) -> String {
        let owned = Set(keys.map { $0.lowercased() })
        guard !owned.isEmpty else { return current }
        let source = lines(saved), newline = current.contains("\r\n") ? "\r\n" : "\n"
        var emitted = Set<String>(), output: [String] = []
        for line in lines(current) {
            if let k = key(line), owned.contains(k) {
                if emitted.insert(k).inserted { output += source.filter { key($0) == k } }
            } else { output.append(line) }
        }
        for k in keys.map({ $0.lowercased() }) where !emitted.contains(k) {
            let additions = source.filter { key($0) == k }
            if !additions.isEmpty {
                if output.last == "" { output.removeLast() }
                output += additions; output.append("")
            }
        }
        return output.joined(separator: newline)
    }
}
