import Foundation

// Recipes are reviewed and shipped with the app. Nothing here is downloaded or executed
// from the network; a recipe is data that Nokcandu's own code interprets.

public enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case fillScreen = "fill"
    case windowed = "windowed"
    public var id: String { rawValue }
    public var title: String { self == .fillScreen ? "Fullscreen" : "Windowed" }
}

public struct RuntimeSpec: Codable, Hashable {
    public var id: String              // runtime cache key
    public var engine: String          // e.g. WS12WineSikarugir10.0_8
    public var wineVersionString: String
    public var template: String
    public var renderer: String?
    public var gpuDriver: String?
}

public struct DisplayPolicy: Codable, Hashable {
    public var defaultMode: DisplayMode
    public var recoveryWindow: DesktopSize
    public var detail: String
}

public struct DiscSpec: Codable, Hashable {
    public var imageName: String       // inside SharedSupport
    public var volumeLabel: String
    public var internalMountDir: String
}

public struct VerificationItem: Codable, Hashable, Identifiable {
    public enum State: String, Codable { case confirmed, notVerified }
    public var id: String { title }
    public var title: String
    public var state: State
    public var note: String
}

public struct GameRecipe: Codable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var edition: String
    public var ownershipSource: String
    public var validationDate: String
    public var appBundleName: String           // "Generals Zero Hour.app"
    public var launcherExecutable: String      // CFBundleExecutable
    public var gameDirectory: String           // relative to Contents
    public var primaryExecutable: String       // relative to gameDirectory
    public var runtime: RuntimeSpec
    public var environment: [String: String]
    public var display: DisplayPolicy?
    public var disc: DiscSpec?
    /// SHA-256 pins, keyed by path relative to the app's Contents folder.
    public var pinnedHashes: [String: String]
    /// Launcher scripts Nokcandu recognizes (validated original, plus Nokcandu's own patched form).
    public var knownLauncherHashes: [String: String]
    public var verification: [VerificationItem]
    public var hasInstaller: Bool
    public var notes: [String]
}

public enum RecipeCatalog {
    public static let all: [GameRecipe] = [zeroHour, worms]

    public static func recipe(id: String) -> GameRecipe? { all.first { $0.id == id } }

    static let wine10SHA = "44f32defb3bde419e08a8d4d2a64633c8522e218e02fd5ad7ca0241fc1c45a5e"

    static let sikarugirWine10 = RuntimeSpec(
        id: "sikarugir-1.0.24-wine-10.0_8",
        engine: "WS12WineSikarugir10.0_8",
        wineVersionString: "wine sikarugir 10.0 (revision 8)",
        template: "Sikarugir 1.0.24",
        renderer: nil, gpuDriver: nil)

    public static let zeroHour: GameRecipe = {
        var rt = sikarugirWine10
        rt.renderer = "DXVK-Sikarugir 3.1.1-async (renderer/d9vk)"
        rt.gpuDriver = "KosmicKrisp 26.2.99"
        return GameRecipe(
            id: "generals-zero-hour-generalsonline-m4",
            displayName: "Generals Zero Hour",
            edition: "Steam (Windows) + GeneralsOnline 100126_QFE6",
            ownershipSource: "Steam app 2732960",
            validationDate: "2026-10-24",
            appBundleName: "Generals Zero Hour.app",
            launcherExecutable: "generals-launcher",
            gameDirectory: "SharedSupport/GameFiles",
            primaryExecutable: "GeneralsOnlineZH.exe",
            runtime: rt,
            environment: [
                "WINEMSYNC": "1",
                "DOTNET_SYSTEM_GLOBALIZATION_USENLS": "1",
                "WINEDLLOVERRIDES": "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,vcruntime140,icu=n;d3d8,d3d9=b",
            ],
            display: DisplayPolicy(defaultMode: .fillScreen,
                                   recoveryWindow: DesktopSize(width: 1280, height: 800),
                                   detail: "Medium detail, antialiasing off"),
            disc: nil,
            pinnedHashes: [
                "SharedSupport/wine/bin/wine": "44f32defb3bde419e08a8d4d2a64633c8522e218e02fd5ad7ca0241fc1c45a5e",
                "SharedSupport/renderer/d9vk/wine/i386-windows/d3d8.dll": "902f971988e0ae9cf9001a211ce733afabbfc3a0f034fac02a78faf6fa327371",
                "SharedSupport/renderer/d9vk/wine/i386-windows/d3d9.dll": "7cc1b4f37f19783a3d356e4a5c47aa163b6b791ccadaee3d672d7dba44718d68",
                "Frameworks/libvulkan_kosmickrisp.dylib": "34e50544998477671ba2ee5a288ebd0855128b0da92e671370abeadc505dbfe3",
                "SharedSupport/prefix/drive_c/windows/syswow64/icu.dll": "08f116a72b5b40149f6f634fb8dc70efd968b9cb64d44786d92acfab37521cda",
                "SharedSupport/prefix/drive_c/windows/syswow64/icudt72.dll": ICUPins.icudt72,
                "SharedSupport/prefix/drive_c/windows/syswow64/icuuc72.dll": ICUPins.icuuc72,
                "SharedSupport/prefix/drive_c/windows/syswow64/icuin72.dll": ICUPins.icuin72,
                // Wine's own system DLLs must be the originals (earlier experiments replaced them).
                "SharedSupport/prefix/drive_c/windows/syswow64/d3d8.dll": "0c99959010670509e4a9698abbdb4cae5829aea8558fde34ed77346f565fb036",
                "SharedSupport/prefix/drive_c/windows/syswow64/d3d9.dll": "7a769092ba9a9f7168ebb7d07c31eeb4b87fecd6a5f9d957d1964bb9a759589b",
            ],
            knownLauncherHashes: [
                "8fe257e529dbc867c6e9124cce7db7f790d73172ffad463e1947099fc8a2c9d0": "Validated launcher (Oct 24, fullscreen + --windowed)",
                // Same launcher, but falls back to /usr/bin/python3 when Homebrew python is absent (Nokcandu installs).
                "d8f0bd213f76908a2c0fa29fc079f787974c696a9abd7ae9624c7a11f1fadabc": "Nokcandu-installed launcher (validated recipe)",
            ],
            verification: [
                VerificationItem(title: "Local gameplay", state: .confirmed, note: "User confirmed skirmish gameplay."),
                VerificationItem(title: "Performance", state: .confirmed, note: "Near 60 FPS at 1280 × 800, Medium detail."),
                VerificationItem(title: "Fullscreen + app switching", state: .confirmed, note: "Desktop-sized fullscreen, Wine display capture off."),
                VerificationItem(title: "Online match", state: .notVerified, note: "No live online match yet; anti-cheat compatibility unknown."),
            ],
            hasInstaller: true,
            notes: [
                "Never force the renderer DLLs to native ('n'): they are Wine builtin DLLs and fail with a misleading DirectX 8.1 error.",
                "Original GeneralsOnlineZH.exe is preserved; the launcher runs the extracted, unmodified Launcher.dll through dotnet.exe.",
            ])
    }()

