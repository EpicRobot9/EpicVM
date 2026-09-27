# EpicVM Agent VM Access + Ubuntu Profile Implementation Plan

**Goal:** Let an agent (Codex/Hermes) get elevated, scriptable access into any EpicVM
guest - new or already-created - and add Ubuntu Server as a first-class Linux profile
for headless agent work.

**Status:** Plan only. No production code has been written. Requires Epic's approval
before implementation.

**Sequencing lives in a separate document.** This document is the design. The order,
entry gates, and exit criteria for every phase are pinned in
`2026-09-25-epicvm-phased-roadmap.md` (Phase A through Phase 7). Where the two disagree
on ordering, the roadmap wins. Read that first.

---

## 0. Live state verification (2026-09-25)

The Tailscale credential was refreshed before this section was written. Everything
below is read from the live host and API, not inferred.

### Credential: confirmed working, and it has real scope

- Stored at `C:\ProgramData\EpicVM\agent\tailscale-oauth.dpapi`, DPAPI machine-sealed,
  ACL `SYSTEM:Read` + `Administrators:Read` only.
- `Get-EpicVMTailscaleAccessToken` returns a live token (client id `kg8Y7dTUzQ11CNTRL`).
  This is a Tailscale **OAuth client**, not a legacy `tskey-` API key. It mints guest
  auth keys through the token flow, so a new API key was not required for the plan.
- Live probes against `api/v2`: `GET /tailnet/-/devices` 200, `GET /tailnet/-/acl` 200,
  `GET /tailnet/-/users` 200, `GET /tailnet/-/keys` 200. The credential can read and
  write the ACL. **The original Phase 0 ACL blocker is resolved.**
- The agent service `EpicVMRemoteAgent` is `Running` / `Automatic` on this PC
  (`DESKTOP-VG5E7UC`, `100.72.220.117`).

### Finding 1 - the documented ACL does not describe the deployed ACL

`remote_agent/windows/README.md` documents a narrow policy allowing only
`tag:epicvm-host`/`tag:epicvm-kvm2` -> `tag:epicvm-guest:3389`. The live policy is:

```json
{ "grants": [ { "src": ["*"], "dst": ["*"], "ip": ["*"] } ] }
```

plus a Tailscale SSH rule allowing `autogroup:member` -> `autogroup:self` as
`autogroup:nonroot` and `root`. `tagOwners` maps `tag:epicvm-guest` to the Epic account.

Two consequences:

1. The port 22 blocker described in the original section 5 **does not exist in
   practice**. Every guest port is already reachable, so no ACL edit is required to
   make the SSH workstreams function. The documentation is what is wrong.
2. The live policy is materially wider than the documented intent. Any authenticated
   tailnet member can reach any other tailnet node on any port, and Tailscale SSH
   permits root on self. That is a real exposure that exists today, independent of this
   project.

Recommended, **not yet applied** - it is a production tailnet and a bad edit can lock
devices out: replace the wildcard grant with tag-scoped rules, keep SSH limited to the
EpicVM service identities, and correct the README to match whatever policy is chosen.
Epic's call on the exact rule set; flagged in section 8 as question 6.

### Finding 2 - there are no existing VMs to retrofit. This is the real blocker.

`E:\EpicVM\vms` contains exactly one entry, an empty `quarantine` directory. There are
no VHDX files under it. The only VHDX files on the host belong to templates
(`templates\win11-25h2`), a clean template source, quarantined builds, and the Omarchy
builder work area.

Hyper-V reports 2 VMs, both `Off` and both template builders:

- `EpicVM-CleanTemplateSource` (quarantined, `QuarantineUntil` 2026-08-18)
- `EpicVM-Omarchy-TemplateBuilder`

`E:\EpicVM\provisioning-jobs.json` holds 75 job records. **Every single one is in a
terminal failure state** - `setup_failed:*` or `quarantined`. There is not one `ready`
job. Recurring codes: `agent_restart` / `reverification_failed` (17 jobs),
`guest_bootstrap_not_ready`, `guest_configuration_failed`, `legacy_state_uncertain`,
`deprovisioning_failed`, `tailscale_revoke_failed`, and several `setup_failed:streaming`
with `management_transport_failed` on the gaming GPU-P pilots.

The tailnet corroborates this: 36 device records, of which the Windows guests are almost
all stale `epicvm-pilot-*`, `testprovvm*`, `prod-gaming-verify-1-*` (eight separate
records for one failed VM), and `oobe-smoke-*`, all last seen in August. The three
`openclaw-desktop-vg5e7uc` Linux nodes and `srv955268` are unrelated to EpicVM, and two
of them have already expired.

### What this means for the plan

The original Phase 3, "retrofit SSH onto existing VMs", has no target. There is nothing
running to retrofit. The 36 stale tailnet records are also a live misconfiguration in
their own right, since revoked-device sweeps clearly did not complete.

