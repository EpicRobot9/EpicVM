# EpicVM Agent Access + Ubuntu: Phased Roadmap

**Purpose:** Single source of truth for sequencing. Every phase is pinned to an
entry gate, exit criteria, and a verification command. Work does not start on a phase
whose entry gate is unmet, and a phase is not done until its exit criteria are proven,
not asserted.

**Created:** 2026-09-25
**Companion detail:** `2026-09-25-vm-agent-access-and-ubuntu-profile.md` (architecture,
workstreams WS-1..WS-7, file map, safety properties). This roadmap is the *order and
gates*; that document is the *design*. Where they disagree on order, this document wins.

**Authoritative starting point (verified live 2026-09-25):**

- Tailscale OAuth credential is live and can read/write the ACL and mint guest keys.
  Client `kg8Y7dTUzQ11CNTRL`. The documented `:3389`-only ACL is stale; the live policy is
  a wildcard grant, so port 22 is already open. No ACL edit is required for the access
  work.
- `E:\EpicVM\vms` is empty. 75 provisioning jobs exist and **all** are in terminal
  failure. Zero `ready`. 2 Hyper-V VMs, both `Off`, both template builders.
- Therefore the access feature is blocked behind provisioning repair, which is Phase A.

---

## Phase map (RE-SEQUENCED 2026-09-25 - Linux first)

> Superseded order: A (Windows repair) ran first and produced a fully diagnosed but
> unfixed defect. Epic elected to hold Windows and make the first agent pass Linux.
> Rationale and evidence below.

| Phase | Goal | Blocked by |
| --- | --- | --- |
| **U0** | Ubuntu clean source + immutable template | - |
| **U1** | Ubuntu profile in the provisioning pipeline -> first `ready` | U0 |
| **2** | Per-profile capability flags (WS-1) | U1 |
| **3** | Shared exec core + agent routes (WS-2, WS-3) | 2 |
| **4** | Linux `access/enable` + SSH access surface (WS-4) | 3 |
| **5** | Dashboard / CLI / UI for access (WS-6) | 3 |
| **6** | PC-side agent wrapper (WS-7) | 3 |
| **7** | Windows SSH retrofit (WS-4 windows half) | 3 |
| **A2** | Windows template repair (Option A runbook, held) | 7 |
| **B** | Sweep stale tailnet device records | U1 |
| **8** | Ubuntu pilot hardening, then enable | U1, 5 |

### Why Linux goes first

1. **The Windows root cause is a structural coupling, not a bug.** The host stores one
   secret (`bootstrap.dpapi`) that must match a secret baked into an image. That will
   re-break on every rebuild, rotation, restore, or second host. It is managed, not
   fixed. It is also fully diagnosed and written down, so deferring costs little.
2. **The credential-drift class largely does not exist for SSH.** The plan already
   generates a per-VM ed25519 keypair sealed with DPAPI, so there is no shared host-side
   password to drift out of sync with an image.
3. **cloud-init NoCloud avoids every surface that broke.** No OOBE, no unattend passes,
   no sysprep, no "Install Windows" abort dialog. The mechanism already exists in the
   codebase: `New-EpicVMOmarchySeedDisk` (`OmarchyProvider.ps1:447`) builds a `cidata`
   VHDX for headless first boot.
4. **A headless Ubuntu profile skips stages 5-7 entirely.** No GPU-P, no Sunshine, no
   RDP probe. Stages 1-4 are the only thing that must work to reach a first `ready`.

### Honest cost of going Linux-first

- Linux needs more NEW code (provider, builder, SSH readiness, guest config, SSH
  `VerifyGuest`) where Windows needs DEBUGGING. Writing is more predictable, not free.
- The Omarchy SSH transport has Pester tests but was **never enabled on this host**
  (no manifest, gates unset). Treat it as tested, not proven. U1 is its first real proof.
- Windows is the gaming platform at core and will eventually need A2. Deferring is
  cheap only because the diagnosis is captured in
  `recovery-evidence/phase-a-preflight-20260925/`.

### What carries over unchanged

- The **observability fix** (classified bootstrap failures) is already applied and
  parse-verified. It stays valuable for Windows and is harmless for Linux.
- The **legacy vs new Windows template switch** should still be built, so Windows can
  return without another empty-template gap. It is a single `TemplateManifestPath`
  config key plus a selector.

---
## Phase A - Repair Windows provisioning to one `ready` VM

