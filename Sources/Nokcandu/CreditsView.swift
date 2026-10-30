import SwiftUI
import AppKit

/// Settings ▸ Credits: the open-source projects Nokcandu is built on or uses, with a way to support each one.
struct CreditsSettings: View {
    struct Project: Identifiable {
        let name: String
        let by: String
        let what: String
        let license: String
        let site: String
        var donate: [(String, String)] = []
        var id: String { name }
    }

    struct Group: Identifiable {
        let title: String
        let projects: [Project]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Running Windows games", projects: [
            Project(name: "Wine", by: "The Wine project and its contributors",
                    what: "Runs Windows programs on the Mac. Nokcandu's resizable window is built into its Mac driver.",
                    license: "LGPL 2.1", site: "https://www.winehq.org",
                    donate: [("Donate", "https://www.winehq.org/donate")]),
            Project(name: "Sikarugir", by: "Gcenx and contributors",
                    what: "The Wine engines and app wrapper every Nokcandu game runs in.",
                    license: "LGPL 2.1 and others", site: "https://github.com/Sikarugir-App/Sikarugir",
                    donate: [("Ko-fi", "https://ko-fi.com/gcenx"), ("PayPal", "https://paypal.me/gcenx")]),
            Project(name: "DXVK", by: "Philip Rebohle and contributors",
                    what: "Direct3D 8–11 on Vulkan.", license: "zlib", site: "https://github.com/doitsujin/dxvk"),
            Project(name: "DXMT", by: "Feifan He (3Shain)",
                    what: "Direct3D 10 and 11 on Metal.", license: "LGPL 2.1", site: "https://github.com/3Shain/dxmt"),
            Project(name: "MoltenVK", by: "The Khronos Group and contributors",
                    what: "Vulkan on Metal, under DXVK.", license: "Apache 2.0", site: "https://github.com/KhronosGroup/MoltenVK"),
            Project(name: "d3d8to9", by: "Patrick Mours (crosire)",
                    what: "Runs Direct3D 8 games through Direct3D 9.", license: "BSD 2-Clause", site: "https://github.com/crosire/d3d8to9"),
            Project(name: "GStreamer", by: "The GStreamer project",
                    what: "Audio and video playback inside the Wine engine.", license: "LGPL 2.1",
                    site: "https://gstreamer.freedesktop.org"),
            Project(name: "SDL", by: "Sam Lantinga and contributors",
                    what: "Game controllers inside the Wine engine.", license: "zlib", site: "https://www.libsdl.org"),
            Project(name: "Libraries in the Wine engine", by: "Their many authors",
                    what: "FreeType (fonts), GnuTLS and Nettle (secure connections), ICU (text), Brotli, bzip2, libffi, GMP, libiconv and others.",
                    license: "Various open-source licenses", site: "https://github.com/Sikarugir-App/Engines"),
        ]),
        Group(title: "Fixes and game data", projects: [
            Project(name: "LAV Filters", by: "Hendrik Leppkes (Nevcairiel)",
                    what: "The video and music playback fix.", license: "GPL 2",
                    site: "https://github.com/Nevcairiel/LAVFilters",
                    donate: [("GitHub Sponsors", "https://github.com/sponsors/Nevcairiel")]),
            Project(name: "FFmpeg", by: "The FFmpeg developers",
                    what: "The decoders inside LAV Filters.", license: "LGPL 2.1",
                    site: "https://ffmpeg.org", donate: [("Donate", "https://ffmpeg.org/donations.html")]),
            Project(name: "Winetricks", by: "Austin English and contributors",
                    what: "Recipes for installing Windows components.", license: "LGPL 2.1",
                    site: "https://github.com/Winetricks/winetricks",
                    donate: [("GitHub Sponsors", "https://github.com/sponsors/austin987"), ("Patreon", "https://www.patreon.com/austin987")]),
            Project(name: "umu-protonfixes and umu-database", by: "Open Wine Components",
                    what: "Known per-game fixes and game identifiers.", license: "BSD 2-Clause / GPL 3",
                    site: "https://github.com/Open-Wine-Components"),
            Project(name: "AreWeAntiCheatYet", by: "Its contributors",
                    what: "Which games' anti-cheat works outside Windows.", license: "MIT",
                    site: "https://areweanticheatyet.com"),
            Project(name: "rpc-bridge", by: "EnderIce2 and contributors",
                    what: "Discord Rich Presence for Windows games (optional).", license: "MIT",
                    site: "https://github.com/EnderIce2/rpc-bridge"),
            Project(name: "cabextract", by: "Stuart Caie",
                    what: "Unpacks Microsoft cabinet files.", license: "GPL", site: "https://www.cabextract.org.uk"),
        ]),
        Group(title: "Game stores", projects: [
            Project(name: "gogdl", by: "Heroic Games Launcher",
                    what: "Downloads GOG games.", license: "GPL 3",
                    site: "https://github.com/Heroic-Games-Launcher/heroic-gogdl",
                    donate: [("Ko-fi", "https://ko-fi.com/heroicgames"), ("Patreon", "https://www.patreon.com/heroicgameslauncher")]),
            Project(name: "Legendary", by: "derrod and contributors",
                    what: "Downloads Epic Games Store games.", license: "GPL 3",
                    site: "https://github.com/derrod/legendary", donate: [("Ko-fi", "https://ko-fi.com/derrod")]),
            Project(name: "Nile", by: "imLinguin and contributors",
                    what: "Downloads Amazon Games titles.", license: "GPL 3",
                    site: "https://github.com/imLinguin/nile", donate: [("Ko-fi", "https://ko-fi.com/imlinguin")]),
        ]),
        Group(title: "Used to build Nokcandu", projects: [
            Project(name: "llvm-mingw", by: "Martin Storsjö",
                    what: "Compiles the Windows half of Nokcandu's Wine driver.", license: "ISC; LLVM: Apache 2.0",
                    site: "https://github.com/mstorsjo/llvm-mingw"),
            Project(name: "Zig", by: "Zig Software Foundation",
                    what: "Builds the borderless-window helper.", license: "MIT",
                    site: "https://ziglang.org", donate: [("Donate", "https://ziglang.org/zsf/")]),
            Project(name: "GNU Bison", by: "The GNU Project",
                    what: "Needed to build Wine.", license: "GPL 3",
                    site: "https://www.gnu.org/software/bison/", donate: [("Donate to the FSF", "https://my.fsf.org/donate")]),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Nokcandu stands on the work of these open-source projects. If one of them helps you play, consider supporting it.")
                    .foregroundStyle(.secondary)
                ForEach(Self.groups) { g in
                    SettingsSection(title: g.title) {
                        ForEach(Array(g.projects.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Divider() }
                            row(p)
                        }
                    }
                }
                Text("Nokcandu also downloads some components that aren't open source, from their makers, when a game needs them: Apple's D3DMetal (part of the Sikarugir engine), NVIDIA PhysX, and Microsoft's DirectX and Visual C++ runtimes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    func row(_ p: Project) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.body.weight(.semibold))
                    Text(p.license).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().stroke(.secondary.opacity(0.4)))
                }
                Text(p.by).font(.caption).foregroundStyle(.secondary)
                Text(p.what).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let u = URL(string: p.site) { Link("Website", destination: u) }
                ForEach(p.donate, id: \.1) { d in
                    if let u = URL(string: d.1) {
                        Link(destination: u) { Label(d.0, systemImage: "heart") }
                    }
                }
            }
            .font(.callout)
        }
    }
}