    public static let worms = GameRecipe(
        id: "worms-armageddon-disc-3.8.1",
        displayName: "Worms Armageddon",
        edition: "Disc edition, updated to 3.8.1",
        ownershipSource: "Owned disc image",
        validationDate: "2026-10-23",
        appBundleName: "Worms Armageddon.app",
        launcherExecutable: "worms-launcher",
        gameDirectory: "SharedSupport/prefix/drive_c/Games/Worms Armageddon",
        primaryExecutable: "WA.exe",
        runtime: sikarugirWine10,
        environment: [:],
        display: nil,
        disc: DiscSpec(imageName: "Worms Armageddon.iso", volumeLabel: "WA", internalMountDir: "SharedSupport/MountedDisc"),
        pinnedHashes: [
            "SharedSupport/wine/bin/wine": "44f32defb3bde419e08a8d4d2a64633c8522e218e02fd5ad7ca0241fc1c45a5e",
        ],
        knownLauncherHashes: [
            "e5ea2a5b9eca626ffb556418ecde138e51a27a03a286001e5504eca635f907c7": "Validated disc launcher (Oct 24)",
        ],
        verification: [
            VerificationItem(title: "Local gameplay", state: .confirmed, note: "User confirmed: works perfectly."),
            VerificationItem(title: "Disc check", state: .confirmed, note: "Read-only mount; d: → volume, d:: → raw device, label WA."),
            VerificationItem(title: "Cold restart of refined launcher", state: .notVerified, note: "Preflight passed; full cold restart not confirmed."),
        ],
        hasInstaller: false,
        notes: [
            "Display modes are not validated for this game; it runs with its own settings.",
            "The disc image stays inside the app and is mounted read-only only when needed.",
        ])
}

/// Hashes of Microsoft.ICU.ICU4C.Runtime.win-x86 72.1.0.3 native DLLs, taken from the working setup.
public enum ICUPins {
    public static let packageURL = URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.icu.icu4c.runtime.win-x86/72.1.0.3/microsoft.icu.icu4c.runtime.win-x86.72.1.0.3.nupkg")!
    public static let icudt72 = "c128609ac3084761f5640fb49d244e0df52b9fe72c8da3b5c17b6edc24de05e7"
    public static let icuuc72 = "83423bbf26e49acae4c21f0fccd07c0aa0d5dc9e643276c463a34bc1644f040f"
    public static let icuin72 = "1439baacbb87fa45d19ca9710d45ff726036808ccb64b1fc014d305d7a09d92a"
    public static let adapter = "08f116a72b5b40149f6f634fb8dc70efd968b9cb64d44786d92acfab37521cda"
    public static var dlls: [String: String] { ["icudt72.dll": icudt72, "icuuc72.dll": icuuc72, "icuin72.dll": icuin72] }
}
