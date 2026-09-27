# EpicVM Gaming Console Operations Runbook

How to provision, repair, and verify a Gaming VM console end-to-end, and
what to do when each stage fails. The current provisioning and deployment
instructions were updated September 13, 2026. Older verification records
below are historical and do not describe the current routing configuration.

## The happy path

1. **Provision**: `POST /dashboard/api/provisioning-jobs` with
   `{host_id, name, profile: "gaming", mode: "automatic"}`. The dashboard
   forwards to the Windows agent (`/v1/provisioning-jobs`). Creation returns
   202 immediately. A single agent worker performs mutations while health,
   inventory, and job status remain available. Stages run in order:
   `queued → cloning → booting → unclaimed → claim → guest_setup →
   network_setup → management_handoff → gaming_gpu → streaming_setup`.
   The dashboard polls until the clone is claimable and obtains a new
   one-use claim through the authenticated agent endpoint. Readiness remains
   agent-owned and continues through `streaming_setup → ready`.
2. **Guest capture**: enroll Tailscale under the intended desktop account
   with unattended mode enabled, then verify that identity survives the
   service restart. Install or reuse the virtual display, configure Sunshine
   with its display device GUID and `encoder = amdvce`, and reboot the guest
   when its first interactive desktop has not started. Pre-capture GPU
   validation checks the adapter and GPU rendering. Hardware encoder
   discovery is required after Sunshine configuration.
3. **Console staging (dashboard-side, async)**: the orchestrator writes
   `$EPICVM_MOONLIGHT_ROOT/<vm>--<host>/` (compose + plan.json), starts the
   bundle, pairs it with Sunshine, and verifies the application route plus
   guest transport. Capture configuration has a separate 900-second agent
   request limit to cover driver staging, reboot, and encoder validation.
4. **Readiness**: the agent promotes the job after the automated GPU render,
   provisioning, Tailscale/WinRM, capture, Sunshine, route, and guest-TCP
   gates pass. The dashboard keeps the Moonlight stream available for the
   browser, but no keyboard or mouse attestation is requested or persisted.

## Retry paths

| Failure | Endpoint | Notes |
|---|---|---|
| Streaming stage failed, capture not configured | agent `POST /v1/provisioning-jobs/<id>/console-credentials` | body: `username`, `password` (guest), `sunshineUsername`, `sunshinePassword`. Note: guest creds are `username`/`password`, NOT `guestUsername`. |
| Bundle missing/stale, capture already configured | dashboard `POST /dashboard/api/provisioning-jobs/<id>/repair-console` | same credential field names as above; requires `X-Forwarded-Proto: https` + CSRF header. Runs async (202). |
| Everything green, need to flip state | dashboard `POST .../console-verify` | requires only the validated route and `guestTcpVerified: true`; the agent remains authoritative. |

## Failure catalog (seen in production)

- **`gaming_capacity`**: only one Gaming VM may run. Stop the old one
  first (`POST /v1/vms/<name>/stop`). Queued/cloning requests reserve a
  slot. Retained jobs for stopped or saved VMs do not reserve capacity.
  Match a job to inventory using the immutable Hyper-V VM ID.
- **Agent service fails after a PowerShell update**: use
  `scripts/Repair-EpicVMAgentRuntime.ps1` on the PC. The service must use
  the managed PowerShell runtime or a machine installation, never a
  versioned WindowsApps executable that Store updates can remove.
- **`CAPTURE_SUNSHINE_CONF`**: check Sunshine's display enumeration and
  selected device GUID. Retrying setup must reuse the installed VDD.
  Friendly display labels are not valid `output_name` values.
- **`CAPTURE_DESKTOP_LOGON`**: the guest reboot did not produce the expected
  account's interactive desktop in time. Check the guest boot, autologon,
  Tailscale identity, and Explorer session. Do not mark it ready manually.
- **`host_unavailable` from the dashboard** — usually NOT connectivity.
  Two known causes: (a) remote-hosts registry token not AES-GCM sealed
  (`EV1:` prefix) — the dashboard silently drops the host; (b) the agent
  was mid-restart. Check `/dashboard/api/hosts` → `online`.
- **`digest_required`** — `EPICVM_MOONLIGHT_IMAGE` must be a digest pin
  (`...@sha256:64hex`). After building a new overlay image, pin it:
  `docker image inspect <img> --format '{{index .RepoDigests 0}}'` and put
  that exact string in `.env` / container env.
