# Moonlight Web WebRTC close-race overlay

This directory builds the EpicVM-pinned Moonlight Web image with one narrowly
scoped frontend fix. The upstream ENet output poller could call
`RTCDataChannel.send()` after the browser closed the channel. That raised
`InvalidStateError` in the client and could leave a failed stream worker
spinning. The patch is deliberately tied to the pinned bundle and fails closed
if its minified shape changes.

## Build

From the repository root on the deployment host:

```bash
docker build -f docker/moonlight-web/Dockerfile \
  -t epicvm/moonlight-web:webrtc-close-guard-<source-tag> \
  docker/moonlight-web
```

The deployment's `/opt/blobe-vm/.env` must set
`EPICVM_MOONLIGHT_IMAGE` to the resulting image's `repo@sha256:` reference.
The orchestrator requires a digest-pinned reference, including for a locally
built overlay. Record the previous image reference for rollback.

## Host-seat browser latency profile

`Dockerfile.host-seat` pins the Moonlight Web release used by the deployed
MultiSeat stream and patches only `default_settings.js`. New `/vm/seat-.../`
browser sessions start at 1080p with one queued video frame and the canvas
renderer drawing on frame submission. Gaming VM defaults and saved browser
preferences are unchanged. The settings remain adjustable if a user's network
needs more buffering.

The profile was selected after a live host-seat comparison at 60 fps: Epic
reported quicker, smoother keyboard and mouse feedback with those settings.
This does not establish a measured input-to-picture latency or rhythm-game
acceptance on other networks.

From this directory on the deployment host:

```bash
docker build -f Dockerfile.host-seat -t epicvm/moonlight-web:host-seat-lowlatency .
docker image inspect epicvm/moonlight-web:host-seat-lowlatency \
  --format '{{index .RepoDigests 0}}'
```

Use the printed reference for `EPICVM_MOONLIGHT_IMAGE`.

## Verification

The overlay is not a readiness shortcut. Verify all of the following through
the authenticated browser path:

- the browser receives decoded, changing H.264 frames;
- the screenshot is a real Windows lock/sign-in screen or desktop, not black;
- keyboard and mouse input change the guest image;
- closing the browser does not produce the unguarded `RTCDataChannel.send`
  exception or a sustained Moonlight CPU worker;
- the retained VM identity and GPU-P configuration remain unchanged.
