import Foundation

/// Ubisoft disables CEF command-line switches. This exact-version compatibility edit lets
/// --in-process-gpu avoid Wine's cross-process presentation failure. No sandbox switches are used.
/// Research: https://github.com/Pab450/trackmania-mac.
public enum UbisoftBrowser {
    static let originalSHA = "5680f2b2447011771d02b7e649da319d8df32aa0b4562e5e6d0dce89278012b9"
    static let patchedSHA = "ddf4e66f0f65e08a0991e33d22b5185502e76fe3c5cc050a7ff94815107e2337"
    static let offset = 0x11dd2d
    static let before = Data([0x8b,0x47,0x34,0x89,0x46,0x34,0x8b,0x47,0x38,0x89,0x46,0x38])
    static let after = Data([0x8b,0x47,0x34,0x89,0x46,0x34,0x31,0xc0,0x90,0x89,0x46,0x38])
    static let flag = "--in-process-gpu"
    public static func supports(_ g: InstalledGame) -> Bool { PCLaunchers.kind(of:g) == .ubisoft }
    static func browser(_ g: InstalledGame) -> URL? {
        guard supports(g), let exe=CompatibilityFixes.managedProgram(g) else { return nil }
        let dll=exe.deletingLastPathComponent().appendingPathComponent("libcef.dll")
        guard dll.resolvingSymlinksInPath().deletingLastPathComponent() == exe.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        return dll
    }
    static func patched(_ data: Data) throws -> Data {
        let sha=Hashing.sha256(data:data)
        if sha == patchedSHA { return data }
        guard sha == originalSHA, data.count >= offset + before.count,
              data.subdata(in:offset..<offset+before.count) == before else {
            throw NokError("This Ubisoft browser version has not been verified for the display fix. Its files were kept. Update Nokcandu for support for this version.")
        }
        var result=data;result.replaceSubrange(offset..<offset+before.count,with:after)
        guard Hashing.sha256(data:result) == patchedSHA else { throw NokError("Ubisoft browser verification failed; its files were kept.") }
        return result
    }
    static func plannedFiles(_ g: InstalledGame) throws -> [URL:Data] {
        guard let dll=browser(g), PEFile.inspect(dll)?.is64Bit == false else { throw NokError("Choose Ubisoft Connect's own upc.exe first; its 32-bit browser must be beside it.") }
        return [dll:try patched(Data(contentsOf:dll))]
    }
    static func arguments(_ current: String) -> String {
        CustomGames.splitArguments(current).contains(flag) ? current : current + (current.isEmpty ? "" : " ") + flag
    }
    static func undoArguments(_ current:String, previous:String, applied:String) -> String {
        if current == applied { return previous }
        guard !CustomGames.splitArguments(previous).contains(flag) else { return current }
        // Remove only the token added by this fix, keeping later unrelated user arguments.
        return current.replacingOccurrences(of:#"(?<!\S)--in-process-gpu(?!\S)"#,with:"",options:.regularExpression)
            .trimmingCharacters(in:.whitespaces)
    }
    static func configureClient(_ game:InstalledGame, log:@escaping @Sendable(String)->Void) async throws {
        log("Preparing Ubisoft's browser display. Closing its Windows programs first…")
        try await WineTools.stopAll(for:game)
        for fix in [CompatibilityFix.shaderCompiler47, .ubisoftBrowser] {
            let current=CompatibilityFixes.fresh(game)
            if !CompatibilityFixes.isInstalled(fix,for:current) { try await CompatibilityFixes.install(fix,for:current,log:log) }
        }
    }
    /// A self-update may restore the SAME official browser build. Repair it using the existing
    /// journal's unchanged before/after hashes; unknown builds are never edited. Finder launches
    /// use this too, so the fix does not depend on Nokcandu's UI being open.
    static func launcherBlock(_ config:CustomGameConfig) -> String {
        guard PCLauncher.ubisoft.exeSuffixes.contains(where:{ config.exe.lowercased().hasSuffix($0) }) else { return "" }
        return """
        # Verified Ubisoft browser compatibility (original retained by Fixes / Undo).
        if [ -f "$SUPPORT/nokcandu/fix-ubisoft-browser.json" ]; then
         UBI_BROWSER="$GAME_DIR/libcef.dll"
         [ -f "$UBI_BROWSER" ] && [ ! -L "$UBI_BROWSER" ] || { echo 'Ubisoft browser is missing or linked outside its folder; files kept.' >&2; exit 1; }
         UBI_SHA=$( /usr/bin/shasum -a 256 "$UBI_BROWSER" | /usr/bin/awk '{print $1}' )
         case "$UBI_SHA" in
          \(patchedSHA)) ;;
          \(originalSHA))
           if [ "$CHECK_ONLY" = 0 ]; then
            UBI_TEMP=$( /usr/bin/mktemp "$GAME_DIR/.nokcandu-cef.XXXXXX" )
            trap '/bin/rm -f "$UBI_TEMP" "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT
            /bin/cp -p "$UBI_BROWSER" "$UBI_TEMP"
            if /usr/bin/printf '\\061\\300\\220' | /bin/dd of="$UBI_TEMP" bs=1 seek=\(offset+6) conv=notrunc 2>/dev/null && [ "$( /usr/bin/shasum -a 256 "$UBI_TEMP" | /usr/bin/awk '{print $1}' )" = \(patchedSHA) ]; then
             [ ! -L "$UBI_BROWSER" ] && [ "$( /usr/bin/shasum -a 256 "$UBI_BROWSER" | /usr/bin/awk '{print $1}' )" = \(originalSHA) ] || { echo 'Ubisoft browser changed during repair; files kept.' >&2; exit 1; }
             /bin/mv -f "$UBI_TEMP" "$UBI_BROWSER"
            else
             /bin/rm -f "$UBI_TEMP"; echo 'Ubisoft browser repair could not be verified; original kept.' >&2; exit 1
            fi
           fi ;;
          *) echo 'Ubisoft updated its browser to an unverified version. Update Nokcandu for this display fix; browser files were kept.' >&2; exit 1 ;;
         esac
        fi

        """
    }
}