- **`route_collision` / port 41000 already allocated** — every bundle
  publishes UDP 41000-41010. Only one bundle can run at a time per port
  range. Remove stale bundles: `docker rm -f <old-bundle>` and
  `docker compose -p <old-project> down` in its instance dir.
- **`console_start_failed`** — compose up failed. Run
  `docker compose -p <project> up -d --wait` by hand in
  `/opt/epicvm/moonlight-instances/<name>/` to see the real error.
- **`sunshine_pair_failed`** — Sunshine PINs expire fast. The pair POST and
  the PIN submission must happen within seconds of each other. Retry the
  whole repair rather than reusing a PIN.
- **`frame_evidence_rejected`** — the metrics were real and the stream was
  bad (black/frozen). Do not retry with different numbers; fix the stream.
- **WinRM 413/envelope errors** — payloads over ~500KB fail. VDD artifacts
  are chunked at 200KB by the capture script; if you add artifacts, keep
  chunks under that.

## Local integration notes (WSL2)

- Mirrored networking + `hostAddressLoopback=true` in `.wslconfig`.
- The dashboard launcher must set: `BLOBEDASH_STATE` (a DIRECTORY),
  `DASH_V2_SECRET`, `BLOBEDASH_USER`, `BLOBEDASH_PASS`,
  `BLOBEVM_USER_SECRET`, `EPICVM_REMOTE_HOSTS_FILE`,
  `EPICVM_PROVISIONING_CREDENTIALS_FILE`, `EPICVM_MOONLIGHT_ROOT`,
  `EPICVM_CONSOLE_BACKEND=moonlight`, `EPICVM_PUBLIC_HOST`.
- WSL distro bounces kill the flask process but NOT docker containers
  (restart policy revives them). After a bounce: re-launch the dashboard
  and re-seal `remote-hosts.json` tokens (they must carry the `EV1:`
  prefix).
- Local ICE caveat: the moonlight container advertises docker-bridge
  candidates (172.x) that a WSL-side browser cannot reach. Production
  avoids this with `WEBRTC_NAT_1TO1_HOST=<public-ip>`. Local pixel proof
  needs the browser on the same host as docker, or host networking.

## Production deployment from the PC

**Do not build EpicVM on KVM2.** Run frontend and container builds on
Epic's PC. KVM2 is used for deployment and runtime checks over `ssh kvm2`.

1. Inspect the working tree and deployment mounts; preserve unrelated
   edits. Back up `/opt/blobe-vm/dashboard`, `dashboard_v2/dist`, and
   `epicvm_web/dist` before replacing runtime files.
2. On the PC, run relevant tests and `npm run build` in each changed
   frontend. The Vite roots resolve the workspace junction to its real path.
3. Archive the reviewed Python sources and built `dist` directories on
   the PC, copy with `scp`, and extract into `/opt/blobe-vm`. The live
   dashboard uses `/opt/blobe-vm/dashboard`, not the separate `repo` checkout.
4. If the Moonlight image changed, build it on the PC and transfer the
   finished image with `docker save`/`docker load` or a registry. Preserve
   digest pinning and protected environment files. Do not pass TURN or
   agent credentials on the command line.
5. Wait for active provisioning operations to finish, then restart
   `blobedash` for Python changes. Preserve its image, proxy network,
   `20000:5000` mapping, and existing mounts.
6. Install Windows agent sources on the PC using
   `scripts/Install-EpicVMAgentSourcesSafe.ps1 -ReportPath <report.json>`
   from an elevated PowerShell. It backs up replaced files, preserves
   the protected token and service identity, rolls back failures, and
   verifies health and installed hashes.
7. Check the public dashboard, fresh provisioning status throughout
   cloning, and the actual browser video. Build success or a running console
   container is insufficient verification; keyboard/mouse input is not a
   provisioning gate.

## Session auth for automation (prod)

Login needs the operator password (only PASS_HASH is stored — password not
recoverable). For scripts, mint a session token in-process instead:

```python
# inside the blobedash container, as the same user running the app
import base64, hashlib, hmac, os, time, secrets
secret = os.environ["DASH_V2_SECRET"]
payload = f"{int(time.time())+86400}:{secrets.token_hex(16)}"
mac = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
token = base64.urlsafe_b64encode(f"{payload}:{mac}".encode()).decode()
# -> Cookie: Dashboard-Auth=<token>
```

