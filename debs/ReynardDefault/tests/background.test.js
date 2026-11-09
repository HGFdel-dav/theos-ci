const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const code=fs.readFileSync(path.join(__dirname,'../layout/Library/ReynardDefault/handoff/background.js'),'utf8');
(async()=>{
 let listener,queried=0;const calls=[];
 const browser={runtime:{onInstalled:{addListener(fn){listener=fn}}},tabs:{query(){queried++;return Promise.resolve([
  {id:1,url:'https://t.me/moonup_chat'}, {id:2,url:'http://shop.example/a?b=1'},
  {id:3,url:'about:blank'},{id:4,url:'moz-extension://other/page'}, {url:'https://missing.id/'}
 ])},executeScript(id,opt){calls.push([id,opt]);return id===2?Promise.reject(new Error('restricted')):Promise.resolve([])}}};
 vm.runInNewContext(code,{browser});
 assert.equal(queried,0);assert.equal(calls.length,0);
 listener(); await new Promise(r=>setImmediate(r));
 assert.equal(queried,1);assert.deepEqual(calls.map(x=>x[0]),[1,2]);
 for(const [id,opt] of calls){assert.equal(opt.file,'/handoff.js');assert.equal(opt.runAt,'document_idle');assert.equal(opt.allFrames,false)}
 assert(!/location\s*=|location\.href\s*=|openURL|tabs\.update|tabs\.reload/.test(code));
 console.log('BACKGROUND_TESTS=10');
})().catch(e=>{console.error(e);process.exitCode=1});
