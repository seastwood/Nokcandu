/* SPDX-License-Identifier: LGPL-2.1-or-later
 * The original wired Steam Controller uses a vendor HID interface; it is not a
 * keyboard or mouse. Receiver/BLE/Deck support requires separate live validation. */
#include <stdint.h>
#include <stdbool.h>
static bool nok_steam_wired_interface(uint32_t vendor, uint32_t product, bool usb,
                                      uint32_t page, uint32_t usage)
{
    return vendor == 0x28de && product == 0x1102 && usb && page == 0xff00 && usage == 1;
}
