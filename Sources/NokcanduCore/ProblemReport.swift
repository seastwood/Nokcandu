import Foundation

/// "Report a Problem": a plain-text report of what's needed to fix a bug (Nokcandu and macOS versions,
/// the Mac's chip, the game's setup, diagnostics and the end of its logs), with personal details taken
/// out. The person reads it before anything leaves the Mac; nothing is sent automatically.
public enum ProblemReport {
    public static let issuesURL = URL(string: "https://github.com/seastwood/Nokcandu/issues/new")!

    public static func machine() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
            return String(cString: buf)
        }
        let mem = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        return "\(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string")) · \(mem) GB"
    }

    public static func build(game: InstalledGame?, description: String, nokcanduVersion: String) -> String {
        var out = "### What happened\n\(description.isEmpty ? "(describe the problem)" : description)\n\n"
        out += "### Setup\n"
        out += "- Nokcandu \(nokcanduVersion)\n- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n- \(machine())\n"
        if let g = game {
            out += "- Game: \(g.name)\n- Engine: \(g.wineVersion ?? "none")\n"
            if g.native == nil { out += "- " + GameNotes.currentSetup(g).replacingOccurrences(of: "\n", with: "\n- ") + "\n" }
            let fixes = CompatibilityFixes.installedIDs(for: g)
            if !fixes.isEmpty { out += "- Fixes: \(fixes.joined(separator: ", "))\n" }
            out += "\n### Diagnostics\n```\n" + Diagnostics.collect(g, includeHashes: false).text() + "\n```\n"
        }
        return redact(out)
    }

    /// Takes out the Mac user's name, home folder, computer name, email addresses and Steam IDs.
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName(),
                              fullName: String = NSFullUserName(), host: String = Host.current().localizedName ?? "") -> String {
        var t = text.replacingOccurrences(of: home, with: "~")
        for (needle, label) in [(fullName, "<name>"), (host, "<this Mac>"), (user, "<user>")] where needle.count >= 3 {
            t = t.replacingOccurrences(of: needle, with: label, options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"7656119[0-9]{10}"#, with: "<steam id>", options: .regularExpression)
        // Wine's per-user folders under drive_c/users/<name>.
        t = t.replacingOccurrences(of: #"(drive_c/users/|C:\\users\\)(?!Public|crossover|steamuser)[^/\\\s]+"#, with: "$1<user>", options: [.regularExpression, .caseInsensitive])
        return t
    }

    /// GitHub's new-issue page with the title and as much of the report as fits in a link; the full
    /// report is saved to a file to attach.
    public static func issueLink(title: String, body: String, maxBody: Int = 5500) -> URL {
        var b = body
        if b.count > maxBody { b = String(b.prefix(maxBody)) + "\n\n…(cut short — the full report is attached)" }
        var c = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: b)]
        return c.url!
    }

    public static func save(_ text: String, name: String) throws -> URL {
        try NokPaths.ensure(NokPaths.diagnostics)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = NokPaths.diagnostics.appendingPathComponent("Problem report – \(safe) – \(f.string(from: Date())).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
