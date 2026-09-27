import test from 'node:test'
import assert from 'node:assert/strict'
import { automatedConsoleVerifyPayload, completeAutomatedConsole, consoleStreamTarget, consoleVideoMetricsPass, measureConsoleVideo } from '../src/lib/consoleVerification.js'

const goodMetrics = {nonblackFraction:.75,meanLuma:40,stdDev:41,decodedFramesDelta:10,durationMs:2000}

test('automated completion carries transport and decoded-frame evidence',()=>{
  const payload = automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics})
  assert.deepEqual(payload,{host_id:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics})
  for(const key of ['evidenceSource','videoFrameVerified','keyboardInputVerified','mouseInputVerified']){
    assert.equal(key in payload,false,`automated completion must never claim ${key}`)
  }
})

test('automated completion refuses to fabricate evidence or accept an untrusted route',()=>{
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/'}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:false,frameMetrics:goodMetrics}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:'true',frameMetrics:goodMetrics}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'https://attacker.example/vm/x/',guestTcpVerified:true,frameMetrics:goodMetrics}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics}),null)
  assert.equal(automatedConsoleVerifyPayload({hostId:'epic-pc',routePrefix:'',guestTcpVerified:true,frameMetrics:goodMetrics}),null)
})

test('automated completion posts transport and decoded-frame evidence to console-verify',async()=>{
  const seen = []
  const post = async (path, payload)=>{ seen.push([path,payload]); return {ok:true,json:async()=>({ok:true,job:{id:'job-1',state:'ready'}})} }
  const body = await completeAutomatedConsole({jobId:'job-1',hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics},post)
  assert.deepEqual(seen,[['/provisioning-jobs/job-1/console-verify',{host_id:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics}]])
  assert.equal(body.ok,true)
  assert.equal(body.job.state,'ready')
})

test('automated completion fails closed without transport evidence',async()=>{
  await assert.rejects(
    completeAutomatedConsole({jobId:'job-1',hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:false,frameMetrics:goodMetrics},async()=>({ok:true,json:async()=>({})})),
    /Guest transport and decoded video frame evidence/
  )
  await assert.rejects(completeAutomatedConsole({jobId:'job-1',hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/',guestTcpVerified:true,frameMetrics:goodMetrics},async()=>({ok:false,status:422,json:async()=>({ok:false,error:{code:'console_verification_failed',message:'The kvm2 console evidence is incomplete.'}})})),/incomplete/)
})

test('automated video measurement remains available without human input attestation',async()=>{
  assert.equal(typeof measureConsoleVideo,'function')
  assert.equal(consoleStreamTarget({hostId:'epic-pc',routePrefix:'/vm/alpha--epic-pc/'}),'/vm/alpha--epic-pc/?host_id=epic-pc')
  assert.equal(consoleStreamTarget({hostId:'epic-pc',routePrefix:'/vm/alpha/'}),'/vm/alpha/?host_id=epic-pc')
  assert.equal(consoleStreamTarget({hostId:'epic-pc',routePrefix:'https://attacker.example/vm/x/'}),null)
  assert.equal(consoleVideoMetricsPass({nonblackFraction:.75,meanLuma:40,stdDev:41,decodedFramesDelta:10,durationMs:2000}),true)
  assert.equal(consoleVideoMetricsPass({nonblackFraction:.3,meanLuma:40,stdDev:41,decodedFramesDelta:10,durationMs:2000}),true)
  assert.equal(consoleVideoMetricsPass({nonblackFraction:0,meanLuma:40,stdDev:41,decodedFramesDelta:10,durationMs:2000}),false)
})

test('no human console-verification gate remains in the UI contract',async()=>{
  const fs = await import('node:fs')
  const vmManagerPath = new URL('../src/pages/VMManager.jsx',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')
  const vmManagerSource = fs.readFileSync(vmManagerPath,'utf8')
  assert.match(vmManagerSource,/completeAutomatedConsole/)
  assert.match(vmManagerSource,/<iframe /)
  for(const forbidden of ['keyboardInputVerified','mouseInputVerified','My typing reached the guest','My clicks reached the guest']){
    assert.equal(vmManagerSource.includes(forbidden),false,`${forbidden} must not gate provisioning`)
  }
  const componentPath = new URL('../src/components/ConsoleVerification.jsx',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')
  if(fs.existsSync(componentPath)){
    const componentSource = fs.readFileSync(componentPath,'utf8')
    for(const forbidden of ['keyboardInputVerified','mouseInputVerified','My typing reached the guest','My clicks reached the guest']){
      assert.equal(componentSource.includes(forbidden),false,`${forbidden} must not gate provisioning`)
    }
  }
})
