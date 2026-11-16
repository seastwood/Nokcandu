# Nintendo Switch 2 controllers

The Switch 2 Pro Controller (057E:2069) and the GameCube controller for Switch 2 (057E:2073), by USB cable.
Added November 15, 2026, **without the controllers to test against**; the protocol follows SDL's driver
(`src/joystick/hidapi/SDL_hidapi_switch2.c`).

- Over USB they send nothing until started: `Switch2USB` opens their interface 1 with macOS's USB host framework
  (IOUSBHost), reads the stick calibration from flash (factory, then the user's if present; the GameCube
  controller's trigger rest points), sends SDL's start-up sequence and lights player light 1.
- Reports then arrive on the HID interface: buttons (bytes 5–8), 12-bit sticks (11–16), GameCube analog triggers
  (61, 62), motion (0x31–0x3c). `Switch2Controller.decode` turns them into a standard controller, published through
  `MappedGamepads`, so profiles treat it like any controller.
- Pro Controller buttons are by their printed letters (as macOS reports Nintendo controllers); GameCube buttons
  by position. Capture is `misc`, the C button `paddle3`, the Pro's back buttons GR/GL `paddle1`/`paddle2`.
- Motion is turned into Nokcandu's axes using SDL's axes for the original Steam Controller as the bridge; the
  gyro's full scale is SDL's 34.8 rad/s (its timestamp check that can switch it to 40 isn't done).
- Not done: Joy-Con 2 (left 2067, right 2066), rumble, Bluetooth (SDL can't either). A controller macOS's own
  controller support reads is left to it.

Check on first use: Controllers.log says whether it was found and started; then the buttons, stick directions and
which way the gyro turns.
