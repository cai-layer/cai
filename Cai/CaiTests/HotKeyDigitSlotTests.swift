import XCTest
import AppKit
@testable import Cai

/// MARK: (P1) Hotkey-digit slots: ⌥C then ⌥2 runs pinned action #2.
/// Locks down the shipping bugs this rule could cause: a slot firing while the
/// user types ⌥digit (¡™£) in a text editor, a held key auto-repeating into a
/// second slot or destination, and a rebound hotkey (⇧-only, ⌘, ⌃) making digits
/// hijack the filter or answer to the wrong modifier.
final class HotKeyDigitSlotTests: XCTestCase {

    func testSlotDecision() {
        let one: UInt16 = 18, zero: UInt16 = 29, letterS: UInt16 = 1
        let rows: [(String, UInt16, NSEvent.ModifierFlags, NSEvent.ModifierFlags, Bool, Bool, Int?)] = [
            // label,                         key,    held,                 hotkey,            passThrough, repeat, expected
            ("default ⌥1",                    one,    [.option],            [.option],         false, false, 1),
            ("⌥0 opens history",              zero,   [.option],            [.option],         false, false, 0),
            ("⌥⇪1: caps lock ignored",        one,    [.option, .capsLock], [.option],         false, false, 1),
            ("⌥⇧1: shift ignored",            one,    [.option, .shift],    [.option],         false, false, 1),
            ("⌥1 in a text editor",           one,    [.option],            [.option],         true,  false, nil),
            ("⌥1 auto-repeat",                one,    [.option],            [.option],         false, true,  nil),
            ("⌥⌃1 with ⌥ hotkey",             one,    [.option, .control],  [.option],         false, false, nil),
            ("bare 1 filters",                one,    [],                   [.option],         false, false, nil),
            ("⌥ + letter",                    letterS, [.option],           [.option],         false, false, nil),
            ("⌃ hotkey: ⌃1",                  one,    [.control],           [.control],        false, false, 1),
            ("⌃ hotkey: ⌥1 is not a slot",    one,    [.option],            [.control],        false, false, nil),
            ("⌥⇧ hotkey: ⌥1",                 one,    [.option],            [.option, .shift], false, false, 1),
            ("⇧-only hotkey: feature off",    one,    [.shift],             [.shift],          false, false, nil),
            ("⌘ hotkey: feature off",         one,    [.command],           [.command],        false, false, nil),
        ]
        for (label, key, held, hotkey, passThrough, isRepeat, expected) in rows {
            XCTAssertEqual(
                WindowController.hotKeyDigitSlot(
                    keyCode: key, modifiers: held, hotKeyModifiers: hotkey,
                    passThrough: passThrough, isRepeat: isRepeat
                ),
                expected,
                label
            )
        }
    }
}
