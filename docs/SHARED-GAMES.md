# Shared games

Management is at `/EpicVM/Management`. The normal Portal dashboard lists only
games assigned to machines the user can access. Game administration requires
the existing administrator session and CSRF token.

## Operator flow

1. Choose **Add Game**, a title and stable ID.
2. Prefer an existing host installation. Supported detection includes OpenFL,
   publisher `pkg_version` distributions, packaged Unreal games and versioned
   Qt/CEF HoYoPlay payloads. Unknown installed folders fail closed.
3. A clean ZIP can be uploaded or downloaded from HTTPS. Both require its
   SHA-256. This is distribution extraction, not unattended execution of
   arbitrary EXE/MSI installers.
4. Select the gaming VM, check its games and apply. The VM must be running and
   the dashboard's guest operator credentials must match that VM.
5. Open the generated `EpicVM - <id>` shortcut on the VM desktop.

Codex is an explicit last-priority choice. It runs under the host desktop
operator in a restricted workspace, saves reusable discovery instructions,
and passes results through the deterministic importer. It does not copy game
account state. A saved compatible source is reused before requesting another
agent run. Arbitrary unsupported installer recipes still require review.

## Isolation and updates

The library is `E:\EpicVM\game-library`. Imports create immutable releases;
only selected distribution files enter a release. Known profile, session,
cookie, save, log and cache paths are excluded. Host AppData and launcher
registry/account settings are not migrated. Filename filtering is combined
with format-specific allowlists; it is not a universal secret scanner.

Each VM gets its own SMB account and read-only share containing assigned
release links. Executables/launcher state are materialized inside the VM;
large package content uses read-only links. VM-local state directories survive
release changes. Existing games' other save locations depend on their engines.
Guest operator credentials travel through the authenticated server/agent path,
are protected using machine DPAPI and administrator/System ACLs for the worker,
and are removed after the job. They are omitted from job JSON and browser data.

Update the host installation normally, then choose **Refresh from host
installation** and reapply the VM's selection. The old release stays available
until assignments change. ZIP updates can be submitted again under the same
game ID with a new archive/checksum. Retained releases are not automatically
garbage-collected. Publisher updates cannot write into shared content from a VM.

## Verification on 2026-09-20

- FNF Dustin imported from `C:\Users\Epic\Desktop\FNF\FNF Dustin` and
  assigned to `astra-testmann`. Its final release is
  `b42a8feffda842668c813887c0728bbc`.
- The guest sees the content and shortcut; its write probe was rejected.
  FNF rendered its warning screen using the pinned Mesa software OpenGL
  compatibility option. Full gameplay performance and audio are not certified.
- Live public Management displayed the catalog and completed an assignment
  change through the background worker. Guest inspection confirmed the result.
- The browser fixture verified local-path Add Game, catalog, assignment,
  removal, normal-user dashboard visibility, mobile width and no JS errors.
- 15 API/account tests and 20 distribution/isolation assertions passed.
- A real HoYoPlay refresh created a new release while retaining the previous
  generation. ZZZ, HoYoPlay and NTE were imported without copying host profile
  folders, but their VM work was canceled by the user and their assignments
  removed. Host installations were not changed. Their active catalog entries
  were removed; imported release files remain retained for reversible cleanup.
- ZZZ showed an explicit publisher VM restriction. No bypass was attempted.
  HoYoPlay and NTE are not certified as playable. Further work on them stopped
  at the user's request.
- ZIP upload/extraction/checksum validation was tested with isolated fixtures.
  An actual official OpenTTD 15.0 HTTPS ZIP download, publisher checksum check,
  extraction and general-recipe import passed in an isolated library.
  Full production browser upload/download and an actual Codex setup run have
  not been certified. The installed Codex CLI was found and its version checked.

Evidence is under `recovery-evidence/shared-games-*`. Local build output is
deployed to KVM2; KVM2 is used for runtime only.
