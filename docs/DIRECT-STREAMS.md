# EpicVM direct streams

EpicVM launches paired gaming VMs and MultiSeat seats through the Windows host's
Moonlight Web path. The public base page at `https://epicbriiiii.zapto.org/`
remains the owner's WindowsStream page. EpicVM resources use
`/EpicVM/<resource>/` on that same host.

## Launch and authorization

The portal's VM console and native-game links lead to
`/EpicVM/stream-launch/<resource>` on KVM2. The dashboard checks the portal
user's VM assignment or seat ownership and signs a 60-second, one-use grant.
The browser posts it to the Windows host gateway. The gateway sets a
resource-scoped, secure session cookie, then Caddy authenticates each HTTP
request before forwarding the EpicVM user header to that resource's private
Moonlight Web instance. The WindowsStream password and personal launcher
credentials are not placed in seat accounts.

Private state is under `%LOCALAPPDATA%\EpicVM\direct-streams` on the Windows
host. The dashboard receives only the signing key and route manifest under
`/opt/blobe-vm/private` on KVM2. Never copy the instance `data.json`, signing
key, cookies, or pairing records into the repository or logs.

## Lifecycle

`scripts/supervise_host_direct_streams.py` checks the KVM2 paired-instance
inventory every 30 seconds. It imports newly paired gaming VMs and seats,
starts their host-local Moonlight processes, registers their Caddy and portal
routes, and restarts a missing process. A quarantined seat is disabled and its
stream process stopped; its Windows account and profile remain reusable.
`scripts/Start-EpicVMDirectStreams.ps1` starts the supervisor. WindowsStream's
start script also calls it. A per-user Windows Startup shortcut starts it after
sign-in.

The firewall rule `EpicVM Direct Streams WebRTC UDP` permits the Moonlight Web
executable on UDP ports 40022-40200. The supervisor refuses to allocate a
stream outside that range. The host router did not expose UPnP mappings during
setup, so ICE may use STUN or TURN according to the bundled configuration.

## Checks and recovery

- Check that the local gateway listens on 8090, and that each enabled route's
  `localPort` in `routes.json` listens on loopback.
- Probe public authorization with `scripts/probe_host_stream_gateway.py` and
  the private key path. The `--host-check` option also queries a paired host.
- Caddy imports the generated `caddy-routes.caddy` from the WindowsStream
  Caddyfile. Validate Caddy before a reload.
- An unpaired or unreachable guest may have a stream page but cannot pass the
  paired-host readiness check. Repair its Sunshine/Moonlight pairing first.
- A portal account or VM assignment change prevents a fresh EpicVM grant.
  Existing browser stream cookies expire after eight hours; stopping a seat
  also removes its route and stream process within the supervisor's next poll.

The original KVM2 Moonlight bundles remain available for repair, while EpicVM's
normal launch path uses the Windows host routes.