**Goal:** One minimal `standard`-profile Windows VM provisions end to end and lands in
`state=ready`, with evidence. This unblocks the entire roadmap.

### Why this is first

Every later phase needs a live guest to verify against. Section 6 of the companion
document demands a live guest for every access gate, and Ubuntu needs a proven Windows
pipeline first. Today the host cannot deliver a working VM at all, so this is both the
blocker and the single highest-value fix available.

### Entry gate (MET 2026-09-25, verified - see `recovery-evidence/phase-a-preflight-20260925/preflight.txt`)

- [x] Live credential confirmed. Agent service `EpicVMRemoteAgent` `Running`/`Automatic`.
- [x] Template manifest present at `E:\EpicVM\templates\win11-25h2\manifest.json`,
      **sha256 verified to match the VHDX byte-for-byte**
      (`e1d11c8a...c4670cc`, 17.47 GB). `fullCopy=true`, `immutable=true`,
      `network=private-switch`, Sunshine `2026.516.143833`.
- [x] Hyper-V functional. A throwaway Gen2 VM was created, started, reported
      `Operating normally`, and had `Heartbeat: enabled=True`. The probe VM, its VHD,
      and its directory were fully removed afterwards.
- [x] `E:` has ample free space (2465.8 GB free).
- [x] `EnableOmarchyProvisioning` and `EnableUbuntuProvisioning` are both unset, as
      required. `bootstrap.dpapi` is present.
- [x] Management transport required, port 5985, no SSL.

**Preflight finding 1 - manifest version drift (documentation, not a fault).**
The deployed manifest is `templateVersion 1.2.0` (`win11-25h2-20260826`), while
`remote_agent/windows/TemplateBuilder.ps1:414` in the repo emits `1.4.0`. The image hash
matches its own manifest, so the *deployed* artifact is self-consistent. This is source
drift between the builder and what was actually published, and it should be reconciled
before any template rebuild in Phase 6. It does **not** block Phase A.

**Preflight finding 2 - RESOLVED 2026-09-25: guest egress works. Do not touch the NAT.**
This finding was originally recorded as the prime suspect. It is wrong. See
`recovery-evidence/phase-a-preflight-20260925/egress-verdict.txt`. The evidence is
decisive and comes from the job history itself:

- 22 of 75 jobs recorded a `tailnetIp` - the guest reached the internet and enrolled.
- 21 recorded a `tailnetDeviceId` - enrollment minted a real device.
- **15 recorded `completedStages` containing the final stage `stream_validation` with
  `streamValidationVerified = true`.**
- 20 recorded `managementTransport = 'tailscale_winrm'` - the WinRM handoff over
  Tailscale worked end to end.

`Get-NetNat` reporting an empty `ExternalIPInterfaceAddressPrefix` is cosmetic; it still
forwards on the internal vNIC. The earlier probe was insufficient evidence, and acting on
it would have meant an unnecessary network change on a live host.

**Preflight finding 3 - the real fault is a post-provisioning demotion, not a build
failure.** None of the 15 completed jobs failed at `claim`, `guest_setup`, or
`network_setup`. All 15 were demoted from a working state *after* the pipeline finished:

| Outcome | Count |
| --- | --- |
| `setup_failed:agent_restart` / `reverification_failed` | 11 |
| `setup_failed:legacy_state_uncertain` / `legacy_state_uncertain` | 3 |
| `setup_failed:streaming` / `management_transport_failed` | 1 |

The VMs were built correctly and then lost. This lines up exactly with the code read in
the Diagnosis section: `Provisioning.ps1:789-795` and `:818-835` demote an **already-ready**
job to `setup_failed:agent_restart` when the post-restart readiness checkpoint fails, and
the checkpoint at `:770-786` demands all of `claimConsumed && claimUsed`, the six
completed stages, `streamValidationVerified == true`, the per-profile capture flag, and
`Test-EpicVMProvisioningReadyIdentity`, plus a VM that is currently `Running` and
`managed`.

**ROOT CAUSE FOUND 2026-09-25 - see `recovery-evidence/phase-a-preflight-20260925/root-cause.txt`.**

The reproduction did **not** fail as predicted. Job `bd21164e3c454731899d4f2af73722a6`
(`phasea-std-01`, standard) ran `queued -> cloning -> booting -> setup_failed:preclaim`
and stopped in ~12 minutes with `errorCode=guest_bootstrap_not_ready`,
`completedStages=[]`, `claimConsumed=false`. It never reached `network_setup`.

