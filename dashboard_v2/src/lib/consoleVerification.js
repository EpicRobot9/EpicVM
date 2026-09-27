const SCOPED_CONSOLE_ROUTE = /^\/vm\/[a-z0-9][a-z0-9._-]{0,62}\/$/

export const CONSOLE_VIDEO_THRESHOLDS = Object.freeze({
  nonblackFraction: 0.20,
  meanLuma: 12,
  stdDev: 8,
  decodedFramesDelta: 3,
  durationMs: 1500,
})

export function consoleStreamTarget({hostId, routePrefix} = {}){
  const host = String(hostId || '').trim()
  const route = String(routePrefix || '')
  if(!host || !SCOPED_CONSOLE_ROUTE.test(route)) return null
  return `${route}?host_id=${encodeURIComponent(host)}`
}

export function consoleVideoMetricsPass(metrics = {}){
  const number = key => Number(metrics?.[key])
  return Number.isFinite(number('nonblackFraction')) && number('nonblackFraction') >= CONSOLE_VIDEO_THRESHOLDS.nonblackFraction && number('nonblackFraction') <= 1 &&
    Number.isFinite(number('meanLuma')) && number('meanLuma') >= CONSOLE_VIDEO_THRESHOLDS.meanLuma && number('meanLuma') <= 252 &&
    Number.isFinite(number('stdDev')) && number('stdDev') >= CONSOLE_VIDEO_THRESHOLDS.stdDev && number('stdDev') <= 127.5 &&
    Number.isFinite(number('decodedFramesDelta')) && number('decodedFramesDelta') >= CONSOLE_VIDEO_THRESHOLDS.decodedFramesDelta &&
    Number.isFinite(number('durationMs')) && number('durationMs') >= CONSOLE_VIDEO_THRESHOLDS.durationMs
}

export async function measureConsoleVideo(video, {durationMs = 5000, sampleIntervalMs = 250} = {}){
  if(!video || !video.videoWidth || !video.videoHeight) throw new Error('The console video has not produced a frame.')
  const ownerDocument = video.ownerDocument || (typeof document !== 'undefined' ? document : null)
  if(!ownerDocument?.createElement) throw new Error('Console video measurement requires a browser document.')
  const canvas = ownerDocument.createElement('canvas')
  canvas.width = Math.min(video.videoWidth, 640)
  canvas.height = Math.max(1, Math.round(canvas.width * video.videoHeight / video.videoWidth))
  const context = canvas.getContext('2d', {willReadFrequently:true})
  if(!context) throw new Error('Console video measurement is unavailable.')
  const startFrames = Number(video.getVideoPlaybackQuality?.().totalVideoFrames ?? video.webkitDecodedFrameCount ?? 0)
  const startedAt = typeof performance !== 'undefined' ? performance.now() : Date.now()
  const endAt = startedAt + Math.max(CONSOLE_VIDEO_THRESHOLDS.durationMs, Number(durationMs) || 0)
  let sampleCount = 0
  let nonblackPixels = 0
  let totalPixels = 0
  let lumaTotal = 0
  let lumaSquaredTotal = 0
  while((typeof performance !== 'undefined' ? performance.now() : Date.now()) < endAt){
    context.drawImage(video, 0, 0, canvas.width, canvas.height)
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data
    for(let index = 0; index < pixels.length; index += 4){
      const r = pixels[index]
      const g = pixels[index + 1]
      const b = pixels[index + 2]
      const luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
      if(Math.max(r, g, b) > 16) nonblackPixels += 1
      lumaTotal += luma
      lumaSquaredTotal += luma * luma
      totalPixels += 1
    }
    sampleCount += 1
    await new Promise(resolve => setTimeout(resolve, Math.max(50, Number(sampleIntervalMs) || 250)))
  }
  const finishedAt = typeof performance !== 'undefined' ? performance.now() : Date.now()
  const pixelsPerSample = Math.max(1, totalPixels / Math.max(1, sampleCount))
  const meanLuma = lumaTotal / Math.max(1, totalPixels)
  const variance = Math.max(0, (lumaSquaredTotal / Math.max(1, totalPixels)) - (meanLuma * meanLuma))
  const endFrames = Number(video.getVideoPlaybackQuality?.().totalVideoFrames ?? video.webkitDecodedFrameCount ?? startFrames)
  return {
    nonblackFraction: nonblackPixels / Math.max(1, totalPixels),
    meanLuma,
    stdDev: Math.sqrt(variance),
    decodedFramesDelta: Math.max(0, endFrames - startFrames),
    durationMs: Math.max(0, finishedAt - startedAt),
    samples: sampleCount,
    pixelsPerSample,
  }
}

export function automatedConsoleVerifyPayload({hostId, routePrefix, guestTcpVerified, frameMetrics}){
  if(guestTcpVerified !== true) return null
  if(!consoleVideoMetricsPass(frameMetrics)) return null
  const route = String(routePrefix || '')
  if(!SCOPED_CONSOLE_ROUTE.test(route)) return null
  const host = String(hostId || '').trim()
  if(!host) return null
  // Only the dashboard's own server-verified guest transport result is sent.
  // Browser-measured video/keyboard/mouse evidence is never claimed here.
  return {host_id:host, routePrefix:route, guestTcpVerified:true, frameMetrics}
}

export async function completeAutomatedConsole({jobId, hostId, routePrefix, guestTcpVerified, frameMetrics}, post){
  const payload = automatedConsoleVerifyPayload({hostId, routePrefix, guestTcpVerified, frameMetrics})
  if(!payload) throw new Error('Guest transport and decoded video frame evidence are required before automated console completion.')
  const res = await post(`/provisioning-jobs/${encodeURIComponent(String(jobId || ''))}/console-verify`, payload)
  const body = await res.json().catch(()=>({}))
  if(!res.ok || body.ok === false) throw new Error(body.error?.message || body.error || 'Automated console completion failed.')
  return body
}
