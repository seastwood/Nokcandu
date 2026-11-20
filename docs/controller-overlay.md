# Controller overlay

Controls → Controller Settings → **Controller overlay** (November 19, 2026): a 3D controller showing the buttons,
sticks, triggers and trackpads as they're used, turning with the gyro. For streaming or recording.

- **Show**: *Over games and streams*, a click-through panel above everything (full-screen games and streams too),
  dragged into place with **Move Overlay…** (position saved as a fraction of the screen, with the screen's name);
  *In its own window (for OBS)*, a resizable window to add as a macOS Screen Capture source set to Window, best with
  **Background → Colour** and a Chroma Key filter; or *Off*. Closing the window turns it off.
- **Size**, **Opacity**, **Body**, **Buttons**, **Pressed** and **Background** colours, **Turn with the gyro**,
  **Movement shown** (0–150%) and **Recentre**. Everything applies at once; settings are one JSON value in
  UserDefaults (`controllerOverlay`, `ControllerOverlaySettings`), decoded tolerantly.
- **Controller**: *The controller in use* (default) or one drawing always: Steam Controller (2015), Steam Controller
  (2026), Xbox, Switch Pro Controller, DualShock 4 / DualSense. Sources are read like the remapper reads them and left
  unchanged: Steam Controllers from `SteamControllerUSB`; controllers Nokcandu drives itself or maps
  (`MappedGamepads`, with their motion); controllers macOS knows (`GCController`, Steam ones excluded), looked at 60
  times a second while one is connected, with no handlers replaced. The one shown is the last used (a button, a pad
  touched, a stick or trigger pushed past about a third); its drawing comes from its name
  (`ControllerOverlaySettings.Model.forName`, Xbox's for anything unknown). Gravity's sign differs between sources:
  one that reads up as negative at first is turned round. Settings saved by the first version (only "steam2015")
  become *The controller in use*.

## How it's built

- Each drawing is an `OverlayLayout` (body outline plus parts: buttons, d-pad, sticks, trackpads, bumpers, triggers,
  grip and back buttons) built by `OverlayControllerModel` from SceneKit shapes; the 2026 controller uses the editor's
  own outline and landmarks (`Steam2026PictureGeometry`). Triggers sit raised behind the bumpers so they show from the
  front: part pulled, a soft colour and a filling bar; fully pulled, solid. Sticks light while moved. Its axes are the
  gyro's (x right, y out of the face, z towards the player), so motion applies directly.
- Motion (`ControllerOverlayMotion`, NokcanduCore): the gyro integrated as a quaternion; gravity from the
  accelerometer corrects the tilt (2/s, only between 0.8 and 1.2 g so shakes don't count); with no compass, the
  heading returns to the front (0.25/s); a slowly followed bias and a small dead zone keep a resting gyro still.
  Tests: `ControllerOverlayTests`.
- Efficiency: the SceneKit view doesn't render continuously. Each report updates the motion filter (cheap); a draw
  is scheduled at most 60 times a second and skipped unless the input looks different (`looksLike`: within 1%) or
  the drawing would turn more than a fifth of a degree. A controller at rest draws nothing.
- Anything drawn over a full-screen stream stops macOS sending the stream's frames straight to the display, which
  can add a millisecond or two; the setting says so.
