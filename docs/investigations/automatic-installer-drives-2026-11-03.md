# Unmounted installer images left in Windows drive lists — 2026-11-03

## Evidence and scope

The same removed ET Legacy installer image appeared as D: in three private environments: Warcraft III, the older Battlefield test app and EA app. EA's child games inherit the host's mappings, explaining why an unrelated installer appeared throughout the library. Each D: link targeted the old `/Volumes/` mount and had a matching D:: raw-device link; EA's separate E: content mapping was unrelated and must remain intact. Wine's macOS mount-manager source automatically adds removable-media mappings. That explains the observed structure, but the historical creation event was not captured.

An absent volume alone is insufficient evidence for deletion: a disconnected external game drive looks similar. Blanket deletion of disconnected mappings and hardcoded installer-name exclusions were rejected. Unknown existing mappings are preserved.

## Shared implementation

`AutomaticDriveMappings` snapshots drive letters around managed wineboot initialization/update. It records only newly created letters with a raw-device link whose exact target is a currently attached macOS disk image, as reported by the existing disk-image discovery API. Nokcandu's Add Drive records explicit ownership separately. Failure to record metadata leaves mappings untouched and does not abort installation or engine updates.

Background library refresh and the Drives section reconcile recorded mappings only when the Windows environment has reliably stopped, the volume is unmounted, both symlink targets still match, and the letter has no protected references. Configured game discs, explicit Add Drive mappings, program/argument/environment paths, text launcher scripts and registry paths protect the letter. Shared-host peers are checked together. Mutation is serialized so overlapping refreshes cannot partially remove or restore a link pair. No work is scheduled for hosts without pending records.

Removal deletes only drive symlinks, including the raw-device companion. It does not remove a volume, device, game file, registry value, save, launcher or another drive letter. Remove in Files & Tools now clears the companion too. Drive availability uses actual mount presence, avoiding ghost `/Volumes` directories being labeled connected. Undo runs off the UI thread.

## Migration and Undo

Existing unidentified mappings are never automatically adopted. The user's explicit request authorizes enrolling the three exact old ET Legacy mappings as user-requested removals; this is local metadata, not a game-specific code exception. The same guarded reconciliation performs cleanup. A recovery record is written before unlinking. Files & Tools offers **Undo drive cleanup**; it restores only unoccupied letter/device slots and treats the restored mapping as an explicit choice, preventing repeated cleanup. Existing letters are never renumbered.

Newly attached images during arbitrary unmanaged Wine runs are not retroactively classified. Mounted images remain visible until unmounted and a later refresh can safely reconcile them. Configured discs deliberately remain visible even when unmounted. No background system service or global drive blacklist is added. This is local media ownership, not a transferable game compatibility fix; machine-specific image paths are not exported in profiles.

## Validation

Seven isolated regressions cover new-image ownership, unrelated offline disks, unknown preexisting mappings, explicit Add Drive choices, disc/program/environment/registry/manual-launcher protection, busy or changed environments, occupied Undo slots, paired removal preserving target files, and concurrent reconciliation. Test fixtures create symlinks in temporary directories; they do not mount or write to fake `/Volumes` or `/dev` targets. The initial fixture mistakenly reused an existing E: letter; it was corrected to F: before validation.

Final full suite: 277 tests executed, 10 optional tests skipped, zero failures. Production build and deep signature verification passed. The preview performed guarded cleanup in all three enrolled environments; both old D: and D:: links disappeared and recovery records were retained. EA E: still resolves to its connected Elements content folder. The EA Files & Tools UI shows E: and Undo drive cleanup without the stale installer entry; its three external game paths remain listed. The signed update was installed with the prior app retained outside Applications for rollback. No game was launched or stopped for this migration; gameplay was not retested for this drive-list-only change.
