import Foundation

/// Wine 11 launcher pages (Chromium) need DXMT with cross-process surfaces, whatever renderer the games use.
/// Nokcandu's helper library selects DXMT only for the listed launcher programs (browser-renderer.h), so a
/// launcher renders while its games keep their own graphics mode. Steam has its own copy in SharedSteam.
public enum BrowserRenderer {
    /// Shell lines for a launcher script (needs $SUPPORT): opt the given programs in on the tested Wine 11.0
    /// engine when DXMT and the helper library are present. The capability has to be in the environment
    /// before Wine creates the processes, so it's exported here, not set by the helper.
    public static func launcherBlock(exes: String) -> String {
        """
        if [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ] &&
           [ -f "$SUPPORT/renderer/dxmt/wine/x86_64-windows/d3d11.dll" ] &&
           /usr/bin/grep -Eq '(^|[^0-9])11[.]0([^0-9]|$)' "$SUPPORT/wine/version" 2>/dev/null; then
         export NOKCANDU_BROWSER_DXMT_ROOT="$SUPPORT/renderer/dxmt/wine" NOKCANDU_BROWSER_EXES=\(CustomGames.shellQuote(exes)) DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1
        fi
        """
    }
    public static let battleNetExes = "Battle.net.exe"
}
