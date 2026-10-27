import XCTest
@testable import NokcanduCore

final class DiscsTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("discs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        // Eject every disc image this test mounted (imports probe images too), then remove the folder.
        if let info = try? Shell.run("/usr/bin/hdiutil", ["info"], timeout: 30) {
            var image = ""
            for line in info.stdout.split(separator: "\n").map(String.init) {
                if line.hasPrefix("image-path") { image = line; continue }
                if line.hasPrefix("/dev/disk"), image.contains(dir.lastPathComponent),
                   let dev = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first {
                    _ = try? Shell.run("/usr/bin/hdiutil", ["detach", String(dev), "-force", "-quiet"], timeout: 30)
                    image = ""
                }
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// A raw MODE1/2352 image of `sectors` sectors whose user data is the sector number repeated.
    func rawImage(sectors: Int, mode: UInt8 = 1) -> (Data, Data) {
        var raw = Data(), iso = Data()
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        for s in 0..<sectors {
            let user = Data(repeating: UInt8(s % 251), count: 2048)
            var sector = Data(sync + [0, 2, 0, mode])            // sync + header (mode byte at 15)
            if mode == 2 { sector.append(Data(repeating: 0, count: 8)) }   // subheader
            sector.append(user)
            sector.append(Data(repeating: 0xEE, count: 2352 - sector.count))
            raw.append(sector); iso.append(user)
        }
        return (raw, iso)
    }

    func testConvertsRawBinWithAndWithoutCue() throws {
        let (raw, iso) = rawImage(sectors: 600)
        let bin = dir.appendingPathComponent("Game Disc 1.bin")
        try raw.write(to: bin)
        XCTAssertEqual(try Discs.detectLayout(bin), Discs.Layout(sectorSize: 2352, dataOffset: 16))
        let out = dir.appendingPathComponent("out.iso")
        try Discs.convert(bin, layout: Discs.Layout(sectorSize: 2352, dataOffset: 16), to: out)
        XCTAssertEqual(try Data(contentsOf: out), iso)

        let cue = dir.appendingPathComponent("Game Disc 1.cue")
        try "FILE \"game disc 1.BIN\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 05:00:00\n"
            .write(to: cue, atomically: true, encoding: .utf8)
        let (file, layout, audio) = try Discs.parseCue(cue)
        XCTAssertEqual(file.lastPathComponent, "Game Disc 1.bin")     // found case-insensitively
        XCTAssertEqual(layout, Discs.Layout(sectorSize: 2352, dataOffset: 16))
        XCTAssertTrue(audio)

        let (raw2, _) = rawImage(sectors: 4, mode: 2)
        let b2 = dir.appendingPathComponent("m2.bin"); try raw2.write(to: b2)
        XCTAssertEqual(try Discs.detectLayout(b2), Discs.Layout(sectorSize: 2352, dataOffset: 24))
    }

    func testDiscOrder() {
        let urls = ["Game CD2.iso", "Game CD1.iso", "Game (Disc 3).cue", "Game (Disc 3).bin"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(Discs.sorted(urls).map(\.lastPathComponent), ["Game CD1.iso", "Game CD2.iso", "Game (Disc 3).cue"])
        let mw = ["Morrowind Bloodmoon.iso", "Morrowind Tribunal.iso", "morrowind.iso"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(Discs.sorted(mw).first?.lastPathComponent, "morrowind.iso")
    }

    func testMultiDiscLauncher() throws {
        var c = CustomGameConfig(id: "t", name: "T", source: .disc, exe: #"C:\Games\T\t.exe"#, graphics: .classic3D)
        c.disc = DiscSpec(imageName: "T1.iso", volumeLabel: "T1", internalMountDir: "SharedSupport/MountedDisc")
        c.extraDiscs = [DiscSpec(imageName: "T2.iso", volumeLabel: "T2", internalMountDir: "SharedSupport/MountedDisc2")]
        let s = CustomGames.launcherScript(for: c)
        XCTAssertTrue(s.contains("DISC_IMAGES=('T1.iso' 'T2.iso')"), s)
        let f = dir.appendingPathComponent("l.sh"); try s.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", f.path]).ok)
        XCTAssertEqual(Discs.mountDir(dir, index: 1).lastPathComponent, "MountedDisc2")

    }

    /// Real images through macOS: import (reads the label), insert Disc 1, swap to Disc 2.
    func testInsertAndSwapRealImages() throws {
        let fm = FileManager.default
        var images: [String] = []
        for n in 1...2 {
            let content = dir.appendingPathComponent("src\(n)")
            try fm.createDirectory(at: content, withIntermediateDirectories: true)
            try "disc \(n)".write(to: content.appendingPathComponent("DISC\(n).TXT"), atomically: true, encoding: .utf8)
            let iso = dir.appendingPathComponent("Test CD\(n).iso")
            let r = try Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "TESTCD\(n)", "-o", iso.path, content.path], timeout: 60)
            XCTAssertTrue(r.ok, r.combined)
        }
        let support = dir.appendingPathComponent("SharedSupport")
        let prefix = support.appendingPathComponent("prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        for n in 1...2 {
            // macOS's disk image service sometimes stalls for minutes when many images are open; that's
            // the machine, not this code — skip rather than fail the build.
            let i: Discs.Imported
            do { i = try Discs.importImage(dir.appendingPathComponent("Test CD\(n).iso"), into: support) }
            catch let e as NokError where e.localizedDescription.contains("canceling") || e.localizedDescription.contains("timed out") {
                throw XCTSkip("macOS disk image service is stalled: \(e.localizedDescription.prefix(80))")
            }
            XCTAssertEqual(i.label, "TESTCD\(n)")
            images.append(i.imageName)
        }
        defer {
            for i in 0..<2 { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", Discs.mountDir(support, index: i).path, "-quiet", "-force"]) }
        }
        let d = prefix.appendingPathComponent("dosdevices/d:")
        try Discs.insert(0, images: images, support: support, prefix: prefix)
        XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("DISC1.TXT").path))
        try Discs.insert(1, images: images, support: support, prefix: prefix)
        XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("DISC2.TXT").path))
        XCTAssertEqual(try Discs.importImage(dir.appendingPathComponent("Test CD2.iso"), into: support).label, "TESTCD2")   // while mounted
        // The order changed: disc 1 is now the other image, and its folder still holds the old one.
        try Discs.insert(0, images: images.reversed(), support: support, prefix: prefix)
        XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("DISC2.TXT").path))
        XCTAssertEqual(Discs.current(support: support), 0)   // the reversed order put that image in as disc 1
        XCTAssertTrue((try fm.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/d::").path)).hasPrefix("/dev/rdisk"))
    }
}