**The stored bootstrap credential does not match the template.** Raw PowerShell Direct
against a VM rebuilt from the preserved failed clone disk, and separately against the
pristine `win11-25h2` template itself, both return:

```
PSSessionOpenFailed | "The credential is invalid."
```

while the guest `Heartbeat` integration service reports `OK`. A deliberately wrong
credential returns the identical message, which proves the guest is reachable and
PowerShell Direct works - only the credential is rejected.

`Test-EpicVMGuestBootstrapReady` (`GuestProvider.ps1:801-818`) is the gate. It runs
PowerShell Direct with the credential from `bootstrap.dpapi` and does
`catch { return $false }`, discarding the reason. That is why this presented as an
opaque "did not become ready" rather than a password mismatch.

Timeline confirms drift: the template was published 2026-08-26 19:41, and
`bootstrap.dpapi` was rewritten 2026-08-27 07:22, about 12 hours later, during a
`clean-source.vhdx` rebuild. A stray `.bootstrap-fe7c825e...tmp` from 08-10 also
matches the legacy-blob migration path at `TemplateBuilder.ps1:104-108`. Every clone
inherits the mismatch, so this one fault explains the whole `guest_bootstrap_not_ready`
family in the job history.

Ruled out with evidence: guest egress (15 prior jobs completed the full pipeline),
Hyper-V and template integrity (hash matches, boots clean), Tailscale enrollment (never
reached), and the NAT prefix (cosmetic).

**Decision required from Epic before any fix is applied** - both options are
template-affecting and neither should be chosen automatically:

- **A. Rebuild the template** with the current `bootstrap.dpapi`, so the baked account
  matches the stored credential. Also the moment to reconcile manifest `1.2.0` against
  the builder's `1.4.0`. Costs a full build in a maintenance window.
- **B. Reset the `EpicVMBootstrap` password inside the existing template** to match
  `bootstrap.dpapi`, then re-stamp the manifest hash. Cheaper, and the image is
  otherwise healthy, but it mutates a published immutable image, so the `sha256` in
  `manifest.json` must be recomputed or every future clone fails the hash gate.

**Recommendation: B**, run offline in the builder VM with the manifest re-stamped
afterwards, because the image boots clean and this avoids a full rebuild. Either way,
`Test-EpicVMGuestBootstrapReady` should stop discarding the failure reason so the next
occurrence is diagnosable from the API alone. That observability fix is independent of
A or B and should land regardless.

The original three suspects, kept for the record - the reproduction instead found a
fourth, earlier failure:

1. **RDP reachability is the fragile check.** `VerifyGuest` for a Windows guest is
   `Test-EpicVMGuestRdpReachability` (`GuestProvider.ps1:2034-2044`), a 3-second TCP
   connect to `100.x:3389`. If the guest firewall or NLA is not yet accepting 3389 at
   re-verification time, the job is demoted even though the VM is fine.
2. **The VM was not `Running`/`managed` at re-verification time.** `readyVmRunning`
   false makes `retainedReadyRecovery` false and forces the demotion.
3. **A persisted field is missing.** If `claimConsumed`, `claimUsed`, or a
   `completedStages` entry is absent from the re-read record, the checkpoint can never
   hold, and the job is demoted on every restart regardless of VM health.

### Diagnosis - read this before changing anything

The 75 failed jobs are a *history*, not a single bug. Do not replay them. Reproduce one
job and read where it actually breaks. The code paths that decide readiness are:

- `remote_agent/windows/Provisioning.ps1:748-845` - agent-restart recovery. A job whose
  VM is already `ready` gets flipped to `setup_failed:agent_restart` +
  `reverification_failed` unless the re-verification checkpoint holds.
- `remote_agent/windows/providers/HyperVProvider.ps1:1229` - `VerifyGuest`. For a Windows
  guest it calls `Test-EpicVMGuestRdpReachability`, i.e. a TCP connect to
  `100.x:3389` with a 3 s budget (`GuestProvider.ps1:2034-2044`). RDP closed, or a
  firewall rule not yet applied, fails readiness even when the guest is otherwise fine.
- `remote_agent/windows/Provisioning.ps1:1098` - `guest_bootstrap_not_ready` when the
  cloned guest is not ready for secure setup. Tied to the Hyper-V **Heartbeat**
  integration service (`GuestProvider.ps1:1654-1659`, `guest_heartbeat_unhealthy`).

