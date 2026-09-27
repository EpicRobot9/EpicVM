"""Patch the pinned Moonlight Web bundle's ENet send-close race.

The upstream bundle polls ENet output from a timer.  Its normal send path
checks RTCDataChannel.readyState, but the timer path did not.  When a browser
closes a stream, the timer could call send() on a closed channel, raising
InvalidStateError and leaving a failed worker spinning.

This script intentionally fails closed when the pinned upstream bundle changes.
It is used by Dockerfile to produce a reproducible EpicVM overlay image.
"""
from __future__ import annotations

import os
import stat
import sys
import tempfile
from pathlib import Path

OLD = 'for(;r=this.controlStream.pollPacket();)console.debug(r.contents,"enet send"),this.channel.send(r.contents);'
NEW = 'for(;r=this.controlStream.pollPacket();){if(!this.channel||"open"!=this.channel.readyState)return;console.debug(r.contents,"enet send"),this.channel.send(r.contents)}'

# Stream-start stall watchdog.  The pinned server can answer a session start
# with "control: the control stream hasn't successfully connected yet" and
# never deliver a first video frame; the client previously stayed black
# forever with no recovery.  The watchdog waits for the first decoded video
# frame after the WebRTC peer connects; if none arrives within the deadline
# it reloads the page exactly once so the orchestrator's session resume path
# builds a fresh stream instead of presenting a permanent black client.
# The play gate lives inside the video sink class methods, so the watchdog
# call is inserted at the start of the method body (valid class-body syntax).
WATCHDOG_ANCHOR = 'onUserInteraction(){this.videoElement.paused&&this.videoElement.play()'
WATCHDOG_PATCHED = 'onUserInteraction(){epicvmArmFrameWatchdog(this);this.videoElement.paused&&this.videoElement.play()'
WATCHDOG_RETRY = (
    'if(window.__epicvmStreamReloaded)return;window.__epicvmStreamReloaded=!0;'
    'const epicvmRetry=window.parent&&window.parent.__epicvmCancelAndRetry;'
    'if(epicvmRetry){epicvmRetry().then(ok=>{if(ok)window.location.reload()}).catch(()=>{})}'
    'else window.location.reload();'
)
WATCHDOG_SOURCE = (
    'function epicvmArmFrameWatchdog(sink){'
    'if(sink.__epicvmWatchdog)return;sink.__epicvmWatchdog=!0;'
    'let frames=sink.videoElement.getVideoPlaybackQuality?sink.videoElement.getVideoPlaybackQuality().totalVideoFrames:(sink.videoElement.webkitDecodedFrameCount||0);'
    'const started=Date.now();'
    'const timer=setInterval(()=>{'
    'try{'
    'const now=sink.videoElement.getVideoPlaybackQuality?sink.videoElement.getVideoPlaybackQuality().totalVideoFrames:(sink.videoElement.webkitDecodedFrameCount||0);'
    'if(now>frames){clearInterval(timer);return}'
    'if(Date.now()-started<20000)return;'
    'clearInterval(timer);'
    'if(window.__epicvmStreamReloaded){console.warn("epicvm stream watchdog: first frame still missing after one reload; leaving session for orchestrator recovery");return}'
    'console.warn("epicvm stream watchdog: no first video frame; reloading once for a fresh stream");'
    + WATCHDOG_RETRY
    + '}catch(e){clearInterval(timer)}'
    '},1000);'
    '};'
)