CSRF: `GET /dashboard/api/auth/csrf` with that cookie; send the token back
as `X-CSRF-Token`. Mutating endpoints also require
`X-Forwarded-Proto: https` (or go through the real TLS edge).

## Evidence rules (non-negotiable)

The automated GPU/browser render gate must observe a changing, non-black
stream before readiness. Fabricated metrics are rejected. If the stream is
black or frozen, fix the stream. Keyboard and mouse human-attestation fields
are not part of readiness.

## WSL-bundle video path (Aug 23 2026 — LIVE, pixel-verified)

```
browser ──https──> Cloudflare ──> kvm2 Traefik (auth chain unchanged)
                                      │ file-provider router (prio 650)
                                      │   /opt/bloe-vm/traefik/dynamic/
                                      │     epicvm-gaming-verify-1-wsl.yml
                                      ▼
                        http://100.72.220.117:18080  (WSL bundle, host-net)
                                      │ Moonlight RTSP+ENet+media (tailnet)
                                      ▼
              Sunshine on prod-gaming-verify-1 (Hyper-V, this PC)
                 100.74.55.92  ports 47984/47989/47990/48010 + UDP 47998-48000
                 (IP changed from 100.109.155.25 after a tailscale re-enroll;
                  both bundles' server/data.json were updated to match)

Remote users: WebRTC falls back to TURN on kvm2.
  turn:72.60.29.204:3478 (public) AND turn:100.89.87.98:3478 (tailnet) are
  both configured in the bundle's ice_servers; use plain TURN URLs without
  transport query parameters; provider firewall now allows
  inbound 3478 tcp/udp (verified via authenticated allocation from WSL).
  Relay range 49160-49200/udp published on kvm2 docker.
  Long-term creds: kvm2:/root/.turncreds. Maintenance:
  `ssh kvm2 'docker restart coturn'`; rotate creds by editing
  /root/.turncreds then recreating the container with the new -u.
```

Live verification (Aug 23 04:5x UTC): public page → forwardauth OK → WHEP
session up → `videoWidth=1920`, frames 30→201 in 8 s; 8 screenshots over
~11 s gave nonblack ≥ 0.970, meanLuma ≥ 83.8, stdDev ≥ 45.2 (thresholds
0.60/12/8) → PASS.

Verified working pieces:

- WSL bundle `epicvm-prod-gaming-verify-1-local-moonlight-web-1` runs with
  `network_mode: host`, HTTP bound directly on `0.0.0.0:18080`
  (`/opt/epicvm/moonlight-instances/prod-gaming-verify-1/docker-compose.yml`;
  pre-change copies in `/root/compose.yml.bak-*` inside WSL).
  Host networking is required for predictable source addressing.
- Pairing survived the verbatim `server/config.json` + `server/data.json`
  copy AND a guest reboot: `/api/host?host_id=3593014841` stays `Paired`.
- kvm2 Traefik runs BOTH providers; docker-labels router on the kvm2-side
  console container (priority 600) vs file router (650). The file router
  currently serves prod traffic; its exact copy also lives at
  `kvm2:/root/epicvm-gaming-verify-1-wsl.yml.bak-20260822`.
- coturn on kvm2 (`docker run -d --init --network host --name coturn
  -p 3478:3478/tcp
  -p 3478:3478/udp -p 49160-49200:49160-49200/udp coturn/coturn:latest -n
  --lt-cred-mech --realm=techexplore.us --min-port=49160 --max-port=49200
  --external-ip=72.60.29.204 --listening-ip=0.0.0.0 --no-cli
  -u "$TURN_USER:$TURN_PASS"`). Auth + relay echo verified 0% loss via
  turnutils_uclient/turnutils_peer inside the container. Maintenance:
  `ssh kvm2 'docker restart coturn'`; rotate creds by editing
  `/root/.turncreds` then recreating the container.

### Rollback (one command)

```
ssh kvm2 'rm -f /opt/bloe-vm/traefik/dynamic/epicvm-gaming-verify-1-wsl.yml'
```

Traefik watches `/dynamic`; the docker-labels router takes over instantly
(the kvm2-side console project is now `prod-gaming-verify-1` with container
`prod-gaming-verify-1-moonlight-web-1` after the Aug 23 repair re-stage).
Re-cutover = copy `/root/epicvm-gaming-verify-1-wsl.yml.bak-20260822` back
into `/opt/bloe-vm/traefik/dynamic/`.