So the two dominant observed codes map cleanly to two checks: **post-restart
re-verification via RDP reachability** (the `agent_restart` / `reverification_failed`
family, 17 jobs) and **guest bootstrap/heartbeat readiness** (the
`guest_bootstrap_not_ready` family). Start by proving which one a fresh job hits.

### Steps

1. **Preflight, read-only. DONE 2026-09-25** - see the three findings above and
   `recovery-evidence/phase-a-preflight-20260925/` (`preflight.txt`,
   `egress-verdict.txt`). Egress is proven good; the NAT is not to be modified. Nothing
   else is required before a run.
2. **Reproduce one job.** Create a single `standard` VM via the agent's own provisioning
   route (`POST /v1/provisioning-jobs`) so the same code path, stage gates, and
   persistence are exercised. Use a fresh, clearly-named test VM. Do not reuse any of the
   75 stale names.
3. **Observe, do not guess.** Follow the job through `claim -> guest_setup ->
   network_setup -> management_handoff -> streaming_setup -> stream_validation`. Record
   the exact stage, `errorCode`, and `failureStage` where it stops.

   **Expectation going in:** based on the 15 completed jobs, the VM will very likely
   build successfully and then be **demoted from `ready` on a later agent pass**. So the
   instrumentation that matters is around the demotion, not the build:

   - Does the job first reach `state=ready`, and only later flip to
     `setup_failed:agent_restart`? Record the exact transition.
   - At that moment, is `Test-EpicVMGuestRdpReachability` returning true for the guest's
     `100.x:3389`? Test it directly and in parallel.
   - Is the VM `Running` and `managed` at that moment?
   - Does the persisted record still carry `claimConsumed`, `claimUsed`, and all six
     `completedStages`? Dump the record at the moment of demotion.

   That set separates suspect 1 (RDP), suspect 2 (VM not running), and suspect 3
   (missing persisted field) in one pass.
4. **Fix forward from evidence.** Address the single reproduced failure. If it is RDP
   reachability, verify the guest firewall/NLA actually permits 3389 on the Tailscale
   interface before changing the readiness logic - do not weaken the gate. If it is
   heartbeat or bootstrap, inspect the guest integration-service state. Change the
   smallest thing that addresses the observed cause.
5. **Re-run to `ready`.** One VM, one pass, reaching `state=ready` with
   `streamValidationVerified=true`.
6. **Prove durability.** Reboot the host's agent service (not the VM) and confirm the job
   stays `ready` and survives re-verification. Then restart the *VM* and confirm it
   returns to a usable running state. This directly targets the `agent_restart` family.

### Exit criteria (all required, evidence-backed)

- [x] Guest internet egress proven good - 15 prior jobs completed the full pipeline.
- [ ] One `standard` VM is in `state=ready` in `E:\EpicVM\provisioning-jobs.json`.
- [ ] That VM is `Running`, `managed=true`, in Hyper-V.
- [ ] A matching Tailscale device exists online in `GET /tailnet/-/devices`.
- [ ] `VerifyGuest` (`RDP reachability`) returns true for it.
- [ ] The job survives an **agent service restart** and stays `ready`.
- [ ] The job survives a **VM restart** and returns to a usable running state.
- [ ] The root cause of the reproduced failure is written down, with the fix and the
      evidence that justified it.
- [ ] Focused tests pass: `scripts/Run-EpicVMFocusedPester.ps1` over `Provisioning`,
      `GuestProvider`, `HyperVProvider`, and all touched `.ps1` files parse clean.

### Explicitly not Phase A

- Do not touch the 75 historical job records except to add the new job. They are
  evidence; leave them.
- Do not weaken any readiness gate to force a pass. A `ready` that came from a weakened
  gate is not a pass.
- Do not enable `EnableOmarchyProvisioning` or `EnableUbuntuProvisioning`. Both stay
  off.
- Do not run the 36-record tailnet sweep here. That is Phase B.

### Evidence to attach when Phase A is claimed done

- The new job's final JSON record (state, errorCode, completedStages, timestamps).
- The reproduced failure's stage and errorCode, plus the fix diff or config change.
- Hyper-V `Get-VM` output for the new VM.
- The two restart-survival results (agent restart, VM restart).
- Focused test output.

---
## Phase B - Sweep stale tailnet device records

**Goal:** Remove dead Tailscale device records so the tailnet reflects reality and
device-IP reuse cannot collide with a dead guest.

