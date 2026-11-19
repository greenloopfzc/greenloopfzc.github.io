const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const repo=path.resolve(__dirname,'..');
const {chromium}=require('C:/Users/zeeea/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
// Reuse the existing native-history fixture, including actual correction rows.
const prior=fs.readFileSync(path.join(__dirname,'test-imei-activity-time.cjs'),'utf8');
const {history,setup}=new Function('require','__dirname',prior.slice(0,prior.indexOf('(async()=>'))+';return {history,setup};')(require,__dirname);
const primary='357588201538397',secondary='357588201421552',other='355149933063758';
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
 try{
  for(const width of [1400,390]){
   const context=await browser.newContext({viewport:{width,height:950}}),p=await context.newPage(),errors=[];
   p.on('pageerror',e=>errors.push(e.message));
   await context.route('https://fixture.test/**',r=>r.fulfill({contentType:'text/html',body:fs.readFileSync(repo+'/imei-search.html','utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,'').replace(/<link\b[^>]*>/gi,'')}));
   await p.goto('https://fixture.test/imei-search.html');
   await p.evaluate(setup,{history,correctionPages:{},denied:false});
   await p.evaluate(({primary,secondary})=>{
    window.__trace=[];window.__hold=false;window.__releases=[];window.__fail=false;
    delete window.GREENLOOP_RECORD_SEARCH;
    window.GREENLOOP_STOCK={ready:async()=>{}};
    const base=GREENLOOP_GET_CLIENT();window.GREENLOOP_GET_CLIENT=()=>({...base,rpc:async(n,a)=>{
     __trace.push({n,a,time:performance.now()});
     if(n==='search_greenloop_records_v1')return {data:{items:[{kind:'device',identifier:primary,imei_1:primary,model:'14 Pro'}],exact_match:false}};
     if(n==='get_imei_activity_journey_v1'){
      if(__hold)await new Promise(r=>__releases.push(r));
      if(__fail)return {error:{message:'Office access denied'}};
      const h=structuredClone(__history);h.found=a.p_imei!=='999999999999999';
      h.device.imei_1=a.p_imei===secondary?primary:a.p_imei;h.device.imei_2=secondary;return {data:h};
     }
     if(n==='get_imei_replacement_history_v1')return {data:{found:true,imei:a.p_imei,rows:[]}};
     return base.rpc(n,a);
    }});
   },{primary,secondary});
   await p.addScriptTag({content:fs.readFileSync(repo+'/config.js','utf8').split(/\r?\n/)[0]});
   for(const f of ['stock-journey-summary','imei-corrections','record-search','imei-search'])await p.addScriptTag({path:repo+'/js/'+f+'.js'});
   await p.locator('#history-app').waitFor({state:'visible'});
   const q=p.locator('#imei-query');
   // Partial text retains suggestions. Completing it cancels those reads/timers.
   await q.fill(primary.slice(0,8));await p.locator('.gl-record-search-list').waitFor({state:'visible'});
   await p.evaluate(()=>{__trace=[];__hold=true;window.__started=performance.now();});
   await q.fill(primary);await q.press('Enter');
   await p.locator('#imei-search-form').evaluate(f=>f.requestSubmit());
   assert.equal(await p.locator('.gl-record-search-list').isHidden(),true);
   let trace=await p.evaluate(()=>__trace);
   assert.equal(trace.filter(x=>x.n==='search_greenloop_records_v1').length,0);
   assert.equal(trace.filter(x=>x.n==='get_imei_activity_journey_v1').length,1);
   assert(trace[0].time-await p.evaluate(()=>__started)<250,'no autocomplete debounce before exact history');
   await p.evaluate(()=>{__hold=false;__releases.splice(0).forEach(r=>r());});
   await p.locator('#history-result').waitFor({state:'visible'});
   assert.match(await p.locator('#history-device').innerText(),new RegExp(primary));
   // Re-pasting the same IMEI is a new input generation, not a stale flight.
   await p.evaluate(()=>{__hold=true;const q=document.querySelector('#imei-query');q.dispatchEvent(new InputEvent('input',{bubbles:true}));});
   await p.waitForFunction(()=>__releases.length===1);
   await p.locator('#imei-query').dispatchEvent('input');
   await p.waitForFunction(()=>__releases.length===2);
   await p.evaluate(()=>{__hold=false;__releases.splice(0).forEach(r=>r());});
   await p.locator('#history-result').waitFor({state:'visible'});
   // A completed result is not cached: explicit fresh search reads again.
   const before=await p.evaluate(()=>__trace.filter(x=>x.n==='get_imei_activity_journey_v1').length);
   await p.locator('#imei-search-form').evaluate(f=>f.requestSubmit());
   await p.waitForFunction(n=>__trace.filter(x=>x.n==='get_imei_activity_journey_v1').length===n+1,before);
   await p.locator('#history-result').waitFor({state:'visible'});
   // A pasted IMEI2 directly resolves to the same phone, without suggestions.
   await q.fill(secondary);await p.locator('#history-result').waitFor({state:'visible'});
   assert.match(await p.locator('#history-device').innerText(),new RegExp(primary));
   // Superseded exact response and late Office rejection cannot reopen old data.
   await p.evaluate(()=>{__hold=true;});await q.fill(primary);
   await p.waitForFunction(()=>__releases.length===1);await q.fill(other);
   await p.waitForFunction(()=>__releases.length===2);
   await p.evaluate(()=>{__hold=false;__releases.splice(0).reverse().forEach(r=>r());});
   await p.locator('#history-result').waitFor({state:'visible'});
   assert.match(await p.locator('#history-device').innerText(),new RegExp(other));
   await p.evaluate(()=>{__hold=true;});await q.fill(primary);
   await p.waitForFunction(()=>__releases.length===1);
   await p.evaluate(()=>{window.dispatchEvent(new Event('greenloop:office-locked'));__hold=false;__releases.splice(0).forEach(r=>r());});
   await p.waitForTimeout(50);assert(await p.locator('#history-result').isHidden());assert(await p.locator('.gl-record-search-list').isHidden());
   await q.fill('999999999999999');await p.waitForFunction(()=>document.querySelector('#search-message').textContent.includes('no longer available'));
   assert(await p.locator('#history-result').isHidden());
   await p.evaluate(()=>{__fail=true;});await q.fill(other);
   await p.waitForFunction(()=>document.querySelector('#search-message').textContent.includes('Office access denied'));
   assert(await p.locator('#history-result').isHidden());
   // Composition and other widgets are not treated as completed scans.
   await p.evaluate(()=>{__trace=[];const q=document.querySelector('#imei-query');q.dispatchEvent(new CompositionEvent('compositionstart'));q.value='357588201538397';q.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true}));});
   await p.waitForTimeout(300);assert.equal((await p.evaluate(()=>__trace)).length,0);
   await p.evaluate(()=>{__fail=false;document.querySelector('#imei-query').dispatchEvent(new CompositionEvent('compositionend'));});
   await p.locator('#history-result').waitFor({state:'visible'});
   await p.evaluate(()=>{__trace=[];const input=document.createElement('input');input.id='ordinary-search';document.body.append(input);GREENLOOP_RECORD_SEARCH.attach(input);});
   await p.locator('#ordinary-search').fill(primary);
   await p.waitForFunction(()=>__trace.some(x=>x.n==='search_greenloop_records_v1'));
   assert.equal((await p.evaluate(()=>__trace)).filter(x=>x.n==='get_imei_activity_journey_v1').length,0);
   assert.deepEqual(errors,[]);
   const dir=path.join(require('os').tmpdir(),'greenloop-imei-auto-open-evidence');fs.mkdirSync(dir,{recursive:true});
   await p.screenshot({path:path.join(dir,width+'.png'),fullPage:true});
   console.log('PASS',width,'actual report + real search widget: immediate exact scan/paste, secondary IMEI, single running request, fresh retry, partial suggestions, stale/Office/error/not-found/composition and opt-in isolation');
   await context.close();
  }
 }finally{await browser.close();}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
