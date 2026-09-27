# EpicVM RemoteVM Windows agent

This directory contains the Windows host side of EpicVM's RemoteVM feature.
It uses PowerShell 7 and the Hyper-V module. The dashboard never receives a
Hyper-V credential: it calls this agent over a Tailscale address with a bearer
token.

## Install

Recommended: run the guided setup from an elevated PowerShell 7 prompt on the
Windows host:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

It checks PowerShell 7, Hyper-V, and Tailscale; discovers the Tailscale address;
asks for the optional Hyper-V switch; runs the secure installer; and tells you
exactly what to do next. For automation, pass `-TailscaleAddress`, optionally
`-SwitchName`, and `-NonInteractive`.

The lower-level installer remains available:

```powershell
.\install.ps1 -TailscaleAddress 100.72.220.117
```

The installer writes the enrollment credential to the protected `agent.txt`
file for new installations and never prints it. Existing installations using
`agent.token` remain supported. Transfer that file through an approved secure
channel to the EpicVM server, then run `sudo epicvm-remote-host setup`. The server wizard
asks for the host details, enrolls the protected token file, and probes the agent.
It stores the real token under `C:\ProgramData\EpicVM\agent\agent.txt` for new installs,
creates the `EpicVMRemoteAgent` service, and opens TCP/8765 only for
`100.64.0.0/10` (Tailscale's CGNAT range). The listener binds only to the
supplied Tailscale address; wildcard binding is refused. Set `SwitchName` in the
generated `config.json` before creating VMs if Hyper-V should attach a specific
virtual switch.

A quick local check is:

```powershell
Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Content C:\ProgramData\EpicVM\agent\agent.txt)" } http://127.0.0.1:8765/v1/capabilities
```

The service exposes:

- `GET /v1/health`
- `GET /v1/capabilities`
- `GET /v1/vms`
- `POST /v1/vms`
- `GET /v1/vms/{name}`
- `GET /v1/vms/{name}/logs` (empty but explicit until guest log transport is added)
- `POST /v1/vms/{name}/start|stop|restart`
- `DELETE /v1/vms/{name}`
- `POST /v1/vms/{name}/actions/start|stop|restart|delete` (legacy alias)

All endpoints require the configured authorization header and return JSON. Mutation
requests accept an `Idempotency-Key`, are serialized while the provider acts,
and return an `X-Request-Id` header. The provider writes an
`EpicVM-Managed: true` marker into Hyper-V VM notes and refuses lifecycle or
delete operations on VMs without that marker or outside the configured VM root.
Deleting a VM unregisters it but preserves its VHDX for recovery.

## Uninstall

```powershell
.\uninstall.ps1
# Add -PurgeData only when the token, config, logs, and VM data should be removed.
```

The Linux dashboard should register the host with its Tailscale URL, for
example `http://win-gaming.ts.net:8765`, and the token. Public URLs are rejected
by the server-side registry unless the explicit development override is set.

## EpicVM one-click provisioning (source-only until staged)

Provisioning requires the immutable manifest at
`E:\EpicVM\templates\win11-25h2\manifest.json`. Build it only during a
planned maintenance window from an elevated PowerShell 7 session; the builder
is opt-in and has an exact `testre` source-name gate:

```powershell
.\scripts\Invoke-EpicVMTemplateBuilderInteractive.ps1
```

The wrapper prompts in the elevated PowerShell window, passes both
`PSCredential` objects only in memory, and never accepts a password on the
command line. It does not run during installation. Store the host-side OAuth
secret interactively:

```powershell
.\Set-TailscaleOAuthSecret.ps1
```

The one required Tailscale control-plane action is to create a narrowly scoped
service OAuth client with device read/create permission, preauthorize only
`tag:epicvm-guest`, and add the equivalent ACL rule below. The secret is entered
only at the secure prompt, DPAPI machine-encrypted on the Windows host, and
never copied to kvm2.

```json
{
  "tagOwners": { "tag:epicvm-guest": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["tag:epicvm-host", "tag:epicvm-kvm2"], "dst": ["tag:epicvm-guest:3389"] }
  ]
}
```

The kvm2 console plan is source-only here. It requires digest-pinned
Guacamole, guacd, and PostgreSQL images, keeps database/guacd internal, puts
only Guacamole on the existing proxy network with dashboard ForwardAuth, and
refuses to start until kvm2 can reach the guest on TCP 3389.

### Experimental Omarchy + AMD GPU-P profile

Omarchy is a separate, disabled-by-default profile. It is remote Hyper-V only,
uses the pinned Omarchy v3.8.3 ISO, and requires an AMD GPU-P partition,
Tailscale SSH, accelerated guest rendering, Hyprland/Wayland, and Sunshine
hardware encoding. The Microsoft GPU-P support matrix does not list Arch or
Omarchy, so a VM is never marked ready merely because Hyper-V reports it as
running.

The source-only builder is plan-only unless `-Execute` is supplied. It creates
a disposable Gen2 builder on an existing NAT or external Hyper-V switch with
Internet egress (the default is `Default Switch`), uses a removable `cidata`
seed, requires the operator to run the bundled sanitation script, and publishes
a standalone Dynamic VHDX with its SHA-256 in `manifest.json`:

```powershell
.\scripts\Build-EpicVMOmarchyTemplate.ps1
.\scripts\Build-EpicVMOmarchyTemplate.ps1 -Execute
```

The build must remain outside normal service operation until the separate pilot
proves AMD rendering, Sunshine hardware encoding, Tailscale SSH, Moonlight
video/audio/input, and reboot recovery. Enable the dashboard option only after
the host config contains the validated manifest and the explicit
`OmarchyPilotValidated` / `EnableOmarchyProvisioning` gates are intentionally
enabled.