So the access feature is now sequenced behind repairing Windows provisioning. Building
`/v1/vms/{name}/exec` against a host that cannot successfully provision a single VM
would produce a feature that cannot be verified end to end, which directly violates the
standing rule that an artifact is not an outcome. A new **Phase A** is therefore inserted
ahead of everything, and the retrofit workstream moves to after a successful
provisioning run rather than before it.

---
## 1. Scope

### In scope

1. **Agent access API on the Windows RemoteVM agent** - a brokered, elevated exec surface
   per guest, plus an access-discovery endpoint.
2. **Retrofit path for existing VMs** - turn on real OpenSSH access for guests that were
   provisioned before this feature, without rebuilding their template.
3. **Ubuntu Linux profile** (`profile = 'ubuntu'`) - headless, SSH-first, no GPU, no
   streaming. This is the "agent work" profile.
4. **Dashboard + UI + CLI surface** so an agent can discover and use access in one
   command instead of hand-assembling HTTP calls.
5. **PC-side convenience wrapper** so a Codex session on the PC can reach guests without
   knowing the dashboard internals.

### Out of scope (explicitly)

- Replacing or removing the existing WinRM / PowerShell Direct management transport.
  Those stay as the provisioning and repair transports.
- Replacing the Guacamole browser console (`ConsoleProvider.ps1`).
- Changing the Omarchy profile. It remains the experimental AMD GPU-P Linux desktop
  profile. Ubuntu is additive.
- Interactive TTY sessions as the primary agent path. See section 3.2.
- Rewriting the production tailnet ACL. Flagged in section 0 Finding 1 and section 8
  question 6 as a separate change.

---

## 2. Verified architecture facts

These were read out of the current source, not assumed.

### Agent process and transport

- `remote_agent/windows/AgentTransport.ps1:57-120` - `Invoke-EpicVMAgentListener` is a
  **single-threaded** `HttpListener` loop. One request is serviced at a time. There is
  one existing async escape hatch (`$State.DeferProvisioning` / `$operation`) used for
  provisioning jobs. This is the single most important constraint on the design: a long
  blocking request stalls health checks and every other VM operation.
- `remote_agent/windows/EpicVM.Agent.ps1:858-870` - the listener binds to a specific
  Tailscale `100.64.0.0/10` address or loopback. Wildcard binding is refused.
- `remote_agent/windows/EpicVM.Agent.ps1:825-828` - `Test-EpicVMMutationRequest` is the
  single allowlist of mutating routes. Anything new that mutates must be added here or it
  will be treated as a read and will not get the mutation / idempotency treatment.
- `remote_agent/windows/EpicVM.Agent.ps1:835` - `Read-EpicVMBoundedBody` caps request
  bodies at 1 MiB (`$MaxBytes = 1048576`).
- `remote_agent/windows/EpicVM.Agent.ps1:753` - `GET /v1/vms/{name}/logs` already exists
  as a documented "empty but explicit" stub. That is the established pattern for adding
  routes ahead of full functionality.
- `remote_agent/windows/AgentTransport.ps1:108` - `Idempotency-Key` is honored for
  mutations via a 256-entry completed-operation cache.

### Management transport abstraction (the extension point)

- `remote_agent/windows/providers/GuestProvider.ps1:414-711` -
  `Invoke-EpicVMManagementTransport` / `...Once` is the shared transport. It already
  supports a `Provider.ManagementInvoker` override (lines 428-431), which is how a
  provider substitutes its own wire protocol.
- `remote_agent/windows/providers/GuestProvider.ps1:644-658` -
  `New-EpicVMWinRMLocalCredential` qualifies the username as `.\user` because WinRM to a
  Tailscale IP has no Kerberos context. Elevation on Windows guests is a local-admin WinRM
  token.
- `remote_agent/windows/providers/GuestProvider.ps1:660-676` -
  `Enter-EpicVMManagementClientBoundary` installs a persistent inbound block on
  `5985/5986` so the host cannot be reached as a WinRM client. Any new listener we add on
  the host must follow the same isolation pattern.
- `remote_agent/windows/providers/TailscaleProvider.ps1:290-300` - WinRM is enabled and
  firewalled to `100.64.0.0/10` with `EdgeTraversalPolicy Block`. This is the precedent
  for scoping the new SSH listener.

### SSH already exists for Linux guests (prior art to generalize)

- `remote_agent/windows/providers/OmarchyProvider.ps1:530-570` -
  `Invoke-EpicVMOmarchySsh` runs a script over real `ssh.exe`: `BatchMode=yes`,
  `StrictHostKeyChecking=accept-new`, per-VM `UserKnownHostsFile`, `IdentitiesOnly=yes`,
  `ConnectTimeout=10`, and `sudo -S -p ""` when elevation is requested. The private key
  is written to a temp file from DPAPI and deleted in `finally`.
- `remote_agent/windows/providers/OmarchyProvider.ps1:410-440` -
  `New-EpicVMOmarchySshKeyPair` generates a per-VM ed25519 key with `ssh-keygen` and
  seals the private half with machine-scope DPAPI.
