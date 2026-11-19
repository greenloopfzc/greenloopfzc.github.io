const fs=require('fs'),path=require('path'),assert=require('assert/strict'),{chromium}=require('C:/Users/zeeea/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const repo=path.resolve(__dirname,'../..'),native=require('./fixture.json');
function model(data){
 window.GREENLOOP_CONFIG={supabaseUrl:'fixture',supabaseAnonKey:'fixture'};window.supabase={};window.GREENLOOP_PAGE_ACCESS={pageKey:'reports',canEdit:true};window.GREENLOOP_ACCESS_READY=Promise.resolve();window.__write=true;window.__quantity=true;window.__changed=false;window.__failOnce=false;window.__calls=[];window.__history=null;window.__names=true;window.__deny=false;window.__data=data;
 window.GREENLOOP_CAN=(c,p)=>p==='reports'&&['view','report_receipt_correction',...(__write?['receipt_supplier_correction']:[]),...(__quantity?['receipt_quantity_correction']:[])].includes(c);
 window.GREENLOOP_CAN_VIEW_PARTNER_NAMES=true;
 const mask=d=>{const x=structuredClone(d);function walk(v){if(!v||typeof v!=='object')return;for(const k in v){if(!__names&&['supplier_name','target_name','old_name','new_name'].includes(k))v[k]=null;else walk(v[k]);}}walk(x);return x;};
 const supplierDetail=(target=null,offset=0)=>{const x=structuredClone(target?data.preview:__changed?data.saved.supplier_detail:data.context);if(__history){x.history_total=__history.length;x.history_snapshot='b'.repeat(32);x.history=__history.slice(offset,offset+50);}if(window.__badInfo)delete x.phone_count;x.offset=offset;return mask(x);};
 window.GREENLOOP_GET_CLIENT=()=>({auth:{getSession:async()=>({data:{session:{user:{id:'fixture'}}}})},rpc:async(n,a)=>{
  __calls.push({n,a});if(n==='has_role')return{data:true};if(__deny)return{error:{message:'Office access denied'}};
  if(n==='get_stock_receipt_correction_receipts_v1'){const r=__changed?data.saved.detail.receipt:data.detail.receipt;return{data:mask({suppliers:[{supplier_id:data.context.supplier_id,supplier_code:data.context.supplier_code,supplier_name:data.context.supplier_name},{supplier_id:data.preview.target_id,supplier_code:data.preview.target_code,supplier_name:data.preview.target_name}],receipts:[r],total:1})};}
  if(n==='get_stock_receipt_correction_detail_v1')return{data:mask(__changed?data.saved.detail:data.detail)};
  if(n==='get_stock_receipt_supplier_v1'){if(a.p_offset>0&&a.p_expected_history_snapshot!=='b'.repeat(32))return{error:{message:'Supplier correction history changed. Reload the receipt.'}};return{data:supplierDetail(a.p_supplier_id,a.p_offset)};}
  if(n==='correct_stock_receipt_supplier_v1'){
   __changed=true;const x=structuredClone(data.saved);x.request_id=a.p_request_id;x.supplier_detail.history[0].reason=a.p_reason;
   if(__failOnce){__failOnce=false;return{error:{message:'Connection interrupted after save'}};}return{data:mask(x)};
  }
  if(n==='correct_stock_receipt_quantity_v1')return{error:{message:'TEST quantity writer called'}};
  throw Error('Unexpected RPC '+n);
 }});
}
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});try{
for(const width of [1450,390])for(const mode of ['light','dark']){
 const c=await browser.newContext({viewport:{width,height:1000},timezoneId:'America/New_York'}),p=await c.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(12000);
 await c.route('**/*',route=>{const u=new URL(route.request().url());if(u.hostname!=='fixture.test')return route.abort();const f=path.join(repo,decodeURIComponent(u.pathname));if(!fs.existsSync(f))return route.fulfill({status:404,body:''});let body=fs.readFileSync(f);if(f.endsWith('.html'))body=Buffer.from(body.toString().replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,''));return route.fulfill({body,contentType:f.endsWith('.js')?'text/javascript':f.endsWith('.css')?'text/css':f.endsWith('.html')?'text/html':'application/octet-stream'});});
 await p.goto('https://fixture.test/reports.html?report=stock_receipt_correction');await p.evaluate(model,native);await p.evaluate(m=>document.documentElement.dataset.mode=m,mode);
 for(const f of ['permission-catalog','rpc-capabilities','stock-receipt-correction','reports'])await p.addScriptTag({url:'/js/'+f+'.js'});
 await p.locator('#src-receipt option').nth(1).waitFor({state:'attached'});await p.locator('#src-receipt').selectOption(native.context.batch_id);await p.locator('#src-supplier-form').waitFor();
 assert.equal(await p.locator('.report-tab:visible').count(),1);assert.match(await p.locator('#src-current-supplier').innerText(),/SUP-RSS-OLD-\(10\)/);assert.equal(await p.locator('#src-supplier-confirm').isVisible(),false);
 assert.equal(await p.evaluate(()=>__calls.filter(c=>c.n==='correct_stock_receipt_supplier_v1').length),0);
 await p.locator('#src-new-supplier').selectOption(native.preview.target_id);await p.locator('#src-supplier-reason').fill('Correct supplier for this delivery.');await p.locator('#src-supplier-review').click();await p.locator('#src-supplier-confirm').waitFor();
 assert.match(await p.locator('#src-supplier-preview').innerText(),/SUP-RSS-OLD-\(10\)[\s\S]*SUP-RSS-NEW-\(10\)/);assert.match(await p.locator('#src-supplier-preview').innerText(),/Linked phones\s+5/);
 assert.equal(await p.evaluate(()=>__calls.filter(c=>c.n==='correct_stock_receipt_supplier_v1').length),0,'Preview cannot write');
 await p.locator('#src-supplier-reason').fill('Supplier was selected incorrectly.');assert.equal(await p.locator('#src-supplier-confirm').isVisible(),false);await p.locator('#src-supplier-review').click();await p.locator('#src-supplier-confirm').waitFor();
 await p.evaluate(()=>__failOnce=true);await p.locator('#src-supplier-confirm').click();await p.waitForFunction(()=>document.querySelector('#src-message').textContent.includes('Connection interrupted'));
 assert.equal(await p.locator('#src-supplier-reason').inputValue(),'Supplier was selected incorrectly.');assert.equal(await p.locator('#src-new-supplier').inputValue(),native.preview.target_id);await p.locator('#src-supplier-confirm').click();
 await p.waitForFunction(()=>document.querySelector('#src-message').textContent.startsWith('Stock supplier corrected.'));
 const writes=await p.evaluate(()=>__calls.filter(c=>c.n==='correct_stock_receipt_supplier_v1'));assert.equal(writes.length,2);assert.equal(writes[0].a.p_request_id,writes[1].a.p_request_id);assert.equal(writes[0].a.p_snapshot,native.preview.snapshot);
 assert.match(await p.locator('#src-reference').innerText(),/SUP-RSS-NEW-\(10\)/);assert.equal(await p.locator('#src-quantity').inputValue(),'10');assert.equal(await p.locator('#src-supplier-history tr').count(),1);assert.equal(await p.locator('#src-supplier').inputValue(),native.preview.target_id);
 assert.match(await p.locator('#src-supplier-history').innerText(),/SUP-RSS-OLD-\(10\)[\s\S]*SUP-RSS-NEW-\(10\)/);assert.match(await p.locator('#src-supplier-history').innerText(),/\d{2}:\d{2}:\d{2}/);
 // Snapshot-checked history paging never becomes a write or a fake partial list.
 await p.evaluate(()=>{__history=Array.from({length:51},(_,i)=>({...__data.saved.supplier_detail.history[0],request_id:'fixture-'+i}));});await p.locator('#src-refresh').click();await p.waitForFunction(()=>document.querySelectorAll('#src-supplier-history tr').length===50);await p.locator('#src-supplier-next').click();await p.waitForFunction(()=>document.querySelectorAll('#src-supplier-history tr').length===1);assert.match(await p.locator('#src-supplier-range').innerText(),/51–51 of 51/);
 const dir=path.join(require('os').tmpdir(),'greenloop-receipt-supplier-evidence');fs.mkdirSync(dir,{recursive:true});await p.locator('.src-report').screenshot({path:path.join(dir,width+'-'+mode+'.png')});assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2));
 // A quantity-only grant can still use its own form, while supplier writes hide.
 await p.evaluate(()=>{__write=false;__names=false;GREENLOOP_CAN_VIEW_PARTNER_NAMES=false;GREENLOOP_STOCK_RECEIPT_CORRECTION.mount(document.querySelector('#report-content'));});await p.locator('#src-receipt option').nth(1).waitFor({state:'attached'});await p.locator('#src-receipt').selectOption(native.context.batch_id);await p.locator('#src-supplier-panel').waitFor();assert.equal(await p.locator('#src-supplier-form').isVisible(),false);assert.equal(await p.locator('#src-form').isVisible(),true);assert(!/PRIVATE SUPPLIER/.test(await p.locator('.src-report').innerText()));
 await p.evaluate(()=>{__write=true;__badInfo=true;GREENLOOP_STOCK_RECEIPT_CORRECTION.mount(document.querySelector('#report-content'));});await p.locator('#src-receipt option').nth(1).waitFor({state:'attached'});await p.locator('#src-receipt').selectOption(native.context.batch_id);await p.waitForFunction(()=>document.querySelector('#src-supplier-status').textContent.includes('could not be verified'));assert.equal(await p.locator('#src-supplier-form').isVisible(),false);assert.equal(await p.locator('#src-form').isVisible(),true);
 await p.evaluate(()=>window.dispatchEvent(new Event('greenloop:permissions-changed')));assert.equal(await p.locator('.src-report').count(),0);assert.deepEqual(errors,[]);await c.close();console.log('PASS actual Reports supplier review/save:',width,mode,'manual confirm, uncertain retry ID, filter/labels, quantity retained,51-history snapshot paging, independent grants, privacy, malformed reads, access clearing and contained layout.');
}
}finally{await browser.close()}})().catch(e=>{console.error(e.stack);process.exitCode=1});
