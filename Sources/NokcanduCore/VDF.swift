import Foundation

/// Minimal Valve KeyValues (VDF) parser — enough for Steam's installScript.vdf.
public indirect enum VDFNode: Equatable {
    case value(String)
    case object([(String, VDFNode)])

    public static func == (a: VDFNode, b: VDFNode) -> Bool {
        switch (a, b) {
        case let (.value(x), .value(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(_ key: String) -> VDFNode? {
        guard case let .object(items) = self else { return nil }
        return items.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }
    public var string: String? { if case let .value(s) = self { return s }; return nil }
    public var items: [(String, VDFNode)] { if case let .object(i) = self { return i }; return [] }
}

public enum VDF {
    public static func parse(_ text: String) throws -> VDFNode {
        var tokens: [String?] = []   // nil = "{" marker handled separately
        var kinds: [Character] = []  // 's' string, '{', '}'
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace { i = text.index(after: i); continue }
            if ch == "/" && text[i...].hasPrefix("//") {
                while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            if ch == "{" || ch == "}" { kinds.append(ch); tokens.append(nil); i = text.index(after: i); continue }
            var s = ""
            if ch == "\"" {
                i = text.index(after: i)
                while i < text.endIndex && text[i] != "\"" {
                    if text[i] == "\\" {
                        let n = text.index(after: i)
                        guard n < text.endIndex else { break }
                        switch text[n] { case "n": s.append("\n"); case "t": s.append("\t"); case "\\": s.append("\\"); case "\"": s.append("\""); default: s.append("\\"); s.append(text[n]) }
                        i = text.index(after: n)
                    } else { s.append(text[i]); i = text.index(after: i) }
                }
                guard i < text.endIndex else { throw NokError("Unterminated string in VDF") }
                i = text.index(after: i)
            } else {
                while i < text.endIndex && !text[i].isWhitespace && text[i] != "{" && text[i] != "}" && text[i] != "\"" {
                    s.append(text[i]); i = text.index(after: i)
                }
            }
            kinds.append("s"); tokens.append(s)
        }
        var pos = 0
        func object(top: Bool) throws -> VDFNode {
            var items: [(String, VDFNode)] = []
            while pos < kinds.count {
                if kinds[pos] == "}" {
                    if top { throw NokError("Unexpected } in VDF") }
                    pos += 1
                    return .object(items)
                }
                guard kinds[pos] == "s", let key = tokens[pos] else { throw NokError("Expected key in VDF") }
                pos += 1
                guard pos < kinds.count else { throw NokError("Missing value for \(key)") }
                if kinds[pos] == "{" { pos += 1; items.append((key, try object(top: false))) }
                else if kinds[pos] == "s", let v = tokens[pos] { pos += 1; items.append((key, .value(v))) }
                else { throw NokError("Bad value for \(key)") }
            }
            if !top { throw NokError("Missing } in VDF") }
            return .object(items)
        }
        return try object(top: true)
    }

    /// Converts installScript.vdf "Registry" entries into a Windows .reg file for one language.
    /// %INSTALLDIR% becomes `installDir`. Only values present in the Steam script are written —
    /// nothing is invented.
    public static func registryFile(fromInstallScript root: VDFNode, installDir: String, language: String = "english") throws -> String {
        guard let reg = root["InstallScript"]?["Registry"] else { throw NokError("installScript.vdf has no Registry section") }
        var out = "Windows Registry Editor Version 5.00\n\n"
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        for (rawKey, body) in reg.items {
            var key = rawKey
            if key.hasPrefix("HKEY_LOCAL_MACHINE_WOW64_32\\") {
                // 32-bit view of HKLM\SOFTWARE in a 64-bit prefix.
                let rest = key.dropFirst("HKEY_LOCAL_MACHINE_WOW64_32\\".count)
                if rest.uppercased().hasPrefix("SOFTWARE\\") {
                    key = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Wow6432Node\\" + rest.dropFirst("SOFTWARE\\".count)
                } else { key = "HKEY_LOCAL_MACHINE\\" + rest }
            } else if key.hasPrefix("HKEY_LOCAL_MACHINE_WOW64_64\\") {
                key = "HKEY_LOCAL_MACHINE\\" + key.dropFirst("HKEY_LOCAL_MACHINE_WOW64_64\\".count)
            }
            var lines: [String] = []
            for (type, values) in body.items {
                // Values are either per-language groups or direct name/value pairs.
                let chosen: [(String, VDFNode)]
                if let lang = values[language] { chosen = lang.items }
                else if values.items.allSatisfy({ $0.1.string != nil }) { chosen = values.items }
                else { continue }
                for (name, v) in chosen {
                    guard let raw = v.string else { continue }
                    let value = raw.replacingOccurrences(of: "%INSTALLDIR%", with: installDir)
                    switch type.lowercased() {
                    case "dword":
                        guard let n = UInt32(value) else { throw NokError("Bad dword \(name)=\(value)") }
                        lines.append("\"\(escape(name))\"=dword:\(String(format: "%08x", n))")
                    case "string":
                        lines.append("\"\(escape(name))\"=\"\(escape(value))\"")
                    default:
                        continue
                    }
                }
            }
            if !lines.isEmpty { out += "[\(key)]\n" + lines.joined(separator: "\n") + "\n\n" }
        }
        return out
    }
}