- `remote_agent/windows/providers/OmarchyProvider.ps1:225-231` - Omarchy is gated behind
  `OmarchyPilotValidated` + `EnableOmarchyProvisioning` plus a manifest check. It is
  **disabled by default** and additionally requires an AMD GPU-P partition. On this host
  those config keys are unset and no Omarchy manifest path is configured, confirming
  Omarchy has never been enabled here.

### Provisioning model

- `remote_agent/windows/Provisioning.ps1:262-301` - `Get-EpicVMProvisioningProfile` is a
  `switch` over `standard` / `gaming` / `omarchy`. Adding `ubuntu` is a new case here.
- `remote_agent/windows/Provisioning.ps1:11` - stage order is `claim`, `guest_setup`,
  `network_setup`, `management_handoff`, `gaming_gpu`, `omarchy_gpu`, `streaming_setup`,
  `stream_validation`.
- `remote_agent/windows/Provisioning.ps1:170-171` and `:754-755` - the ready gate and the
  stage-restart gate compare `profile -ne 'gaming'` and `profile -ne 'omarchy'` **by
  hardcoded name**. A headless Ubuntu profile that skips both GPU and streaming stages
  cannot be expressed without refactoring this into per-profile capability flags. This is
  the main structural change in the plan.
- `remote_agent/windows/Provisioning.ps1:360-380` - `ConvertTo-EpicVMRedactedJob` is an
  explicit field allowlist. New non-secret fields (e.g. `accessTransport`) must be added
  there or the dashboard will never see them.

### Templates

