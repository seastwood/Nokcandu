import XCTest
@testable import NokcanduCore

/// Runs against the throwaway test support folder (NokPaths.support while testing), never the real library.
final class LibraryCategoryTests: XCTestCase {
    override func setUp() { LibraryOrganizer.save(LibraryOrganizer.Saved()) }
    override func tearDown() { LibraryOrganizer.save(LibraryOrganizer.Saved()) }

    func testAddRenameReorderAndRemoveKeepItemsConsistent() throws {
        XCTAssertEqual(LibraryOrganizer.categories, [])
        XCTAssertEqual(try LibraryOrganizer.addCategory("  Tools "), "Tools")
        XCTAssertEqual(try LibraryOrganizer.addCategory("tools"), "Tools", "the same name in another case is the same category")
        try LibraryOrganizer.addCategory("Shooters")
        XCTAssertThrowsError(try LibraryOrganizer.addCategory("   "))
        XCTAssertEqual(LibraryOrganizer.categories, ["Tools", "Shooters"])

        var saved = LibraryOrganizer.load()
        saved.categoryOf = ["a.app": "Tools", "b.app": "Shooters", "c.app": "Gone"]
        saved.favorites = ["a.app"]; saved.order = ["b.app"]
        LibraryOrganizer.save(saved)
        XCTAssertEqual(LibraryOrganizer.categoryKeys, ["a.app": "Tools", "b.app": "Shooters"], "a removed category's items are uncategorized")

        LibraryOrganizer.setCollapsed("category:Tools", true)
        try LibraryOrganizer.renameCategory("Tools", to: "Utilities")
        XCTAssertThrowsError(try LibraryOrganizer.renameCategory("Utilities", to: "shooters"))
        XCTAssertEqual(LibraryOrganizer.categoryKeys["a.app"], "Utilities")
        XCTAssertEqual(LibraryOrganizer.collapsedSections, ["category:Utilities"])

        LibraryOrganizer.moveCategory("Shooters", by: -1)
        XCTAssertEqual(LibraryOrganizer.categories, ["Shooters", "Utilities"])
        LibraryOrganizer.moveCategory("Shooters", by: -1)
        XCTAssertEqual(LibraryOrganizer.categories, ["Shooters", "Utilities"])

        LibraryOrganizer.removeCategory("Utilities")
        XCTAssertEqual(LibraryOrganizer.categories, ["Shooters"])
        XCTAssertNil(LibraryOrganizer.categoryKeys["a.app"])
        XCTAssertEqual(LibraryOrganizer.collapsedSections, [])
        // Favorites and the custom order are untouched by any of it.
        XCTAssertEqual(LibraryOrganizer.load().favorites, ["a.app"]); XCTAssertEqual(LibraryOrganizer.load().order, ["b.app"])
    }

    func testOlderSavedLibraryDecodesWithNoCategories() throws {
        let old = try JSONDecoder().decode(LibraryOrganizer.Saved.self, from: Data(#"{"sort":"name","order":[],"favorites":["x"],"played":{}}"#.utf8))
        XCTAssertNil(old.categories); XCTAssertNil(old.categoryOf); XCTAssertNil(old.collapsed)
        XCTAssertEqual(old.favorites, ["x"])
    }
}
