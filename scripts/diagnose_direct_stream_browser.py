"""Probe one signed host stream in an isolated browser without printing secrets."""

import html
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from direct_stream_auth import issue_grant  # noqa: E402

root = Path(sys.argv[1])
route = sys.argv[2]
record = json.loads((root / "dashboard-manifest.json").read_text(encoding="utf-8"))[route]
grant = issue_grant((root / "signing.key").read_bytes(), route=route,
                    user="portal:browser-probe", path=record["streamPath"])
events = []


def describe(url):
    parsed = urlsplit(url)
    return parsed.path


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(channel="chrome", headless=True,
                                         args=["--autoplay-policy=no-user-gesture-required"])
    context = browser.new_context(ignore_https_errors=False, viewport={"width": 1280, "height": 720})
    if '--webrtc-stats' in sys.argv:
        context.add_init_script("""(() => {const Original=window.RTCPeerConnection;
            window.__epicvmPeers=[];
            window.RTCPeerConnection=class extends Original {
                constructor(...args){super(...args);window.__epicvmPeers.push(this)}
            }
        })()""")
    page = context.new_page()
    if '--video-element' in sys.argv:
        def use_video_element(route):
            response = route.fetch()
            body = response.body().decode('utf-8')
            body = body.replace('"forceVideoElementRenderer": false', '"forceVideoElementRenderer": true')
            body = body.replace('"canvasRenderer": true', '"canvasRenderer": false')
            route.fulfill(response=response, body=body)
        page.route('**/default_settings.js', use_video_element)
    if '--audio-context' in sys.argv:
        def use_audio_context(route):
            response = route.fetch()
            body = response.body().decode('utf-8')
            preferred = '    { input: "data", pipes: [DepacketizeAudioPipe, OpusAudioDecoderPipe, AudioPcmBufferPipe], player: ContextDestinationNodeAudioPlayer },\n'
            anchor = '    // Convert data -> audio_sample -> track (MediaStreamTrackGenerator) -> audio_element, Chromium\n'
            if preferred not in body or anchor not in body:
                raise RuntimeError('Pinned audio pipeline layout changed')
            body = body.replace(preferred, '', 1).replace(anchor, preferred + anchor, 1)
            route.fulfill(response=response, body=body)
        page.route('**/stream/audio/pipeline.js', use_audio_context)
    page.on("console", lambda message: events.append(("console", message.type, message.text[:200]))
            if message.type in {"error", "warning"} or 'audio' in message.text.lower() else None)
    page.on("pageerror", lambda exc: events.append(("pageerror", type(exc).__name__, str(exc)[:200])))
    page.on("response", lambda response: events.append(("http", response.status, describe(response.url)))
            if response.status >= 400 else None)
    page.on("requestfailed", lambda req: events.append(("failed", req.failure, describe(req.url))))
    page.set_content('<form method="post" action="'
                     + html.escape(record["hostUrl"] + "/EpicVM/auth/redeem", quote=True)
                     + '"><input name="grant" value="' + html.escape(grant, quote=True) + '"></form>')
    page.evaluate("document.forms[0].submit()")
    page.wait_for_timeout(20000)
    print("page", describe(page.url))
    print("body", page.locator("body").inner_text(timeout=5000)[:400].replace("\n", " | "))
    print("renderers", json.dumps(page.evaluate("""() => ({
        videos: [...document.querySelectorAll('video')].map(v => ({readyState: v.readyState, width: v.videoWidth, height: v.videoHeight})),
        canvases: [...document.querySelectorAll('canvas')].map(c => ({width: c.width, height: c.height})),
        audio: [...document.querySelectorAll('audio')].map(a => ({muted: a.muted, paused: a.paused, volume: a.volume,
            readyState: a.readyState, tracks: a.srcObject?.getAudioTracks?.().map(t => ({enabled: t.enabled, muted: t.muted, readyState: t.readyState}))})),
    })""")))
    if '--audio-interaction' in sys.argv:
        page.locator('body').click(position={"x": 30, "y": 30})
        result = page.evaluate("""() => {const a=document.querySelector('audio');try{a.play().catch(()=>{});return 'requested'}catch(e){return e.name + ': ' + e.message}}""")
        page.wait_for_timeout(1000)
        print("audioPlayResult", result)
        print("audioAfterInteraction", json.dumps(page.evaluate("""() => [...document.querySelectorAll('audio')].map(a => ({muted: a.muted, paused: a.paused, readyState: a.readyState, currentTime: a.currentTime}))""")))
    if '--audio-levels' in sys.argv:
        levels = page.evaluate("""async () => {
            const media = document.querySelector('audio');
            const stream = media?.srcObject;
            if (!stream?.getAudioTracks?.().length) return null;
            const context = new AudioContext();
            await context.resume();
            const source = context.createMediaStreamSource(stream);
            const analyser = context.createAnalyser();
            analyser.fftSize = 2048;
            source.connect(analyser);
            const data = new Float32Array(analyser.fftSize);
            let maxPeak = 0, maxRms = 0;
            for (let sample = 0; sample < 25; sample++) {
                await new Promise(resolve => setTimeout(resolve, 100));
                analyser.getFloatTimeDomainData(data);
                let power = 0, peak = 0;
                for (const value of data) { power += value * value; peak = Math.max(peak, Math.abs(value)); }
                maxPeak = Math.max(maxPeak, peak);
                maxRms = Math.max(maxRms, Math.sqrt(power / data.length));
            }
            await context.close();
            return {maxPeak, maxRms};
        }""")
        print("audioLevels", json.dumps(levels))
    if '--webrtc-stats' in sys.argv:
        print("webrtcAudio", json.dumps(page.evaluate("""async () => {
            const result=[];
            for (const peer of window.__epicvmPeers || []) {
                const stats=await peer.getStats();
                for (const item of stats.values()) if (item.type==='inbound-rtp' && item.kind==='audio')
                    result.push({packetsReceived:item.packetsReceived,bytesReceived:item.bytesReceived,
                        totalAudioEnergy:item.totalAudioEnergy,totalSamplesDuration:item.totalSamplesDuration,
                        concealedSamples:item.concealedSamples, silentConcealedSamples:item.silentConcealedSamples});
            }
            return result;
        }""")))
    if '--metrics' in sys.argv:
        metrics = page.evaluate("""async () => {
            const video = document.querySelector('video');
            if (!video || video.readyState < 2 || !video.videoWidth) return null;
            const count = () => video.getVideoPlaybackQuality?.().totalVideoFrames ?? video.webkitDecodedFrameCount ?? 0;
            const start = count();
            const startTime = video.currentTime;
            const started = performance.now();
            await new Promise(resolve => setTimeout(resolve, 2000));
            const durationMs = performance.now() - started;
            const canvas = document.createElement('canvas');
            canvas.width = 64; canvas.height = 36;
            const context = canvas.getContext('2d', {willReadFrequently: true});
            context.drawImage(video, 0, 0, canvas.width, canvas.height);
            const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
            const values = [];
            let nonblack = 0;
            for (let i = 0; i < pixels.length; i += 4) {
                const luma = .2126 * pixels[i] + .7152 * pixels[i+1] + .0722 * pixels[i+2];
                values.push(luma);
                if (luma >= 8) nonblack++;
            }
            const meanLuma = values.reduce((sum, value) => sum + value, 0) / values.length;
            const variance = values.reduce((sum, value) => sum + (value - meanLuma) ** 2, 0) / values.length;
            return {nonblackFraction: nonblack / values.length, meanLuma,
                stdDev: Math.sqrt(variance), decodedFramesDelta: count() - start, durationMs,
                currentTimeDelta: video.currentTime - startTime,
                frameCounter: count(), readyState: video.readyState};
        }""")
        print("frameMetrics", json.dumps(metrics))
    print("canvasImage", page.evaluate("""() => {const c=document.querySelector('canvas'); if(!c) return null; const x=c.getContext('2d'); if(!x) return null; const d=x.getImageData(0,0,Math.min(16,c.width),Math.min(16,c.height)).data; return [...new Set([...d].filter((_,i)=>i%4<3))].slice(0,12)}"""))
    image_path = next((Path(arg) for arg in sys.argv[3:] if not arg.startswith('--')), None)
    if image_path:
        page.screenshot(path=str(image_path))
    if '--input-check' in sys.argv:
        before = page.evaluate("""() => {const c=document.querySelector('canvas');return c?.toDataURL()}""")
        try:
            page.keyboard.press('Control+Escape')
            page.wait_for_timeout(3000)
            after = page.evaluate("""() => {const c=document.querySelector('canvas');return c?.toDataURL()}""")
            print('input_screen_changed', before != after)
            if image_path:
                page.screenshot(path=str(image_path.with_name(image_path.stem + '.after.png')))
        finally:
            page.keyboard.press('Escape')
    print("events", json.dumps(events[-35:]))
    browser.close()
