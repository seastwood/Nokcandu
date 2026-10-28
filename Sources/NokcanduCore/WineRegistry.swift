import Foundation

enum WineRegistry {
    static func decode(_ value: String) -> String {
        let chars = Array(value.utf16)
        var result: [UInt16] = [], i = 0
        while i < chars.count {
            let c = chars[i]; i += 1
            guard c == 92, i < chars.count else { result.append(c); continue }
            let next = chars[i]
            if next == 92 || next == 34 { result.append(next); i += 1 }
            else if next == 120, i + 4 < chars.count,
                    let code = UInt16(String(decoding: chars[(i + 1)...(i + 4)], as: UTF16.self), radix: 16) { result.append(code); i += 5 }
            else { result.append(c) }
        }
        return String(decoding: result, as: UTF16.self)
    }
}
