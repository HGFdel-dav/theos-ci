const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const root=path.resolve(__dirname,'..');
const code=fs.readFileSync(path.join(root,'layout/Library/ReynardDefault/handoff/handoff.js'),'utf8');
const cases=[];let passed=0;const now=1794217455000;
function test(name,fn){fn();passed++;console.log('PASS '+name);}
function env(href,options={}) {
 const nav=[],handlers={},doc={baseURI:options.base||'https://t.me/moonup_chat',title:'Original title',hidden:!!options.hidden};
 doc.querySelector=()=>{throw Error('Page metadata must never replace clicked URL')};
 doc.addEventListener=(type,fn)=>handlers[type]=fn;
 const anchor={nodeName:options.tag||'A',getAttribute:k=>k==='href'?href:null,hasAttribute:k=>k==='download'&&!!options.download};
 const child={nodeName:'SPAN',nodeType:1,closest:()=>anchor};
 let cancelled=false,stopped=false;const loc={};
 Object.defineProperty(loc,'href',{get(){return doc.baseURI},set(v){if(options.assignmentThrows)throw Error('blocked');nav.push(v)}});
 const win={};const ctx={window:win,document:doc,location:loc,URL,Set,Uint8Array,Array,encodeURIComponent,Date:{now:()=>now},crypto:{getRandomValues(b){for(let i=0;i<b.length;i++)b[i]=i;return b}}};
 vm.runInNewContext(code,ctx);
 const event={isTrusted:true,defaultPrevented:false,button:0,target:child,composedPath:()=>[child,anchor,doc],preventDefault(){cancelled=true;this.defaultPrevented=true},stopImmediatePropagation(){stopped=true},...options.event};
 return {nav,doc,ctx,fire(){handlers.click(event)},state:()=>({cancelled,stopped})};
}
function decoded(sent){return Object.fromEntries(new URLSearchParams(new URL(sent).hash.slice(1)))}
for(const url of [
 'tg:resolve?domain=moonup_chat',
 'tg://resolve?domain=channel&post=123&thread=45&start=ab%2Bcd',
 'tg://join?invite=AB-CD_ef+g',
 'mailto:a@example.com?subject=A%26B&body=x%23y',
 'tel:+86123456789',
 'sms:+123?body=hello%20world',
 'myshop://product/001?sku=a%2Fb&callback=https%3A%2F%2Fx.example%2F%3Fa%3D1%26b%3D2#reviews',
 'customapp:opaque?value=%252F&v=plus+literal',
 'someapp://path?text=%E4%BD%A0%E5%A5%BD&name=a%26b%3Dc'
]) test('trusted custom '+url,()=>{
 const e=env(url);e.fire();assert.equal(e.nav.length,1);assert(e.state().cancelled&&e.state().stopped);
 const d=decoded(e.nav[0]);assert.equal(d.v,'2');assert.equal(d.a,url);assert.equal(d.h,'');assert.equal(d.ts,String(now));assert.equal(d.id.length,32);
 assert.equal((e.nav[0].match(/#/g)||[]).length,1);cases.push({uri:e.nav[0],expectedApp:url});
});
test('load/refresh creates no navigation and preserves title',()=>{const e=env('tg://resolve?domain=x');assert.equal(e.nav.length,0);assert.equal(e.doc.title,'Original title')});
for(const event of [{isTrusted:false},{defaultPrevented:true},{button:1},{button:2},{ctrlKey:true},{altKey:true},{shiftKey:true},{metaKey:true}])test('no custom interception '+JSON.stringify(event),()=>{const e=env('tg://resolve?domain=x',{event});e.fire();assert.equal(e.nav.length,0);assert(!e.state().cancelled)});
for(const options of [{hidden:true},{download:true},{assignmentThrows:true}])test('no swallowed click '+JSON.stringify(options),()=>{const e=env('tg://resolve?domain=x',options);e.fire();assert.equal(e.nav.length,0);assert(!e.state().cancelled)});
for(const href of ['https://t.me/moonup_chat','https://moonup.dev/','http://news.example/item?a=1&b=2#part','/relative/path?q=x','#chapter','javascript:void(0)','about:blank','data:text/html,test','file:///tmp/example','intent://example/#Intent;scheme=x;end','reynard://open?url=x'])test('leave browser link untouched '+href,()=>{const e=env(href);e.fire();assert.equal(e.nav.length,0);assert(!e.state().cancelled)});
for(const href of [null,'','tg:\nresolve?domain=x','tg:resolve?x=hello world','abc\u0000def:foo','x:'.padEnd(16386,'x')])test('invalid href untouched',()=>{const e=env(href);e.fire();assert.equal(e.nav.length,0)});
test('shadow DOM link selected via composedPath',()=>{const e=env('demo://item');e.fire();assert.equal(decoded(e.nav[0]).a,'demo://item')});
test('area element supported',()=>{const e=env('demo://item',{tag:'AREA'});e.fire();assert.equal(decoded(e.nav[0]).a,'demo://item')});
test('second script evaluation does not install duplicate listener',()=>{const e=env('demo://item');vm.runInNewContext(code,e.ctx);e.fire();assert.equal(e.nav.length,1)});
// Feed emitted fragments to the production C parser (run_checks.py).
fs.writeFileSync(process.env.RD_TEST_CASES||'/tmp/rd-click-cases.json',JSON.stringify(cases,null,2));
console.log('CLICK_SCRIPT_TESTS='+passed);