**Entry gate:** Phase A complete (one live guest exists, so we can tell live from dead).

**Context:** `GET /tailnet/-/devices` returns 36 records. Roughly 20 are dead EpicVM
guests last seen in August, including **eight** separate records for the single failed
VM `prod-gaming-verify-1`, which is direct evidence the revoked-device sweep did not
finish. Some unrelated Linux nodes (`openclaw-desktop-vg5e7uc`, `srv955268`) are also
stale; those are not EpicVM's to delete without Epic's explicit call.

**Steps**

1. Snapshot `GET /tailnet/-/devices` to a dated evidence file. This is the rollback
   reference.
2. Classify each record: live EpicVM guest, dead EpicVM guest, unrelated, already
   expired. Do not guess from names; use last-seen, expiry, and the Phase A guest's
   known device id.
3. Confirm the existing `ClearTailscaleStaleDevices` / `RevokeTailscale` provider helpers
   (`TailscaleProvider.ps1`) behave correctly, since the eight-record duplicate shows
   they did not. Fix the sweep if it is the cause.
4. Revoke only the records Epic confirms dead. Leave unrelated nodes alone.
5. Re-read devices and confirm the count dropped to the expected live set.

**Exit criteria**

- [ ] A dated device snapshot exists as evidence.
- [ ] Every dead EpicVM guest record is either revoked or explicitly listed as retained.
- [ ] No unrelated node was deleted.
- [ ] The Phase A guest's device is still present and online after the sweep.

---

## Phase 1 - Per-profile capability flags (WS-1)

**Goal:** Replace the hardcoded profile-name comparisons with declarative flags so a
headless profile can exist.

**Entry gate:** Phase A complete. Reason: this changes the ready-gate logic, so it must be
validated against a working baseline first, or a regression is indistinguishable from
the pre-existing breakage.

**Steps**

1. Add to each profile case in `Get-EpicVMProvisioningProfile`
   (`Provisioning.ps1:262-301`): `requiresGpuValidation`, `requiresStreaming`,
   `requiresOmarchyGpuValidation`, `managementTransport`, `consoleBackend`.
2. Replace the `profile -ne 'gaming'` / `profile -ne 'omarchy'` checks at
   `Provisioning.ps1:170-171` and `:754-755` with reads of those flags.
3. Extend the redacted-job allowlist (`Provisioning.ps1:360-380`) with the new
   non-secret fields so the dashboard can see them.
4. Do **not** add a `ubuntu` case yet. That is Phase 6. This phase is only the
   mechanism.

**Exit criteria**

- [ ] No ready-gate or stage-restart decision depends on a hardcoded profile name.
- [ ] The Phase A `standard` VM still reaches `ready` after the refactor.
- [ ] `gaming` and `omarchy` profile decisions are byte-for-byte equivalent to before.
- [ ] `Provisioning.Tests.ps1` passes, plus a new case proving a hypothetical
      no-GPU/no-streaming profile resolves to ready without GPU or streaming stages.

---

## Phase 2 - Shared exec core + agent routes (WS-2, WS-3)

**Goal:** An agent can run commands in a guest through the agent, with elevation, and
get back exit code, stdout, and stderr.

**Entry gate:** Phase 1 complete.

**Steps**

1. Create `remote_agent/windows/providers/GuestExecProvider.ps1`, generalizing the
   proven `Invoke-EpicVMOmarchySsh` (`OmarchyProvider.ps1:530-570`) into
   `Invoke-EpicVMLinuxSshExec`, plus a `Invoke-EpicVMWindowsWinRmExec` wrapper and a
   generalized `New-EpicVMGuestSshKeyPair`. Keep the Omarchy names working.
2. Add the routes to `EpicVM.Agent.ps1`: `GET /v1/vms/{name}/access`,
   `POST /v1/vms/{name}/exec`, `GET /v1/vms/{name}/exec/{jobId}`.
3. Add the mutating routes to `Test-EpicVMMutationRequest` (`:825-828`).
4. Enforce the listener's constraints: 1 MiB stdout / 256 KiB stderr with a `truncated`
   flag; 60 s default and 300 s hard sync timeout; `async: true` for longer work so the
   **single-threaded** listener (`AgentTransport.ps1:57-120`) is never blocked.
5. Add new failure codes to `Get-EpicVMGuestProviderFailure` (`:726+`) so raw exception
   text never crosses the boundary.

