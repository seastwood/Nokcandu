# Pointer-picked radial menus - November 11, 2026

User's field report requests mouse/gyro direction selection for held radial menus and automatic action titles. Implemented incrementally in the existing engine, retaining old profile IDs, stick choices and output ownership.

## Behavior

Menu picker 0/1 retains left/right stick; new 2 selects relative mouse direction. The most recent nonzero finite vector chooses the clockwise sector (up first); zero/invalid vectors retain selection. The held opening button commits once on release. Focus release, source removal and other existing cancellation paths close without committing. Opening again starts unselected. All access to the two-element stick array is guarded for the new pointer picker.

The engine intercepts gyro/stick/touchpad mouse output before its OS sink while this menu is open. Desktop headphone mouse output enters the same picker, and the existing physical-mouse global monitor observes hardware direction without a new tap, permissions or recording typed data. Physical pointer movement itself is not suppressed. Controller-generated mouse motion resumes when the menu closes. Existing physical sticks retain their ordinary mappings unless their mouse output is consumed; selected-stick menus remain unchanged. This is not an independent virtual controller output source.

New radial choices leave custom Title blank and derive their displayed name from the configured outputs. Editing Title overrides the automatic name; clearing it restores automatic naming. Existing saved labels, including Up/Right/Down/Left, remain exact user choices and are not renamed during migration.

## Validation / limitations / Undo

Actual-engine tests cover four directions, latest-direction selection, zero/NaN/infinite samples, release-only actions, focus cancellation, fresh opening, gyro selection without desktop output and restored motion after close. Existing stick choice behavior and saved profile compile/JSON round-trip pass. Automatic title updates and explicit/legacy label preservation pass. Combined suite: 272 tests, two optional skips, zero failures. Installed UI verified: the existing Steam Controller profile shows Left stick, Right stick and Mouse / gyro direction in Pick with, and automatic-title guidance. Existing profile mappings/titles were not edited. Live physical-pointer acceptance remains pending.

No migration is required for old profiles (picker 0/1 unchanged). New option requires this engine version. Undo through the profile editor or choose a stick again; existing profile Undo/backups apply. Do not claim head/controller hardware menu acceptance from software tests alone.


Final broader validation: full suite 589 tests, zero failures/19 explicit optional integration skips. Existing header/library packaging compiled, and the signed app exposes the picker. No claim of physical hardware/menu game acceptance from unit tests.