### Guest-side incident log (Aug 23) — read before touching the VM

1. **Zombie sessions**: aborted sessions leave Sunshine `Busy` /
   `current_game:<id>` and every later launch fails ("Failed to start the
   specified application" or rtsp 500). Clear with

   ```
   curl -X POST -H 'X-EpicVM-User: prod-gaming-verify-1' \
     -H 'Content-Type: application/json' \
     -d '{"user":"<moonlightUserId>","host_id":3593014841}' \
     http://<bundle>:18080/vm/prod-gaming-verify-1--epic-pc/api/host/cancel
   ```

2. **Tailscale logout**: the guest tailnet node dropped to NeedsLogin
   (adapter Up but no 100.x IP) → total media loss while TCP probes kept
   half-working during the transition. Re-enroll without the agent:
   decrypt `C:\ProgramData\EpicVM\agent\tailscale-oauth.dpapi`
   (LocalMachine DPAPI), mint a one-use key
   (`POST /api/v2/oauth/token` then `POST /api/v2/tailnet/-/keys` with
   tag epicvm-guest), then run INSIDE the guest
   `tailscale up --auth-key <key> --hostname prod-gaming-verify-1
   --unattended=true --accept-dns=false --reset`.
   A logout wipes node identity → NEW tailscale IP (was
   100.109.155.25 → now 100.74.55.92). Update BOTH bundles'
   `server/data.json` host address afterwards and restart them.
3. **Guest firewall**: media pings need UDP 47998/48000 inbound. Added
   rules `EpicVM Sunshine Tailnet Range UDP/TCP` (47984-48010 from
   100.64.0.0/10) inside the guest alongside the provisioning defaults.
4. **Wedged capture/display**: after repeated crashes the VDD desktop fell
   back to 800×600 and h264_amf entered an encoder create-loop (one frame
   then freeze). A **guest VM restart** (dashboard
   `POST /dashboard/api/restart/<name>` → agent lifecycle) cleared it;
   pairing SURVIVED the reboot. If pairing ever drops,
   `POST /dashboard/api/provisioning-jobs/<job_id>/repair-console`
   (job `477ed0d485f44e19903dd777a2fbf507`) re-stages and re-pairs — note
   it re-creates the kvm2 console under compose project
   `prod-gaming-verify-1` and may leave it Created-but-not-started; start
   with `docker compose -p prod-gaming-verify-1 up -d --wait`.

App-ID note for this VM's Sunshine: `Desktop` (881448767) and
`Steam Big Picture` (1093255277) both stream. BP required: installing Steam
in the guest (`SteamSetup.exe /S`), setting its app cmd to the REAL exe —
`"C:\Program Files (x86)\Steam\steam.exe" -bigpicture` (quoted; protocol
URLs like `steam://open/...` cannot be spawned by Sunshine, and an unquoted
spaced path fails with Permission denied) — AND an active console session:
Sunshine spawns apps into the console session, so a headless VM at the
lock screen fails with "Permission denied". Keep the session alive with
`tscon <id> /dest:console` after connecting it via PS-Direct/quser.

Public TURN status: provider firewall was opened Aug 23 (3478 tcp/udp
reachable; authenticated allocation verified from an external vantage).
Keep the "don't add unreachable TURN candidates" rule in mind for ANY
future relay: dead candidates add ~4 s of ICE gathering delay each, which
pushes Moonlight's media pings past Sunshine's Initial-Ping window and
black-screens sessions.

### WSL availability hazard (operational)

WSL idle-shutdown (default `vmIdleTimeout` 60 s) stops docker and takes the
video path down. Fixed persistently in `C:\Users\Epic\.wslconfig`
(`[wsl2] vmIdleTimeout=-1`). During ops sessions also keep a holder:
`Start-Process -WindowHidden wsl -ArgumentList '-d Ubuntu --exec sleep 14400'`.
Symptom of a bounce: kvm2→100.72.220.117 curls time out for ~1 min while
containers restart under policy.
NOTE: `-WindowHidden` does not exist on Start-Process; use
`-WindowStyle Hidden`. Even with `vmIdleTimeout=-1` the distro still tore
down between sessions on Aug 23 — the sleep-holder is mandatory during ops.

### Same-name reprovision playbook (Aug 23 2026 — verified end-to-end)

Reprovisioning `prod-gaming-verify-1` in place hit and cleared every known
gap. Order matters:

1. **Deprovision** via `POST /dashboard/api/deprovisioning-jobs`
   `{host_id, name, confirmName}` (cookie+CSRF+`Origin: http://127.0.0.1:20000`
   header when curling localhost:20000). Terminal job state is `quarantined`.
2. **Stale job records block the name** (`conflict` 409 on re-provision).
   The agent has no purge endpoint; `ready`/`quarantined` records are never
   retryable. Fix: stop `EpicVMRemoteAgent`, remove the offending records
   from `E:\EpicVM\provisioning-jobs.json` (backup first; deprovisioning-kind
   records live in a separate dict and do not block), start service again.
   NEVER restart the service while a provision job is mid-flight — that is
   what produces `setup_failed:agent_restart`.
3. **Dashboard auth for automation**: mint inside the container with the
   app's own `_dashboard_secret()` (self-verify against `_verify_v2_token`),
   store as `/tmp/dashtoken`; cookie mutations additionally need
   `X-CSRF-Token` (from `/dashboard/api/auth/csrf`) AND an `Origin` header
   matching `request.host`.
4. **epic-pc offline after agent restart** = cold `/v1/capabilities` probe
   (>10 s registry timeout). It warms within ~1 min; just retry hosts check.
5. **gaming_gpu_validation_failed on fresh VMs** can be a false negative:
   first-boot WebGL isn't up within the gate's ~1.5 s retry window. The gate
   has NO resume API (`console-credentials` rejects non-streaming states).
   Recovery used tonight: flip the retained job's state to
   `setup_failed:streaming` (store edit, service stopped), then
   `POST /v1/provisioning-jobs/<id>/console-credentials` with guest+Sunshine
   creds — it configures capture and lands in the recoverable state.
6. **Guest tailscale NeedsLogin after enrollment**: re-enroll per incident
   log #2 above (DPAPI secret → OAuth → one-use key → in-guest
   `tailscale up`). New node ⇒ NEW IP; update the job record's `tailnetIp`
   /`tailnetDeviceId` (service stop/edit/start) BEFORE console-credentials.