**Exit criteria**

- [ ] `exec` on the Phase A Windows guest returns correct exit code and stdout.
- [ ] A `sudo -n`-style elevated action works on a Linux guest (use the Omarchy-style
      SSH path with a throwaway Linux guest, or defer to Phase 6 for Ubuntu).
- [ ] A long `async` job does **not** stall `GET /v1/health`.
- [ ] Requesting over the sync timeout returns a bounded error, not a hang.
- [ ] Nothing sensitive appears in agent logs.
- [ ] Focused Pester over `GuestExecProvider`, `Agent`, `AgentTransport` passes.

---

## Phase 3 - Windows SSH retrofit / `access/enable` (WS-4)

**Goal:** Real OpenSSH access on an existing Windows guest, installed on demand, and a
real `ssh` round trip that proves it.

**Entry gate:** Phase 2 complete **and** the Phase A guest is live.

**Steps**

1. Implement `POST /v1/vms/{name}/access/enable` to run the Windows bootstrap over the
   existing WinRM transport: install `OpenSSH.Server`, write `sshd_config.d/epicvm.conf`
   with `PasswordAuthentication no`, place the management public key in
   `administrators_authorized_keys` **ACL-locked to SYSTEM + Administrators**, start
   `sshd`, and open TCP 22 firewalled to `100.64.0.0/10` with `EdgeTraversalPolicy Block`.
2. Make it idempotent.
3. Verify with a genuine `ssh` round trip from the host, not merely "sshd is running".

**Exit criteria**

- [ ] `access/enable` is idempotent (a second call is a no-op success).
- [ ] A real `ssh` round trip to the guest succeeds as the management user.
- [ ] An admin action over that SSH session succeeds.
- [ ] The Sunshine/streaming path on that guest still works after the retrofit.
- [ ] A reboot does not lose SSH access.

---

## Phase 4 - Dashboard / CLI / UI for access (WS-6)

**Goal:** An agent or user can discover and use access through the dashboard, CLI, and UI
without hand-assembling HTTP calls, and without the browser ever holding a credential.

**Entry gate:** Phase 2 complete.

**Steps**

1. Add the access/exec/enable proxy routes in `dashboard/app.py` behind the existing
   auth + CSRF + `_enforce_vm_user_access` path (`app.py:3557`).
2. Extend `server/epicvm-remote-host` with `access`, `exec`, `access-enable`.
3. UI: treat `ubuntu` as non-GPU in `provisioningUi.js:29-38`, add a `streamingRequired`
   awareness, and surface `accessTransport` per VM in `AccountWorkspace.jsx`.
4. Write `docs/GUEST-ACCESS.md`, and correct the stale ACL in
   `remote_agent/windows/README.md` and `docs/REMOTE_HOSTS.md`.

**Exit criteria**

- [ ] Dashboard, CLI, and UI all reach the same exec behavior.
- [ ] No agent token or guest credential is ever returned to the browser.
- [ ] `tests/test_guest_access_api.py`, `tests/test_provisioning_api.py`, and the
      `dashboard_v2` tests pass; both frontend builds pass.

---

## Phase 5 - PC-side agent wrapper (WS-7)

**Goal:** A Codex session on this PC reaches guests in one command.

**Entry gate:** Phase 2 complete. This PC is already on the tailnet at `100.72.220.117`,
so the tunnel surface is available here.

**Steps**

1. Write `scripts/epicvm-guest.ps1` with `-Access`, `-Exec`, `-Upload`, `-Download`,
   reading dashboard URL and agent token from a local protected file, never printing the
   token, supporting `-Json`.
2. File transfer: bounded base64 over exec for small files, tunnel + `scp` above a
   documented threshold.

**Exit criteria**

- [ ] `-Access` returns correct transport/endpoint/user.
- [ ] `-Exec` runs a command and returns exit code and output.
- [ ] `-Upload`/`-Download` round-trip a file and checksum-match it.
- [ ] The wrapper never prints the agent token.

---

## Phase 6 - Ubuntu profile + template + manifest (WS-5)

**Goal:** Ubuntu Server 24.04 LTS as a headless, SSH-first profile for agent work.

**Entry gate:** Phase 1 complete (capability flags exist), Phase 4 complete (UI can
render the profile), and a live guest from Phase A to validate the Windows pipeline that
the Ubuntu build mirrors.

**Steps**

