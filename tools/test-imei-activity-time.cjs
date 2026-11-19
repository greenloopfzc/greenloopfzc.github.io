const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const repo=path.resolve(__dirname,'..');
require(repo+'/js/stock-journey-summary.js');const api=global.GREENLOOP_STOCK_JOURNEY;
const field=(label,value)=>({label,value});
const row=(id,stage,title,time,details=[],extra={})=>({id,stage,title,occurred_at:time,actor:'Operator',job_number:'JOB-1',details,parts:[],...extra});
assert.match(api.moment('2026-11-18T20:00:03.123456Z'),/19 Nov 2026, 12:00:03 am · UAE/i);
assert.match(api.moment('2026-11-19T18:30:07+04:00'),/19 Nov 2026, 06:30:07 pm · UAE/i);
assert.match(api.moment('2026-11-19'),/19 Nov 2026 · Time: Not recorded/);
for(const t of [null,'','invalid','2026-11-19T14:00:00'])assert.equal(api.moment(t),'Not recorded');
const tied='2026-11-19T06:42:18Z';
const initial=row('initial-qc:1','initial_qc','Initial QC inspection',tied);
const issuance=row('event:issuance','qc_issuance','B-DEPT passed to Issuance',tied);
const frame=row('frame:1','frame','B-DEPT passed',tied,[],{status:'pass'});
const move=row('movement:1','movement','Location changed',tied,[field('From','Frame'),field('To','Initial QC'),field('Reason','B-DEPT passed to Lab & Glass Issuance')]);
const route=row('event:route','workflow','B-DEPT passed to Issuance',tied);
for(const rows of [[issuance,move,frame,route],[route,frame,move,issuance]]){
 const sorted=api.activity(rows),groups=api.group(rows);
 assert(sorted.findIndex(r=>r.id===frame.id)<sorted.findIndex(r=>r.id===move.id));
 assert(sorted.findIndex(r=>r.id===move.id)<sorted.findIndex(r=>r.id===issuance.id));
 assert.deepEqual(groups.map(g=>g.key),['frame','qc_issuance']);
 assert(sorted.every(r=>r.same_time));assert.deepEqual(api.activity(sorted),sorted);
}
const micro=[row('event:b','ready_stock','B','2026-11-19T06:42:18.123999Z'),row('event:a','ready_stock','A','2026-11-19T06:42:18.123001Z')];
assert.deepEqual(api.activity(micro).map(r=>r.id),['event:a','event:b']);assert(api.activity(micro).every(r=>!r.same_time));
const unrelated=[row('event:z','ready_stock','Z',tied,[],{job_number:'JOB-Z'}),row('event:a','initial_qc','A',tied,[],{job_number:'JOB-A'})];
assert.deepEqual(api.activity(unrelated).map(r=>r.id),['event:z','event:a']);
const direct=row('event:direct','workflow','Initial QC sent phone directly to B-DEPT',tied);
const auto=row('final-qc:auto','final_qc','Final QC passed',tied,[field('Notes','Initial QC direct route to Frame')],{status:'pass'});
const directRows=api.activity([auto,direct,initial]);assert(directRows.find(r=>r.id===auto.id).automatic_direct_bdept);
assert(!api.group(directRows).some(g=>g.key==='final_qc'));
const original=JSON.stringify([auto,direct,initial]);api.activity([auto,direct,initial]);assert.equal(JSON.stringify([auto,direct,initial]),original);
assert.equal(api.actorLabel(row('timer-start:1','technician','Timer',tied)),'Technician');
assert.equal(api.actorLabel(row('assignment:1','assignment','Assigned',tied)),'Assigned technician');
const chaman=['send','shop_receive','return_send','company_receive'].map((status,i)=>row('chaman-event:'+i,'movement','Chaman '+status,`2026-11-19T${String(7+i).padStart(2,'0')}:00:00Z`,[],{status,job_number:null}));
assert.deepEqual(api.group(chaman).map(g=>g.key),['chaman_send','chaman_shop_receive','chaman_return_send','chaman_company_receive']);
console.log('PASS UAE rollover / seconds / missing time; microsecond chronology; same-time routes; independent jobs; direct B-DEPT system evidence; immutability; Chaman steps; actor roles.');

