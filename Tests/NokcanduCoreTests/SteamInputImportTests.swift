import XCTest
@testable import NokcanduCore

final class SteamInputImportTests: XCTestCase {
    /// A small layout written for this test, in Steam Input's format.
    static let layout = #"""
    "controller_mappings"
    {
        "version"   "3"
        "title"     "Test Layout"
        "controller_type"   "controller_steamcontroller_gordon"
        "actions" { "Default" { "title" "Default" "legacy_set" "1" } }
        "action_layers" { "Preset_1000001" { "title" "Crouched" "legacy_set" "1" "set_layer" "1" "parent_set_name" "Default" } }
        "group" { "id" "0" "mode" "four_buttons" "inputs" {
            "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press SPACE, Jump, , " } } } }
            "button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press E, , " } }
                                        "Long_Press" { "bindings" { "binding" "key_press F, , " } "settings" { "long_press_time" "400" } } } }
            "button_x" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_SHIFT, , " } "settings" { "toggle" "1" } } } }
            "button_y" { "activators" { "release" { "bindings" { "binding" "key_press G, , " } } } }
        } }
        "group" { "id" "1" "mode" "radial_menu" "inputs" {
            "touch_menu_button_0" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 1, , " } } } }
            "touch_menu_button_1" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 2, , " } } } }
            "touch_menu_button_4" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 5, , " } } } }
            "click" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_button LEFT, , " } } } }
        } }
        "group" { "id" "2" "mode" "absolute_mouse" "inputs" {
            "click" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action hold_layer 2 1 0, , " } } } }
        } }
        "group" { "id" "3" "mode" "dpad" "inputs" {
            "dpad_north" { "activators" { "Full_Press" { "bindings" { "binding" "key_press W, , " } } } }
            "dpad_south" { "activators" { "Full_Press" { "bindings" { "binding" "key_press S, , " } } } }
            "click" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_CONTROL, , " } } } }
            "edge" { "activators" { "Full_Press" { "bindings" { "binding" "key_press LEFT_SHIFT, , " } } } }
        } }
        "group" { "id" "4" "mode" "trigger" "inputs" {
            "edge" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_button RIGHT, , " } } } }
            "click" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_wheel SCROLL_DOWN, , " } } } }
        } }
        "group" { "id" "5" "mode" "gyro_to_mouse" "inputs" { } "settings" { "gyro_button" "1" } }
        "group" { "id" "6" "mode" "switches" "inputs" {
            "button_back_left" { "activators" { "Full_Press" { "bindings" { "binding" "mode_shift joystick 7, , " } } } }
            "left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "game_action Default jump, , " } } } }
        } }
        "group" { "id" "7" "mode" "joystick_mouse" "inputs" { } }
        "group" { "id" "8" "mode" "four_buttons" "inputs" {
            "button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press C, , " } } } }
        } }
        "preset" { "id" "0" "name" "Default" "group_source_bindings" {
            "0" "button_diamond active" "1" "left_trackpad active" "2" "right_trackpad active" "3" "joystick active"
            "4" "left_trigger active" "5" "gyro active" "6" "switch active" "7" "joystick inactive modeshift"
        } }
        "preset" { "id" "1" "name" "Preset_1000001" "group_source_bindings" { "8" "button_diamond active" } }
    }
    """#

    func testASteamControllerLayoutBecomesAProfile() throws {
        let r = try SteamInputImport.profile(fromVDF: Self.layout, fallbackName: "x")
        let p = r.profile, base = p.layers[0]
        XCTAssertEqual(p.name, "Test Layout")
        XCTAssertEqual(p.controllerSource, .steamUSB); XCTAssertEqual(p.controllerLabels, "valve")
        XCTAssertEqual(base[.a]?.press, [.key(49)])
        XCTAssertEqual(base[.b]?.tap, [.key(14)]); XCTAssertEqual(base[.b]?.hold, [.key(3)]); XCTAssertEqual(base[.b]?.holdTime, 0.4)
        XCTAssertEqual(base[.x]?.togglePress, true); XCTAssertEqual(base[.x]?.press, [.keyToggle(56)])
        XCTAssertEqual(base[.y]?.release, [.key(5)])
        // Radial menu: a buttons trackpad, items in order.
        XCTAssertEqual(p.steamLeftTrackpad?.mode, .buttons); XCTAssertEqual(p.steamLeftTrackpad?.zoneLayout, .ring6)
        XCTAssertEqual(base[.lpt1]?.press, [.key(18)]); XCTAssertEqual(base[.lpt5]?.press, [.key(23)])
        XCTAssertEqual(base[.touchpad]?.press, [.mouse(.left)])
        // Right pad: mouse; its click holds the "Crouched" layer.
        XCTAssertEqual(p.steamRightTrackpad?.mode, .mouse)
        XCTAssertEqual(p.layers.map(\.name).contains("Crouched"), true)
        XCTAssertEqual(base[.rs]?.press, [.layerHold("Crouched")])
        // Joystick as directions, its click and outer ring.
        XCTAssertEqual(p.leftStick?.mode, .directions)
        XCTAssertEqual(base[.lsup]?.press, [.key(13)]); XCTAssertEqual(base[.lsdown]?.press, [.key(1)])
        XCTAssertEqual(base[.ls]?.press, [.key(59)]); XCTAssertEqual(base[.lsring]?.press, [.key(56)])
        // Trigger: soft pull and full pull.
        XCTAssertEqual(base[.lt]?.press, [.mouse(.right)]); XCTAssertEqual(base[.ltfull]?.press, [.wheel(up: false)])
        XCTAssertEqual(p.gyro?.output, .mouse)
        // The layer's own binding, and a mode shift as a layer held while the back grip is.
        let crouched = try XCTUnwrap(p.layers.first { $0.name == "Crouched" })
        XCTAssertEqual(crouched[.a]?.press, [.key(8)])
        let shift = try XCTUnwrap(p.layers.first { $0.name.hasPrefix("Mode shift") })
        XCTAssertEqual(base[.paddle2]?.press, [.layerHold(shift.name)])
        XCTAssertEqual(shift.leftStick?.mode, .mouse)
        // What couldn't come across is said.
        XCTAssertTrue(r.notes.contains { $0.contains("game actions") })
        XCTAssertTrue(r.notes.contains { $0.contains("activation") })
        // It compiles for the engine.
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains("bind 0 a press=key:49"))
    }

    func testNotALayout() {
        XCTAssertThrowsError(try SteamInputImport.profile(fromVDF: "\"something\" { }", fallbackName: "x"))
    }
}
