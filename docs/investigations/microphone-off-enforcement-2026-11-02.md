# Microphone-off enforcement — 2026-11-02

## Report and confirmed gaps

The user reported microphone prompts despite the per-game switch being off,
possibly in Warcraft III. The title was tentative; this is a shared-infrastructure
regression, not a Warcraft recipe. Inspection confirmed three separate gaps:

- General launchers exported NOKCANDU_NO_MICROPHONE only immediately before the
  game, after an earlier Wine registry/setup call. Wine tools did not carry the
  same microphone policy/helper environment.
- The audio-follow helper registered a default-input listener even with microphone
  off. Calls made within the same dylib are not protected by its own dyld interpose
  table, so default-input queries need an explicit shared policy check.
- Hiding input enumeration alone did not guard AudioUnit EnableIO. Cached Windows
  endpoints could still attempt capture setup. Shared Steam shortcuts also ignored
  their custom microphone value; an enabled child needed an explicit override of
  its parent's disabled state.

These are demonstrated code-path gaps. The exact OS request that produced the
original dialog has not been retrospectively traced to one individual call.

## Shared correction

Managed private and hosted scripts apply explicit 1/0 microphone policy before
Wine/bootstrap commands, after extra environment values where needed. The Windows
registry environment carries it for launcher-created child environments. Wine
setup/tools use the same policy and helper. Explicit on clears an inherited off;
explicit off takes precedence over conflicting advanced launcher variables.

The audio guard no longer caches a possibly stale inherited value. It also reads
the generated per-program policy directly before relying on constructor-applied
environment values. This avoids a shared-launcher initialization-order gap. Shared
Steam per-game policies travel with existing per-program settings; refreshing the
library or changing the switch refreshes those entries. Steam's client has its own
explicit opt-in switch, independent of the game's choice, so disabling the client
by default does not remove the ability to use Steam voice chat.

Audio enumeration reports no input devices when blocked. The shared audio-follow
code skips input-device queries/listeners and rejects capture EnableIO before
calling CoreAudio. Output property, playback and device-follow behavior remain
forwarded. Guard decisions cover helper-internal calls as well as interposed Wine
calls. No game-name exception, removed Info.plist usage description, system privacy
reset, revoked OS consent, microphone recording or root execution is involved.

## Fresh installs, migration and Undo

Fresh scripts use the corrected policy ordering. Existing unchanged generated
launchers refresh through the normal shared paths; manually edited scripts remain
preserved. The shared helper is updated in private environments through the normal
library refresh, leaving already loaded inodes valid until processes exit. Restart
the game for the new library; restart a shared client to change that client's own
policy. Do not terminate another game's session just to replace a mapped library.
Explicit microphone choices in game/hosted settings are preserved. Imported profiles
do not grant macOS microphone permission.

The current switch remains the user-facing Undo: explicitly enabling input permits
capture and normal macOS consent; disabling blocks it on a fresh launch. Launcher
changes retain their existing journal. Rolling back the guard binaries/source would
restore the previous faulty enforcement, rather than undo an OS permission change.
No game content, saves, engine driver or macOS privacy settings are modified.

## Verification boundaries

Native tests replace every CoreAudio and AudioUnit boundary with fakes. Off makes
zero default-input queries/listeners and zero forwarded capture enables, while
output calls still succeed. On forwards capture operations to the fakes. Tests also
cover inherited policy changes, shared-client separation, pre-constructor table
lookup, distinct per-game settings, and actual generated shell execution: the first
Wine registry command and game command both receive the correct policy.

A 32-bit endpoint probe used Warcraft's Wine 11 engine in a separate temporary
prefix with the guard injected and input disabled. Windows reported **zero input
devices and four output devices**, exit 0. The probe enumerates endpoints and never
opens, records or plays a stream; no real microphone-on hardware test was run.
The first full suite passed 229 tests with seven optional skips before the final
two policy tests were added; focused tests then passed all five. Final full-suite,
signed packaging, and a fresh game-launch result are recorded below when complete.
The subsequent user confirmation and saved-policy tests are recorded below.


## Live retest and environment-independent hardening

The user confirmed the fresh Warcraft launch showed **no microphone prompt**.
The actual game spawned a second executable after its launcher exited. A shared
startup-monitor correction now follows foreground Windows children in the same
private prefix instead of reporting the bootstrap exit as failure. It excludes
shared-store environments and checks native process ownership; no game filename
exception is used.

Mic policy also persists beside the injected helper: microphone-policy contains
the private-prefix default, and program-microphones.tsv contains shared-prefix
per-program choices. The guard locates these through its own loaded path, not an
inherited WINEPREFIX or microphone environment variable. Shared prefixes default
to blocked for unknown children; explicit client and game opt-ins have separate
routes. Exact paths/Steam IDs outrank ambiguous basenames, and conflicting routes
at equal priority choose blocked. This handles child environments rebuilt by a
bootstrap and preserves game-specific choices without changing rendering policy.
Generated launch environments remain explicitly set as an additional layer.

The saved-policy probe was repeated with NOKCANDU_NO_MICROPHONE deliberately absent:
it still reported zero inputs and four outputs. An output-only stream successfully
opened and closed, with no buffers queued and no sound played. Native fake-boundary
tests also prove that the saved policy wins with the variable missing or conflicting.
The full suite passed **233 tests, seven optional skips, zero failures**.

Important evidence boundary: macOS logged microphone capability checks during the
output-only stream as well as the game. Such a TCC check is not itself proof that
an input stream was opened or a permission dialog appeared. The implementation's
boundary guarantee is zero input endpoints and rejected capture enables when off;
the user confirmed no visible dialog. Existing OS consent/denial was not reset to
manufacture a fresh prompt. A real microphone-on recording test was not performed.
The initial UI confirmation preceded this extra saved-policy hardening; that
hardening is independently covered by the stripped-environment/output-only probe.


The final signed update, including saved-policy enforcement and bootstrap-child
tracking, was installed with a recoverable previous-app copy. Running games were
left intact; already mapped older helper images take the final changes on their
next full restart. The live no-dialog observation and the independent saved-policy
capture/output tests are separate evidence, not a claim of testing every game.