1. Add the `ubuntu` profile case using the capability flags from Phase 1: 4 vCPU, 8 GiB,
   96 GiB, `gpu = $false`, `managementTransport = 'tailscale_ssh'`,
   `consoleBackend = 'none'`, `experimental = $true` until pilot passes.
2. Write `scripts/Build-EpicVMUbuntuTemplate.ps1`, mirroring the Omarchy builder: plan-only
   unless `-Execute`, Gen2 UEFI, Secure Boot **on**, vTPM off, pinned ISO sha256,
   `fullCopy`, `immutable`, `noGuestSecrets`.
3. Write `Test-EpicVMUbuntuTemplateManifest` modeled on the Omarchy manifest gate
   (`OmarchyProvider.ps1:139-170`), including the image-path-inside-manifest check.
4. Add `UbuntuTemplateManifestPath`, `UbuntuIsoSha256`, `UbuntuPilotValidated`,
   `EnableUbuntuProvisioning` config keys, defaulting to **off**.
5. Surface `ubuntu_provisioning` in `/v1/capabilities`.
6. Cloud-init seed: `epicvm` user, key-only, `NOPASSWD` sudo, `openssh-server` on at
   build time, Tailscale enrolled to the guest tag, pinned base packages, no Docker in
   v1, seed burned after consumption.

**Exit criteria**

- [ ] `ubuntu` appears in the profile list gated on `ubuntu_provisioning`.
- [ ] The template builds and `Verify-EpicVMTemplatePublication.ps1` passes.
- [ ] A real `ubuntu` VM provisions to `ready` with **no** `gaming_gpu`,
      `omarchy_gpu`, `streaming_setup`, or `stream_validation` stage.
- [ ] `GET /v1/vms/{name}/access` returns `tailscale_ssh`, ready.
- [ ] `exec` proves a read, a `sudo -n` elevation, and a write.
- [ ] Access survives a reboot.

---

## Phase 7 - Ubuntu pilot hardening, then enable

**Goal:** Flip `EnableUbuntuProvisioning` on only after the pilot proves the whole
path repeatedly, and only after the ACL is tightened.

**Entry gate:** Phase 6 complete.

**Steps**

1. Run at least three full Ubuntu provision/access/teardown cycles and record outcomes.
2. Resolve the separate tailnet ACL question (open question 6 in the companion document):
   the live policy is a wildcard `* -> *` grant plus Tailscale SSH as root on self,
   which is wider than the documented intent. Tighten with a rollback-ready copy first.
3. Decide on a separate `tag:epicvm-linux`. Note `TailscaleProvider.ps1:79` currently
   hard-refuses any tag other than `tag:epicvm-guest`, so this is a code change as well
   as an ACL change.
4. Only then set `EnableUbuntuProvisioning` and `UbuntuPilotValidated`.

**Exit criteria**

- [ ] Three consecutive clean provision/access/teardown cycles.
- [ ] Tailnet policy tightened to a documented, non-wildcard form.
- [ ] README/REMOTE_HOSTS docs match the deployed policy.
- [ ] `EnableUbuntuProvisioning` flipped, with Epic's explicit approval recorded.

---

## Cross-phase rules

1. **No phase starts before its entry gate is met.** A blocked phase waits; it does not
   get partially started.
2. **Exit criteria are proven, not asserted.** A written claim without the attached
   evidence does not close a phase. This is the standing EpicVM rule.
3. **No weakening readiness gates to force a pass.** If a gate is wrong, fix the cause
   and say so, not the gate.
4. **Preserve dirty state.** The repo has extensive uncommitted work. Every phase uses
   scoped edits only, and never reverts or reformats unrelated files.
5. **Build on the PC, deploy/runtime-check on kvm2.** Source edits stay on this PC;
   deployment and live verification run through kvm2. Use
   `scripts/Install-EpicVMAgentSourcesSafe.ps1 -ReportPath <path>` and compare hashes.
6. **Standing boundaries.** The 75 historical job records and the manual-input /
   automated-readiness separation stay intact. Automated readiness never substitutes for
   a human keyboard/mouse/audio attestation when claiming gaming acceptance.

## Document map

- This roadmap: `docs/plans/2026-09-25-epicvm-phased-roadmap.md` (order and gates).
- Companion design: `docs/plans/2026-09-25-vm-agent-access-and-ubuntu-profile.md`
  (architecture, WS-1..WS-7 detail, file map, safety properties, live-state section 0).