# Auto-arm stall recovery.  The click-armed watchdog above never fires for
# headless/automation clients or for users who never interact before the
# stream wedges (observed as Sunshine logging UDP "actively refused" while
# the client sits at one decoded frame).  This installer watches the video
# element directly: once a stream has produced frames and then stops
# advancing for 20s - or never produced its first frame within 20s of being
# sized - it reloads exactly once, mirroring the manual watchdog.
AUTO_WATCHDOG_ANCHOR = 'window.requestAnimationFrame(()=>{'
AUTO_WATCHDOG_SOURCE = (
    'window.epicvmInstallAutoWatchdog=function(){'
    'if(window.__epicvmAutoWatchdogInstalled)return;window.__epicvmAutoWatchdogInstalled=!0;'
    'let lastFrames=-1;let lastChange=Date.now();'
    'setInterval(()=>{'
    'try{'
    'const v=document.querySelector("video");'
    'let retry=false;'
    'if(!v||!v.videoWidth){if(Date.now()-lastChange<20000)return;lastChange=Date.now();console.warn("epicvm auto-watchdog: no video element; retrying fresh session");retry=true'
    + '}else{'
    'const q=v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null;'
    'const f=q?q.totalVideoFrames:(v.webkitDecodedFrameCount||0);'
    'if(f!==lastFrames){lastFrames=f;lastChange=Date.now();return}'
    'if(Date.now()-lastChange<20000)return;'
    'console.warn("epicvm auto-watchdog: stream stalled; reloading once for a fresh session");retry=true'
    '}'
    'if(retry){'
    + WATCHDOG_RETRY
    + '}'
    + '}catch(e){}'
    '},1000);'
    '};'
    'window.epicvmInstallAutoWatchdog();'
    'window.requestAnimationFrame(()=>{'
)


def patch_file(path: str | Path) -> bool:
    target = Path(path)
    text = target.read_text(encoding="utf-8")
    changed = False
    count = text.count(OLD)
    if count == 1:
        text = text.replace(OLD, NEW, 1)
        changed = True
    elif count == 0 and NEW not in text:
        raise RuntimeError(
            f"expected exactly one pinned Moonlight ENet poll loop in {target}, found {count}"
        )
    # The patched form replaces each play-gate opening, so an already-patched
    # bundle has zero raw anchors left but one or two patched markers.
    anchor_count = text.count(WATCHDOG_ANCHOR)
    patched_gate_count = text.count(WATCHDOG_PATCHED)
    if anchor_count > 0:
        # The pinned bundle ships identical video sink classes for the
        # software and hardware renderer paths; arm the watchdog on each.
        if anchor_count not in (1, 2) or patched_gate_count != 0:
            raise RuntimeError(
                f"unexpected video play gate layout in {target}: {anchor_count} anchors / {patched_gate_count} patched"
            )
        text = text.replace(WATCHDOG_ANCHOR, WATCHDOG_PATCHED)
        if WATCHDOG_SOURCE not in text:
            text = WATCHDOG_SOURCE + text
        changed = True
    elif patched_gate_count in (1, 2) and WATCHDOG_SOURCE in text:
        pass
    else:
        raise RuntimeError(
            f"Moonlight stream-start watchdog anchor missing in {target}; the pinned bundle changed"
        )
    # Auto-watchdog: install once per stream.js.  Idempotent on re-runs.
    if AUTO_WATCHDOG_ANCHOR in text and AUTO_WATCHDOG_SOURCE not in text:
        text = text.replace(AUTO_WATCHDOG_ANCHOR, AUTO_WATCHDOG_SOURCE, 1)
        changed = True
    elif AUTO_WATCHDOG_ANCHOR not in text and AUTO_WATCHDOG_SOURCE not in text:
        raise RuntimeError(
            f"auto-watchdog anchor missing in {target}; the pinned bundle changed"
        )
    if not changed:
        return False
    if (
        NEW not in text
        or OLD in text
        or WATCHDOG_PATCHED not in text
        or WATCHDOG_SOURCE not in text
        or AUTO_WATCHDOG_SOURCE not in text
    ):
        raise RuntimeError(f"Moonlight stream patch verification failed for {target}")
    patched = text
    mode = stat.S_IMODE(target.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(patched)
        # Windows refuses replacing a read-only target.  Temporarily grant the
        # owner write permission, then restore the original mode on the new
        # inode.  Linux builders can replace the target directly.
        os.chmod(temporary, mode)
        os.chmod(target, mode | stat.S_IWUSR)
        os.replace(temporary, target)
        os.chmod(target, mode)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} STREAM_JS", file=sys.stderr)
        return 2
    try:
        changed = patch_file(argv[1])
    except (OSError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("patched" if changed else "already-patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
