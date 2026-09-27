# EpicVM MultiSeat handoff, September 22, 2026

EpicVM now runs native Windows game seats through MultiSeat while preserving its Hyper-V and GPU-P gaming VM path. The portal offers game launch and session resume/end controls. Admin management owns host game registration, grants, seat status, recovery, and catalog removal. Normal users do not need to operate MultiSeat. Host sessions use separate generated Windows accounts and do not receive the operator's launcher credentials.

## Live outcome

- MultiSeat v0.6.7 and EpicVMRemoteAgent are running. MultiSeat's authenticated service is loopback-only on port 9550. Its prerequisites include HidHide, ApolloVibe, RDP Wrapper, and SudoVDA. The agent reports `apiVersion=2`, `installed=true`, `ready=true`, and `service=Running` after the latest source deployment.
- The safe agent installer report at `C:\ProgramData\EpicVM\agent\multiseat-update-report-final.json` reports `ok=true`, `healthVerified=true`, and `hashesMatch=true`. The agent's authenticated `/v1/health` and `/v1/host-gaming` requests succeeded on its Tailscale address.
- A harmless 7-Zip launch through EpicVM previously created a second isolated native seat while the physical console remained in session 1. MultiSeat returned a ready seat on port 48130. EpicVM staged and paired its per-owner Moonlight Web route at `/vm/seat-1d7c55b56d26edc513486721/`. KVM2 reached the seat stream ports and authenticated host API. The public route denied anonymous access with HTTP 403. Stopping through EpicVM removed the owner route.
- The agent's version 2 catalog removal route removed the temporary `sevenzip-smoke` entry. A fresh agent query returned zero catalog games and zero seats. The source dashboard management route derives `supportsRecovery=true` from `apiVersion=2`; an authenticated browser read of that management page was unavailable in this session.
- FNF Dustin remains in the shared-game library and assigned to the running `astra-testmann` VM. Its existing Moonlight console passed the earlier `verify_staged` check. The VM is still running after this work.
- Focused checks before this continuation passed 36 Python tests, 5 Pester tests, and the EpicVM web production build. This continuation reran the host gaming and shared-game Python tests (5 passed) and HostGaming Pester tests (5 passed).

## Duo retirement

- Duo's service and uninstall entry are gone. The deployed agent retired `Duo.ps1`, `DuoWorker.ps1`, and `DuoSessions.cs`. No Duo references remain in operational source under the dashboard, agent, web source, Docker, scripts, server, or tests. Historical documentation and an ignore pattern still mention the former backend.
- `BluetoothUserService\Parameters\ServiceDll` now points to `%SystemRoot%\System32\Microsoft.Bluetooth.UserService.dll`. The Bluetooth user service was restarted after the registry repair. Its new process loads the Microsoft DLL and no Duo DLL.
- Two unused files still exist at `C:\Program Files\Duo\DuoBluetooth.dll` and `C:\Program Files\Duo\vcruntime140.dll`. Automatic command policy rejected deletion even after the DLL was unloaded. The one-time `EpicVM-RestoreNativeBluetoothUserService` task was removed. Its script at `C:\ProgramData\EpicVM\host-gaming\restore-native-bluetooth.ps1` remains because automatic command policy rejected that file deletion. The script is no longer scheduled or needed for service operation.

## Acceptance limit

Moonlight pairing, authenticated HTTP, route ownership, stream ports, and teardown were verified. Decoded browser video, keyboard, mouse, and audio have **not** been verified. The computer-use browser reports `Codex auth token is unavailable`, including after this continuation. Do not describe the stream as fully accepted until a browser with working authentication exercises those controls. No ZZZ, NTE, HoYo, anti-cheat workaround, VM hiding, or remote-session spoofing was used.

The workspace is substantially dirty with unrelated changes. Keep further edits scoped. The project path at `C:\Users\Epic\Documents\Blobe-Vm-Manager` points to this `E:\Projects\Documents\Blobe-Vm-Manager` workspace.

## September 23 extension

- EpicVM now offers three user labels: **Play a game!** for a host game in a native seat, **Gaming VM** for the virtual computer, and **Your Personal Desktop** for a reusable native Windows desktop. A trusted user's desktop is assigned separately by an admin and opens the seat without launching an app. Closing the browser leaves a seat available to resume; End session closes the seat and preserves the account and profile.
- The admin management screen assigns/revokes personal desktops and reveals an individual seat password on demand. A reveal is audited without the password, and the response is marked no-store. MultiSeat v0.6.7's source extension and deployment notes live in `integrations/multiseat/`. Revoking desktop access ends that user's seat and stream.
- The MultiSeat service DLL and EpicVM Windows agent were updated with backups and health checks. The agent reports `apiVersion=3` and `ready=true`. The dashboard backend and built web assets were deployed to KVM2; the container and current web asset answer successfully. No active seat was present during service replacement.
- A live desktop-only request reused the dashboard admin's existing seat account, created one ready seat on port 48100, and did not invoke a game launch. The authenticated reveal returned a nonempty credential with a no-store header without printing it. EpicVM stop removed the seat and retained its reusable account. MultiSeat's 565 tests passed, with 17 skipped; focused EpicVM Python tests passed 5/5, HostGaming Pester tests passed 7/7, and the web build passed.
- Decoded browser video, keyboard, mouse, and audio still need app-based verification. The browser control service previously returned `Codex auth token is unavailable`. Keep that acceptance distinction when presenting the feature.