- `remote_agent/windows/TemplateBuilder.ps1:414` - the Windows manifest is
  `templateVersion='1.4.0'`, under `E:\EpicVM\templates\win11-25h2\`, immutable, with
  `sha256`, `fullCopy=true`, `network='private-switch'`,
  `sunshineCredentials='request-only'`.
- `remote_agent/windows/providers/OmarchyProvider.ps1:139-170` -
  `Test-EpicVMOmarchyTemplateManifest` is the model for a Linux manifest gate: pinned ISO
  sha256, Gen2 UEFI, secureBoot off, vTPM off, `managementTransport`, `noGuestSecrets`,
  `immutable`, `fullCopy`, and an image path that must resolve inside the manifest
  directory.
- `scripts/Build-EpicVMOmarchyTemplate.ps1` is plan-only unless `-Execute` is passed, and
  the build is gated on an exact `testre` source-name check. A partial Omarchy builder VHDX
  (12.4 GB) sits unreconciled in `E:\EpicVM\template-work\omarchy-...\` with no published
  manifest.

### Server / dashboard

- `dashboard/remote_hosts.py:91-117` - agent bearer tokens are sealed with AES-GCM under a
  key derived from a server secret, stored `0600` in `/opt/blobe-vm/remote-hosts.json`.
  `redact_host_record` guarantees tokens never reach the browser.
- `dashboard/app.py:238` - guest provisioning credentials come from
  `EPICVM_PROVISIONING_CREDENTIALS_FILE`, default
  `/opt/epicvm/secrets/provisioning-defaults.json`, and are never returned to the client.
- The established rule across the codebase: **the browser never holds a host credential
  and the server never holds a Hyper-V credential.** Any access design must preserve that.

### Control plane

- The documented ACL in `remote_agent/windows/README.md` is stale. The live policy is a
  wildcard grant. See section 0 Finding 1. There is no `:22` blocker in practice, and
  therefore also no rule that blocks the existing Omarchy pilot.
- The Tailscale OAuth client can already mint guest auth keys with
  `tags=[tag:epicvm-guest]`, `preauthorized=true`, `ephemeral=false`
  (`TailscaleProvider.ps1:78-95`), and `TailscaleProvider.ps1:79` hard-refuses any tag
  other than `tag:epicvm-guest`. A separate Linux tag therefore requires a code change to
  that guard, not just an ACL edit.

---
## 3. Target design

### 3.1 Access surfaces (three, in preference order for an agent)

**A. Brokered exec - the primary agent interface.**

New agent routes:

| Route | Purpose |
| --- | --- |
| `GET /v1/vms/{name}/access` | Access discovery. Returns transport, endpoint, guest user, elevation flag, readiness, and the exact recommended invocation. Read-only, cheap, safe to call first. |
| `POST /v1/vms/{name}/exec` | Run a command or script in the guest. Body: `{ command, stdin?, cwd?, elevate?, timeoutSeconds?, async? }`. Returns `{ exitCode, stdout, stderr, truncated, durationMs }`. |
| `GET /v1/vms/{name}/exec/{jobId}` | Poll an async exec job. |
| `POST /v1/vms/{name}/access/enable` | Retroactively install/enable OpenSSH plus the management key on an existing guest, over the existing management transport. Mutating: add to `Test-EpicVMMutationRequest`. |

Transport selection is per guest, resolved from the VM's recorded profile and
`managementTransport`:

- Windows guests -> WinRM over Tailscale, admin token, `elevate` is implicit.
- Linux guests -> `ssh.exe`, per-VM DPAPI key, `elevate` maps to `sudo -n`.

**B. Real SSH / SCP for interactive or bulk transfer.**

`POST /v1/vms/{name}/access/tunnel` opens a **loopback-only** TCP forwarder on the Windows
host to the guest's `100.x:22`, and mints a **single-use, time-boxed** grant containing the
public key plus a short-lived private key sealed for the caller. The caller gets a
`ProxyCommand` it can drop straight into `ssh` / `scp` / `rsync`.

This exists because bulk file transfer and genuine interactive shells are real needs, but
they are *not* the daily driver. The private key still never reaches the dashboard, the
browser, or kvm2 - only the caller who asked for it, for a bounded window.

**C. Browser console** - unchanged, via `ConsoleProvider.ps1` plus Guacamole.

### 3.2 Why exec is the primary path

An agent doing work on a VM does not want a TTY. It wants: run this, read stdout, check
the exit code, move on. A structured exec API is scriptable, auditable, bounded, and
returns exactly what an agent needs to decide its next step. Interactive SSH for an agent
means parsing terminal escape sequences, which is strictly worse.

The user said "ssh into the vm and do work on it easily" and "I don't care how they are
accessed". Exec-over-SSH is SSH doing the work; the plan just makes the agent-facing
surface the one that is actually reliable. Real SSH remains available via surface B.

### 3.3 Elevated access model

- **Ubuntu**: a dedicated `epicvm` account, key-only SSH, `NOPASSWD` sudo. Elevation is
  `sudo -n` with no interactive prompt, so a non-interactive exec can never hang on a
  password prompt. `ubuntu` is left in place for a human, password-locked.
  - Tradeoff, stated plainly: `NOPASSWD` sudo for that account is root-equivalent in the
    guest. This matches the standard cloud-image default and is defensible because the
    account is per-VM, disposable, tailnet-internal, and its blast radius is that user's
    own VM. If a tighter posture is wanted, the alternative is a scoped sudoers drop-in
    plus an explicit `epicvm-escalate`, which is more friction for a marginal gain in a
    disposable guest. **Recommendation: NOPASSWD, documented.**
- **Windows**: the existing local-admin WinRM token. No new elevation surface needed.
- **Omarchy**: already capable via `sudo -S`. Reused as-is.

### 3.4 Non-negotiable safety properties

- Guest SSH listens only on the Tailscale interface, firewalled to `100.64.0.0/10` with
  `EdgeTraversalPolicy Block` - same shape as `TailscaleProvider.ps1:300`.
- `PasswordAuthentication no` on every guest we configure.
- Keys are generated per VM, sealed with machine-scope DPAPI, and the plaintext temp copy
  is deleted in `finally` (existing Omarchy pattern).
- No command text, output, or key material is written to the agent log. Exec invocations
  are recorded as `{vm, user, elevate, commandHash, exitCode, durationMs}`.
- Every access action is auditable from the host. An agent with root in a guest should
  never be an invisible event.

---

## 4. Workstreams

### WS-1 - Per-profile capability flags (blocking prerequisite)

The hardcoded `profile -ne 'gaming'` / `profile -ne 'omarchy'` checks in
`Provisioning.ps1:170-171` and `:754-755` cannot express a headless profile.

- Add to each profile case: `requiresGpuValidation`, `requiresStreaming`,
  `requiresOmarchyGpuValidation`, `managementTransport`, `consoleBackend`.
- Replace the name comparisons with reads of those flags in the ready gate, the stage
  restart gate, and the stage classifier.
- Do not add a GPU stage for a profile that has no GPU.
- Extend the redacted job allowlist (`Provisioning.ps1:360-380`) with the new non-secret
  fields.

Files: `remote_agent/windows/Provisioning.ps1`,
`remote_agent/windows/providers/OmarchyProvider.ps1` (profile passthrough).
Tests: `remote_agent/windows/tests/Provisioning.Tests.ps1`.

### WS-2 - Shared exec core

Extract the process/SSH mechanics from the Omarchy-only path into a guest-agnostic core,
so Windows and Linux guests use the same caller shape.

- New `remote_agent/windows/providers/GuestExecProvider.ps1`:
  - `Invoke-EpicVMGuestExec` - transport dispatch.
  - `Invoke-EpicVMLinuxSshExec` - the generalized body of `Invoke-EpicVMOmarchySsh`
    (`OmarchyProvider.ps1:530-570`), parameterized on key path and known-hosts path
    rather than hardcoded to `omarchy-*.dpapi`.
  - `Invoke-EpicVMWindowsWinRmExec` - wraps `Invoke-EpicVMManagementTransport`.
  - `New-EpicVMGuestSshKeyPair` - generalize `New-EpicVMOmarchySshKeyPair`.
  - Key path convention: `<VmRoot>\<vm>\guest-management-key.dpapi` and
    `<VmRoot>\<vm>\guest-known-hosts`, matching the existing per-VM folder layout. Keep
    reading the old `omarchy-*` names for backward compatibility.
- Output cap: 1 MiB stdout / 256 KiB stderr with an explicit `truncated` flag, mirroring
  the existing request-body cap.
- Timeouts: default 60s, hard max 300s synchronous. `async: true` returns a job id for
  longer work so the single-threaded listener is never blocked.

Files: new `GuestExecProvider.ps1`, edits to
`remote_agent/windows/providers/OmarchyProvider.ps1` (delegate to the shared core),
`remote_agent/windows/providers/GuestProvider.ps1` (add the provider to the dispatch set).
Tests: new `remote_agent/windows/tests/GuestExecProvider.Tests.ps1`.

### WS-3 - Agent routes

- Add `GET /v1/vms/{name}/access`, `POST /v1/vms/{name}/exec`,
  `GET /v1/vms/{name}/exec/{jobId}`, `POST /v1/vms/{name}/access/enable`, and
  `POST /v1/vms/{name}/access/tunnel` to `EpicVM.Agent.ps1`.
- Add the mutating ones to `Test-EpicVMMutationRequest` (`:825-828`).
- Enforce the existing conventions on every new route: bearer auth is already global,
  plus `X-Request-Id`, `Idempotency-Key` on mutations, `ConvertTo-EpicVMJsonResponse`, and
  `New-EpicVMApiError` with allowlisted codes only. Add new failure codes to
  `Get-EpicVMGuestProviderFailure` (`:726+`) rather than letting raw exception text cross
  the boundary.
- `access/enable` runs the guest bootstrap over the *existing* transport, so it works on
  any guest that has a working management transport. It is idempotent.

Files: `remote_agent/windows/EpicVM.Agent.ps1`,
`remote_agent/windows/AgentTransport.ps1` (reuse the async-operation path for `async`
exec).
Tests: `remote_agent/windows/tests/Agent.Tests.ps1`,
`remote_agent/windows/tests/AgentTransport.Tests.ps1`.

---
### WS-4 - Guest bootstrap scripts (new + retrofit)

**Windows retrofit** (`access/enable` payload, executed over WinRM as admin):

1. `Add-WindowsCapability OpenSSH.Server~~~~0.0.1.0`, or install the capability if the
   payload is a Feature-on-Demand failure.
2. `sshd_config.d/epicvm.conf`: `PubkeyAuthentication yes`,
   `PasswordAuthentication no`, `PermitEmptyPasswords no`.
3. `administrators_authorized_keys` with the management public key, ACL-locked to
   `SYSTEM` + `Administrators`. This is the documented Windows OpenSSH requirement and a
   common silent failure.
4. Start `sshd`, set `Automatic`.
5. `New-NetFirewallRule` TCP 22 scoped to `100.64.0.0/10`, `EdgeTraversalPolicy Block`.
6. **Verify with a real `ssh` round trip** before reporting success. Enabling OpenSSH is
   not proof that access works.

**Ubuntu seed** (cloud-init NoCloud, baked at template build):

- `epicvm` user, key-only, `NOPASSWD` sudo, `/bin/bash`.
- `openssh-server` installed and enabled at build time, so access works on first boot with
  no post-provision repair needed.
- `PasswordAuthentication no`, `PubkeyAuthentication yes`.
- Base packages for agent work: `ca-certificates`, `curl`, `git`, `python3`,
  `python3-pip`, `python3-venv`, `build-essential`, `nodejs` / `npm` (pinned source),
  `jq`, `unzip`, `htop`. Deliberately **no** Docker daemon in v1: nested containers
  inside a guest add a large surface for no benefit here.
- Tailscale installed and enrolled to `tag:epicvm-guest` at first boot, so the guest is
  reachable at `100.x` like every other guest.
- Burn the seed after consumption, matching the existing Omarchy sanitation discipline.

Files: `remote_agent/windows/providers/GuestExecProvider.ps1` (Windows retrofit script),
new `scripts/Build-EpicVMUbuntuTemplate.ps1` (Ubuntu builder),
`remote_agent/windows/providers/UbuntuProvider.ps1` (profile, readiness, validation).

Tests: `remote_agent/windows/tests/GuestExecProvider.Tests.ps1`,
new `remote_agent/windows/tests/UbuntuProvider.Tests.ps1`,
new `remote_agent/windows/tests/UbuntuTemplateBuilder.Tests.ps1`.

### WS-5 - Ubuntu profile, template, and manifest

- `Get-EpicVMProvisioningProfile` gains a `ubuntu` case: 4 vCPU, 8 GiB RAM, 96 GiB disk,
  `gpu = $false`, `managementTransport = 'tailscale_ssh'`, `consoleBackend = 'none'`,
  `experimental = $true` until the pilot passes.
- `scripts/Build-EpicVMUbuntuTemplate.ps1` mirrors `Build-EpicVMOmarchyTemplate.ps1`:
  plan-only unless `-Execute`, disposable Gen2 builder on a NAT/external switch, ISO
  sha256 pinned, UEFI, **Secure Boot on** (Ubuntu supports it; Omarchy needs it off), vTPM
  off for simpler recovery, dynamic VHD, `fullCopy = $true`, `immutable = $true`,
  `noGuestSecrets = $true`, `managementTransport = 'tailscale_ssh'`,
  `consoleBackend = 'none'`.
- `Test-EpicVMUbuntuTemplateManifest` modeled on
  `Test-EpicVMOmarchyTemplateManifest` (`OmarchyProvider.ps1:139-170`), including the
  image-path-inside-manifest-directory check.
- Config keys `UbuntuTemplateManifestPath`, `UbuntuIsoSha256`, `UbuntuPilotValidated`,
  `EnableUbuntuProvisioning`, defaulting to disabled.
- `/v1/capabilities` gains `ubuntu_provisioning` plus `ubuntuProvisioningChecks`, mirroring
  `omarchy_provisioning` (`OmarchyProvider.ps1:225-231`). The dashboard and UI gate on the
  capability, not on a hardcoded profile list.

### WS-6 - Dashboard, UI, CLI

- **Dashboard proxy** (`dashboard/app.py`): agent-facing routes behind the existing auth +
  CSRF + `_enforce_vm_user_access` (`app.py:3557`) path -
  `GET /dashboard/api/vms/<name>/access`,
  `POST /dashboard/api/vms/<name>/exec`,
  `POST /dashboard/api/vms/<name>/access/enable`. The server holds the agent token and the
  guest credential; neither is returned to the browser. Reuse the `redact_host_record`
  discipline.
- **CLI**: extend `server/epicvm-remote-host` with `access <vm>`, `exec <vm> -- <command>`,
  and `access-enable <vm>`. This is the kvm2-side path for scripting.
- **UI** (`dashboard_v2/src/lib/provisioningUi.js:29-38`): `ubuntu` is a non-GPU profile,
  so it must not be added to the `gaming || omarchy` branch. Add a `streamingRequired`
  awareness so the UI hides the Sunshine/pairing panel for Ubuntu.
  `epicvm_web/src/pages/AccountWorkspace.jsx`: add the `Linux Server (Ubuntu)` option,
  gated on `host.capabilities?.ubuntu_provisioning`, and show `accessTransport` per VM.
- **Docs**: `docs/GUEST-ACCESS.md` with the exact invocation an agent should read at the
  start of a session, plus a correction to the stale ACL in
  `remote_agent/windows/README.md` and `docs/REMOTE_HOSTS.md`.

Files: `dashboard/app.py`, `dashboard_v2/src/lib/provisioningUi.js`,
`dashboard_v2/src/lib/hostPlacement.js`, `epicvm_web/src/pages/AccountWorkspace.jsx`,
`server/epicvm-remote-host`, `remote_agent/windows/README.md`, `docs/REMOTE_HOSTS.md`,
`docs/GUEST-ACCESS.md`.

Tests: `tests/test_provisioning_api.py`, new `tests/test_guest_access_api.py`,
`dashboard_v2/tests/provisioningUi.test.mjs`, new
`dashboard_v2/tests/guestAccessUi.test.mjs`.

### WS-7 - PC-side agent wrapper

The agent working on the PC should not hand-assemble dashboard URLs and headers.

- `scripts/epicvm-guest.ps1`:
  - `-Vm <name> -Access` - print transport, endpoint, user, and the recommended command.
  - `-Vm <name> -Exec '<command>' [-Elevate] [-Stdin <file>] [-TimeoutSec n]`.
  - `-Vm <name> -Upload <local> -Remote <path>` / `-Download`.
  - Reads the dashboard URL and agent token from a local protected file; never prints the
    token; supports `-Json` for structured consumption.
- File transfer rides the exec channel as bounded base64 for small files, and switches to
  the tunnel plus `scp` above a size threshold. Document the threshold.

---

## 5. Prerequisites Epic must handle (control plane + infra)

1. ~~Tailscale ACL: add port 22.~~ **RESOLVED 2026-09-25 - not needed.** The live policy is
   a wildcard `* -> *` grant, so port 22 is already open to guests. The
   `remote_agent/windows/README.md` ACL is documentation-only and does not match
   production. See section 0 Finding 1.
2. **Tailscale OAuth client** is confirmed live and able to read/write the ACL and mint
   guest auth keys. Only remaining decision: whether to adopt a separate
   `tag:epicvm-linux` for Linux guests. Note that `TailscaleProvider.ps1:79` currently
   hard-refuses any tag other than `tag:epicvm-guest`, so a separate tag is a code change
   as well as an ACL change. The live policy is already wildcard-open, so this is a
   hardening choice, not a blocker. **Recommendation: adopt the separate tag when the
   policy is rewritten.**
3. **Phase A first:** repair Windows provisioning to one `ready` VM. Nothing downstream can
   be honestly verified before that exists.
4. **Ubuntu ISO pin**: exact version and sha256. Recommend Ubuntu Server 24.04 LTS.
5. **Agent-to-host reachability for the tunnel surface**: surface B binds loopback on the
   Windows host, so the caller must already have a path to that host. This PC is already on
   the tailnet at `100.72.220.117`, so surface B is available here. If a caller is off
   tailnet, surface A only. **Decision: use surface A for the dashboard/kvm2 path, surface
   B from this PC.**
6. **Pinned package sources** for the Ubuntu seed (NodeSource version, Ubuntu LTS pocket)
   so the image is reproducible.
7. **Stale tailnet cleanup**: 36 device records, roughly 20 dead EpicVM guests. Decide
   whether to revoke the dead ones as part of Phase B, since it is a live hygiene problem.

---
## 6. Verification plan

Per Epic's standing rule, artifact presence is not acceptance. Each gate below must be
proven against a real guest.

**Static / local (build on the PC, per the EpicVM/KVM2 split)**

- `py -3.13 -m pytest tests/test_guest_access_api.py tests/test_provisioning_api.py -q --basetemp <fresh>`
- `node --test dashboard_v2/tests/` (or the repo's existing runner)
- `scripts/Run-EpicVMFocusedPester.ps1` over `GuestExecProvider`, `UbuntuProvider`,
  `Provisioning`, `Agent`, `AgentTransport`.
- Parse-check all touched `.ps1` (the repo already does a 72-file parse pass).

**Phase A: provisioning repair (the gate for everything else)**

- Provision one minimal `standard` VM and drive it to `state=ready`.
- Confirm the record in `E:\EpicVM\provisioning-jobs.json` reaches `ready` and a matching
  Tailscale device appears online in `GET /tailnet/-/devices`.
- Capture the exact stage where it previously failed. Do not replay the 75 historical
  failures; reproduce one and fix forward from evidence.

**Template build (PC, maintenance window, gated)**

- `Build-EpicVMUbuntuTemplate.ps1` plan-only, then `-Execute`.
- `Verify-EpicVMTemplatePublication.ps1` against the new manifest.
- Quarantine any failed builder via `Quarantine-EpicVMInvalidTemplate.ps1`.

**Live guest (the real gate)**

- Provision a real `ubuntu` VM. Confirm `management_handoff` reaches ready **without**
  `gaming_gpu`, `omarchy_gpu`, `streaming_setup`, or `stream_validation` running.
- `GET /v1/vms/{name}/access` returns `tailscale_ssh`, ready.
- `exec` a read-only probe, then a `sudo -n id` proving elevation, then a write probe.
- Reboot the VM, re-run the probe - prove access survives reboot.
- **Retrofit the Phase A Windows VM**: `access/enable`, then prove a real `ssh` round trip
  from the host, then a real admin action, then confirm the Sunshine/streaming path still
  works afterward (the retrofit must not disturb it).
- Confirm a long-running command with `async: true` does **not** stall `GET /v1/health` on
  the agent.
- Confirm nothing sensitive appears in agent logs.

**Deployment**

- Build on the PC. Deploy and runtime-check on kvm2 only, per the standing split.
- Use `scripts/Install-EpicVMAgentSourcesSafe.ps1 -ReportPath <path>` and compare hashes
  before and after. Deploy to `/opt/blobe-vm`. Back up first.
- Production source `/opt/blobe-vm`, DB `/opt/blobe-vm/epi/memory.sqlite3`, `blobedash`
  container mounts `/opt/blobe-vm/dashboard` read-only.

**Explicitly unverified until proven**

- Agent-path gaming acceptance (input, audio) is separate from this work and is not
  claimed by it.
- The tunnel surface's real `scp` throughput is unmeasured until a live transfer runs.
- Ubuntu provisioning has never been run. It is a plan, not a capability.

---

## 7. Phasing

| Phase | Contents | Can ship without |
| --- | --- | --- |
| **A** | **Repair Windows provisioning to one `ready` VM (new, blocking)** | - |
| B | Stale tailnet sweep of the 36 dead device records | Phase A |
| 1 | WS-1 capability flags | anything else |
| 2 | WS-2 + WS-3 exec core and routes | Ubuntu |
| 3 | WS-4 Windows retrofit + `access/enable` | Ubuntu |
| 4 | WS-6 dashboard/CLI/UI for exec | Ubuntu |
| 5 | WS-7 PC-side wrapper | Ubuntu |
| 6 | WS-5 Ubuntu profile, builder, manifest | - |
| 7 | Pilot hardening, then flip `EnableUbuntuProvisioning` | - |

**Phase A is new and it is first, for a concrete reason.** Section 0 Finding 2 shows all
75 provisioning jobs are in terminal failure and `E:\EpicVM\vms` is empty. There is no
guest to prove exec against. The verification plan in section 6 demands a live guest, so
the access workstreams cannot be honestly verified until one provisions successfully.
Phase A therefore has to happen first, and it is also independently the highest-value fix
on the list - the host currently cannot deliver a working VM at all.

The dominant failure is `agent_restart` / `reverification_failed` across 17 jobs, which
points at the agent service restart or the post-restart readiness re-verification rather
than at the guests themselves. The next most common is `guest_bootstrap_not_ready` on
fresh standard-profile jobs. Phase A should start by reproducing a single minimal standard
VM, capturing where it actually breaks, and fixing forward from evidence rather than
replaying all 75 histories.

Original Phase 3 was "retrofit existing VMs". It no longer has a target. It stays in the
table but runs against the **first VM Phase A produces**, which is the same code path and
the same proof, just against a VM we control end to end.

---

## 8. Risks and open questions

**Open questions for Epic** (each has a recommendation; none blocks starting Phase A):

1. Separate Tailscale tag for Linux guests, or reuse `tag:epicvm-guest`?
   *Recommend: separate tag, applied together with the ACL rewrite since the current
   `TailscaleProvider.ps1:79` guard hard-refuses it.*
2. Should the PC be joined to the tailnet (enabling surface B), or is surface A enough?
   *Recommend: joined - this PC is already on the tailnet at `100.72.220.117`.*
3. Is `NOPASSWD` sudo acceptable for the guest `epicvm` account?
   *Recommend: yes, per section 3.3.*
4. Docker in the Ubuntu guest, now or later?
   *Recommend: later, v1 stays flat.*
5. Ubuntu LTS version?
   *Recommend: 24.04 LTS.*
6. **Should the wildcard tailnet policy be tightened now?** The live policy is `* -> *` on
   all ports plus Tailscale SSH as root on self, far wider than the documented intent.
   This is unrelated to the access feature and is a live exposure today.
   *Recommend: yes, as its own change*, with a rollback-ready copy of the current policy
   first, and not bundled into the access work.

**Risks**

- *No working guest.* The single largest risk. Every downstream verification depends on
  Phase A succeeding first. Mitigated by making Phase A blocking and evidence-driven.
- *Single-threaded listener.* The most likely way to ship a bug in the access work is an
  exec that blocks for minutes. Mitigated by the sync timeout cap plus the async job path,
  and called out as an explicit live test.
- *Silent Windows OpenSSH failure.* The `administrators_authorized_keys` ACL is the
  classic trap. Mitigated by requiring a real `ssh` round trip in the enable path.
- *Retrofit disturbing gaming.* `access/enable` touches WinRM-adjacent guest config.
  Mitigated by the explicit post-retrofit streaming check in the verification plan.
- *Scope creep into a general remote-exec platform.* Mitigated by keeping the surface
  narrow: per-VM, per-guest-user, bounded, audited, and limited to guests EpicVM already
  manages. A general bastion is a different project and should not be smuggled in here.
- *Package drift in the Ubuntu image.* Mitigated by pinned sources in WS-4/WS-5 and the
  existing immutable-manifest discipline.

---

## 9. File map

**New**

- `remote_agent/windows/providers/GuestExecProvider.ps1`
- `remote_agent/windows/providers/UbuntuProvider.ps1`
- `scripts/Build-EpicVMUbuntuTemplate.ps1`
- `scripts/epicvm-guest.ps1`
- `docs/GUEST-ACCESS.md`
- `remote_agent/windows/tests/GuestExecProvider.Tests.ps1`
- `remote_agent/windows/tests/UbuntuProvider.Tests.ps1`
- `remote_agent/windows/tests/UbuntuTemplateBuilder.Tests.ps1`
- `tests/test_guest_access_api.py`
- `dashboard_v2/tests/guestAccessUi.test.mjs`

**Modified**

- `remote_agent/windows/EpicVM.Agent.ps1` (routes, mutation allowlist)
- `remote_agent/windows/AgentTransport.ps1` (async exec job)
- `remote_agent/windows/Provisioning.ps1` (capability flags, ubuntu case, redacted fields)
- `remote_agent/windows/providers/OmarchyProvider.ps1` (delegate to shared core)
- `remote_agent/windows/providers/GuestProvider.ps1` (dispatch)
- `remote_agent/windows/providers/TailscaleProvider.ps1` (tag guard, if a Linux tag is adopted)
- `remote_agent/windows/README.md`, `docs/REMOTE_HOSTS.md` (routes, ACL correction)
- `dashboard/app.py` (access/exec proxy)
- `dashboard_v2/src/lib/provisioningUi.js`, `dashboard_v2/src/lib/hostPlacement.js`
- `epicvm_web/src/pages/AccountWorkspace.jsx`
- `server/epicvm-remote-host` (access, exec, access-enable)