const {chromium}=require('C:/Users/zeeea/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const ids={imei:'355149933063758'};
const correction=(i)=>({id:'stage:'+i,occurred_at:'2026-11-19T06:42:18Z',actor:'Correction User',source:'IMEI Data Correction',reason:'Grade checked',changes:[{key:'final_grade',field:'Final Grade',old:'A',new:'BA'}]});
const corrections=offset=>({version:'20261114-imei-qc-corrections-1',sources_version:'20261114-imei-correction-sources-1',grade_audit_version:'20261114-imei-grade-audit-1',imei:ids.imei,offset,limit:50,total:51,snapshot:'a'.repeat(32),rows:Array.from({length:offset?1:50},(_,i)=>correction(offset+i))});
const history={found:true,device:{imei_1:ids.imei,brand:'Apple',model:'15 Pro Max',storage_gb:256,color:'Black',supplier_code:'SUP-02',supplier_name:'PRIVATE',current_stage:'Lab & Glass Issuance',initial_battery_health:80,final_battery_health:100,supplier_grade:'B',gl_grade:'A',final_grade:'BA'},summary:{recorded_total_cost:0},report_corrections:corrections(0),rows:[
 row('receipt:1','stock_received','Stock received','2026-11-18T20:00:03Z',[field('Supplier name','PRIVATE')],{job_number:null}),
 initial,frame,issuance,move,route,
 row('assignment:1','assignment','Assigned technician','2026-11-19T08:00:00Z',[field('Department','laboratory')],{actor:'Tech Name'}),
 row('laboratory-start:1','laboratory','Laboratory work started','2026-11-19T08:00:00Z',[],{actor:'Tech Name'}),
 row('manual-part:1','laboratory','Part recorded','2026-11-19T08:01:00Z',[],{parts:[{name:'Battery',quantity:1,unit_cost:null}]}),
 row('event:labcomplete','laboratory','Laboratory completed','2026-11-19T09:00:00Z'),
 row('final-qc:fail','final_qc','Final QC failed','2026-11-19T10:00:00Z',[field('Failure reason','Board issue')],{status:'fail'}),
 row('movement:rework','movement','Location changed','2026-11-19T10:00:00Z',[field('From','Final QC'),field('To','Laboratory'),field('Reason','Returned for rework')]),
 row('event:labagain','laboratory','Laboratory completed','2026-11-19T11:00:00Z'),
 row('final-qc:pass','final_qc','Final QC passed','2026-11-19T12:00:00Z',[],{status:'pass'}),
 ...chaman,row('other:undated','workflow','Historical action',null,[],{actor:null}),
 row('report-stage:1','correction','Reports correction','2026-11-19T14:00:01Z',[field('Reason','Grade checked')],{report_correction:true})
]};
function setup({history,correctionPages,denied}){
 window.__calls=[];window.__mode='ok';window.__history=history;
 window.GREENLOOP_CONFIG={supabaseUrl:'https://fixture.test',supabaseAnonKey:'fixture'};window.supabase={};window.GREENLOOP_ACCESS_READY=Promise.resolve();
 window.GREENLOOP_PAGE_ACCESS=denied?null:{pageKey:'imei_search',accessLevel:'view'};
 window.GREENLOOP_CAN=()=>!denied;window.GREENLOOP_CAN_SEARCH=true;window.GREENLOOP_CAN_VIEW_PARTNER_NAMES=false;
 window.GREENLOOP_RECEIPTS={load:async()=>{},label:()=> 'SUP-02-(1400)'};
 window.GREENLOOP_SCAN_READY={focus:e=>e.focus()};
 window.GREENLOOP_BULK_IMEI={register:options=>window.__bulk=options.load,list:()=>null};
 window.GREENLOOP_RECORD_SEARCH={attach:(input,options)=>{window.__select=options.onSelect;return{close(){},search(){}}}};
 window.GREENLOOP_GET_CLIENT=()=>({auth:{getSession:async()=>({data:{session:{user:{id:'fixture'}}}})},rpc:async(n,a)=>{
  __calls.push({n,a});if(__mode==='error')return{error:{message:'Office access denied'}};
  if(n==='get_imei_activity_journey_v1'){if(__mode==='slow')await new Promise(r=>setTimeout(r,200));return{data:structuredClone(__history)}};
  if(n==='get_imei_replacement_history_v1')return{data:{found:true,imei:history.device.imei_1,rows:[]}};
  if(n==='get_imei_report_corrections_v1')return{data:correctionPages[a.p_offset]};
  if(n==='get_imei_bulk_history_list_v1')return{data:{rows:[{found:true,searched_imei:history.device.imei_1,...history.device}],total:1}};
  throw Error('Unexpected RPC '+n);
 }});
}
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
try{for(const width of [1400,390])for(const mode of ['light','dark']){
 const context=await browser.newContext({viewport:{width,height:950},timezoneId:'America/New_York'}),p=await context.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));
 await context.route('https://fixture.test/**',route=>route.fulfill({contentType:'text/html',body:fs.readFileSync(repo+'/imei-search.html','utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,'').replace(/<link\b[^>]*>/gi,'')}));
 await p.goto('https://fixture.test/imei-search.html');
 await p.addStyleTag({content:['styles.css','imei-search.css','appearance.css'].map(n=>fs.readFileSync(repo+'/css/'+n,'utf8')).join('\n')});
 await p.evaluate(m=>document.documentElement.dataset.mode=m,mode);
 await p.evaluate(setup,{history,correctionPages:{50:corrections(50)},denied:false});
 await p.addScriptTag({content:fs.readFileSync(repo+'/config.js','utf8').split(/\r?\n/)[0]});
 for(const f of ['stock-journey-summary','imei-corrections','imei-search'])await p.addScriptTag({path:repo+'/js/'+f+'.js'});
 await p.waitForFunction(()=>!document.querySelector('#history-app').hidden);
 await p.locator('#imei-query').fill(ids.imei);await p.locator('#imei-search-form').evaluate(f=>f.requestSubmit());await p.locator('#history-result').waitFor({state:'visible'});
 const activity=p.locator('.history-full-activity');await activity.evaluate(e=>e.open=true);
 assert.equal(await p.locator('.history-activity-record').count(),history.rows.length);
 const receipt=p.locator('[data-record-id="receipt:1"]');assert.match(await receipt.innerText(),/19 Nov 2026, 12:00:03 am · UAE/i);
 assert.match(await p.locator('[data-record-id="assignment:1"]').innerText(),/Assigned technician: Tech Name/);
 assert.match(await p.locator('[data-record-id="laboratory-start:1"]').innerText(),/Technician: Tech Name/);
 assert.match(await p.locator('[data-record-id="other:undated"]').innerText(),/Not recorded · By: Not recorded/);
 assert.match(await p.locator('.stock-journey-compact').innerText(),/Visit 2/);
 assert.match(await p.locator('[data-record-id="movement:rework"]').innerText(),/From: Final QC[\s\S]*To: Lab & Glass/);
 assert(!/PRIVATE/.test(await p.locator('#history-result').innerText()));
 assert.match(await p.locator('.history-corrections-table').innerText(),/Date & Time · UAE[\s\S]*10:42:18 am · UAE/i);
 assert.equal(await p.locator('[data-correction-record]').count(),50);
 await p.locator('[data-corrections-offset="50"]').click();await p.waitForFunction(()=>document.querySelectorAll('[data-correction-record]').length===1);
 assert.match(await p.locator('.history-corrections-pager').innerText(),/51–51 of 51/);
 assert.equal(await p.evaluate(()=>__calls.filter(c=>c.n==='get_imei_report_corrections_v1')[0].a.p_limit),50);
 assert.equal(await p.evaluate(()=>document.querySelector('.history-corrections-table td').textContent),'51');
 assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2));assert.deepEqual(errors,[]);
 const dir=path.join(require('os').tmpdir(),'greenloop-imei-activity-time-evidence');fs.mkdirSync(dir,{recursive:true});await p.screenshot({path:path.join(dir,width+'-'+mode+'.png'),fullPage:true});
 // Selected phone popup uses the same actual render path, times and audit.
 await p.evaluate(()=>__bulk([__history.device.imei_1]));await p.getByRole('button',{name:'Open history',exact:true}).click();await p.locator('#imei-history-dialog[open]').waitFor();assert.match(await p.locator('#imei-history-dialog').innerText(),/10:42:18 am · UAE/i);
 await p.locator('#imei-history-dialog .history-dialog-heading button').click();
 await p.evaluate(()=>{__mode='slow';document.querySelector('#imei-query').value=__history.device.imei_1;document.querySelector('#imei-search-form').requestSubmit();window.dispatchEvent(new Event('greenloop:office-locked'));});
 await p.waitForTimeout(260);assert(await p.locator('#history-result').isHidden());assert.equal(await p.locator('#history-report-corrections').count(),0);
 assert.deepEqual(errors,[]);await context.close();console.log('PASS Chrome actual IMEI render',width,mode,'UAE seconds, chronology, rework, all records, correction paging, privacy, popup, stale Office result and contained layout.');
}
}finally{await browser.close()}})().catch(e=>{console.error(e.stack);process.exitCode=1});
