# EpicVM stabilization handoff

This checkout is being left ready for later work after an interrupted Duo
experiment. The production branch was already dirty with earlier EpicVM,
shared-game, account, Moonlight, and experimental Omarchy changes. Cleanup was
scoped: no reset, broad revert, deployment, VM action, game launch, GPU-P
operation, or Omarchy test was performed.

## Archived repository debris

The old live-validation commit had also checked in probe reports, temporary
shell/Python scripts, pytest scratch data, a dashboard backup, a Pester XML
report, pilot-only scripts, and historical screenshot evidence. Those files
were unreferenced by the maintained source and are archived outside the
checkout at:

`C:\Users\Epic\AppData\Local\Temp\EpicVM-cleanup-20260920-c4f78935afae45c3ba04a85f62e94def\legacy-tracked-artifacts`

They were removed from the working tree without touching the active EpicVM,
shared-game, Duo, or Omarchy source. The matching output patterns are ignored
so future local probes and test reports do not become repository files.

## Duo status

Duo is paused. The source-only adapter is preserved in:

- `remote_agent/windows/Duo.ps1`
- `remote_agent/windows/DuoWorker.ps1`
- `remote_agent/windows/DuoSessions.cs`
- `scripts/Initialize-EpicVMDuo.ps1`

The adapter is loaded only when the agent source is present and is reached
through the authenticated `/v1/duo` endpoints. The existing VM and shared-game
routes do not depend on it. It must not be treated as a working streaming
backend yet. The interrupted session reported a Duo display-driver
initialization failure before Sunshine streaming; that live result was not
re-run during this cleanup. The one-shot native probe and its raw report were
removed from the checkout.

A read-only host check still finds the prior machine-side `DuoService` running,
the temporary `evduo_probe` account enabled, and Duo-related processes present.
Those are outside this repository cleanup and were intentionally not stopped,
deleted, or otherwise mutated. Treat that host state as leftover probe state;
do not infer from it that Duo streaming works.

The setup script now stores its optional local report under
`C:\ProgramData\EpicVM\duo\initialize.json` rather than writing generated
evidence into the repository. No process patching, sandbox mode, or anti-cheat
workaround is part of the preserved design.

## Existing paths

The Hyper-V/RemoteVM and shared-game source remains the active path. The
shared-game implementation and its focused tests are kept; the one-off live
inspection, launch, repair, and probe scripts from the interrupted work are
not part of the maintained interface.

Omarchy remains an explicitly experimental, source-only profile. Its provider,
builder, and focused tests are retained with the existing disabled-by-default
gates. No Omarchy runtime validation was performed here.

## Verification boundary

Only repository-local static checks and focused tests are appropriate for this
handoff. Live VM provisioning, retained-VM lifecycle, GPU-P, game streaming,
and Omarchy validation must be performed separately when explicitly resumed.

The cleanup pass completed these local checks:

- Python focused suite: 148 passed, 1 skipped.
- Dashboard v2 Node suite: 51 passed.
- PowerShell AST parsing and `DuoSessions.cs` compilation passed.
- The Windows agent imported with `-NoStart` without starting infrastructure.

The unscoped Python suite is not a useful cleanup gate on this machine: its
default temp root contains an old ACL-blocked `pytest-of-Epic` directory, and
it also includes five unrelated legacy contract failures. Use a fresh private
`--basetemp` path and the focused suite above when checking this dirty
checkout.