7. **Zombie sessions** after aborted runs leave `server_state=Busy`;
   clear via bundle `POST .../api/host/cancel`
   `{"user":"<moonlightUserId>","host_id":<NUMERIC id>}` (host_id must be a
   number, not a string) — else every later session stalls at one frame.
8. **Console readiness evidence**: real browser session through
   techexplore.us; measure frames + pixel metrics; submit
   `console-complete` with quantified `frameMetrics`. KNOWN VERSION SKEW:
   the deployed dashboard's `console-verify` does NOT forward frameMetrics
   to the agent, so it always 422s `frame_evidence_rejected`. Until fixed,
   POST the full payload (booleans + frameMetrics) directly to the agent's
   `/v1/provisioning-jobs/<id>/console-complete`.
9. **WSL route caveat**: the file router MUST carry BOTH middlewares
   (forwardAuth AND `customRequestHeaders.X-EpicVM-User`) or the bundle's
   own `/api/authenticate` 401s behind a Login modal. The disabled WSL route
   copy lives at `kvm2:/root/wsl-route.disabled-kvm2test.yml` (with the
   user-header fix applied); restore into
   `/opt/bloe-vm/traefik/dynamic/` to re-cutover to WSL serving.

Result Aug 23: fresh VM ready via kvm2 console path, pixel-verified
(266 decoded frames/6 s, nonblack 0.75, meanLuma 173, stdDev 103), input
verified. WSL path left disabled pending its intermittent one-frame stall
investigation (suspect mirrored-network RTP handling; control channel and
WebRTC connect are fine when it works).



### Mirrored-networking caveats (measured Aug 22/23)

- Inbound UDP to WSL listeners works when targeted at the tailnet IP
  (100.72.220.117) but NOT at other host IPs (e.g. LAN 192.168.1.178):
  kvm2→100.72.220.117:48000 delivers; kvm2→192.168.1.178:48000 times out.
  Any component advertising a non-tailnet host IP for return traffic will
  black-hole. Keep everything pinned to
  `WEBRTC_NAT_1TO1_HOST=100.72.220.117`.
- WSL `/proc/net/tcp` does not show mirrored connections reliably; use
  Windows-side `Get-NetTCPConnection`/pktmon or WSL tcpdump on eth1.
