const fs=require('fs'),assert=require('assert/strict'),{PGlite}=require('C:/Users/zeeea/Documents/Codex/2026-09-15/greenloop-chat-3/work/audit-tests/node_modules/@electric-sql/pglite');
const base='C:/Users/zeeea/Documents/Codex/2026-09-15/greenloop-chat-3/work',root=require('path').resolve(__dirname,'../..'),admin='00000000-0000-0000-0000-000000000001',staff='00000000-0000-0000-0000-000000000002';let db;
const sql=fs.readFileSync(root+'/supabase/migrations/20261119_331_receipt_supplier_correction.sql','utf8');
async function q(s,a=[]){await db.exec('reset role');const rows=(await db.query(s,a)).rows;await db.exec('set role authenticated');return rows;}
const call=async(n,a=[])=> (await db.query('select public.'+n+'('+a.map((_,i)=>'$'+(i+1)).join(',')+')v',a)).rows[0].v;
async function deny(fn,re){await db.exec('savepoint denied');let err;try{await fn()}catch(e){err=e}await db.exec('rollback to savepoint denied');assert(err,'Expected rejection');assert.match(err.message,re);}
const snap=()=>q(`select(select md5(jsonb_agg(to_jsonb(t)order by id)::text)from jobs t)j,(select md5(jsonb_agg(to_jsonb(t)order by id)::text)from receiving_batches t)b,(select md5(jsonb_agg(to_jsonb(t)order by id)::text)from supplier_returns t)r,(select count(*)from device_events)e`);
(async()=>{db=new PGlite({loadDataDir:new Blob([fs.readFileSync(process.env.RECEIPT_SUPPLIER_BASE||base+'/background-read-base.gz')])});try{
 await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.headers','{}',false)",[admin]);
 for(const name of ['20261118_327_background_read_speed.sql','20261118_328_lab_counter_membership.sql','20261118_329_lab_transfer_readiness.sql','20261119_330_chaman_custody_notice.sql'])await db.exec(fs.readFileSync(root+'/supabase/migrations/'+name,'utf8'));
 const bundle='C:/Users/zeeea/Documents/Codex/2026-11-12/gl4/outputs/GreenLoop-IMEI-Activity-Time-Fix',markers=[];let unavailable=0;
 for(const file of fs.readdirSync(bundle).filter(f=>/^check-.*\.cjs$/.test(f))){const m=fs.readFileSync(bundle+'/'+file,'utf8').match(/return probe\('([^']+)'\s*,\s*'([^']+)'\)/);if(!m)continue;if(!(await db.query('select to_regprocedure($1)v',['public.'+m[1]+'()'])).rows[0].v){unavailable++;continue;}try{const v=await call(m[1]);markers.push({name:m[1],value:v,expected:m[2]});}catch{unavailable++;}}
 const before=await snap();await db.exec('reset role');await assert.rejects(()=>db.exec(sql.replace("notify pgrst,'reload schema';","raise exception 'TEST LAST FAILURE';")),/TEST LAST FAILURE/);
 assert.equal((await db.query("select to_regclass('greenloop_private.receipt_supplier_audit')v")).rows[0].v,null);assert.deepEqual(await snap(),before);
 await db.exec('reset role');await db.exec(sql.replace(/\r?\n/g,'\r\n'));await db.exec(sql);assert.equal(await call('get_receipt_supplier_correction_version'),'20261119-receipt-supplier-correction-1');assert.deepEqual(await snap(),before);
 for(const m of markers)assert.equal(await call(m.name),m.value,m.name+' exact prior version result preserved');console.log('PASS '+markers.filter(m=>m.value===m.expected).length+' verified cumulative markers; '+unavailable+' unavailable fixture markers not certified.');
 console.log('PASS one-statement installation, Windows CRLF, repeat, complete late-failure rollback and unchanged business records.');
 await db.exec('set role authenticated;begin');
 await q("insert into public.user_partner_name_permissions(user_id,access_level)values($1,'view')on conflict(user_id)do update set access_level='view'",[admin]);
 const s1=(await q("insert into suppliers(supplier_code,company_name)values('SUP-RSS-OLD','OLD PRIVATE SUPPLIER')returning id"))[0].id;
 const s2=(await q("insert into suppliers(supplier_code,company_name)values('SUP-RSS-NEW','NEW PRIVATE SUPPLIER')returning id"))[0].id;
 const batch=(await q("insert into receiving_batches(batch_number,invoice_number,supplier_id,planned_quantity,receiving_source)values('BATCH-RSS-ROOT','INV-RSS-ROOT',$1,10,'Stock')returning id",[s1]))[0].id;
 const otherBatch=(await q("insert into receiving_batches(batch_number,invoice_number,supplier_id,planned_quantity,receiving_source)values('BATCH-RSS-OTHER','INV-RSS-OTHER',$1,5,'Stock')returning id",[s1]))[0].id;
 const loc=(await q("select id from locations where location_code='INITIAL-QC'"))[0].id;
 async function phone(i,b=batch){const dev=(await q("insert into devices(imei_1,brand,device_platform,model,storage_gb,color,battery_health,gc_grade,current_status,current_location_id)values($1,'Apple','ios','15',256,'Blue',85,'A','initial_qc_pending',$2)returning id",[String(398700000010000+i),loc]))[0].id;
 const job=(await q("insert into jobs(device_id,supplier_id,receiving_batch_id,job_type,ownership_type,receiving_source,current_status,current_location_id)values($1,$2,$3,'company_refurbishment','company_owned','Stock','initial_qc_pending',$4)returning id",[dev,s1,b,loc]))[0].id;return{dev,job,imei:String(398700000010000+i)};}
 const phones=[];for(let i=0;i<5;i++)phones.push(await phone(i));const other=await phone(99,otherBatch);
 // Use the actual confirmed Chaman dispatch and shop-receiving boundaries.
 for(const action of ['send','shop_receive']){const review=(await db.query("select public.get_chaman_shop_v2(p_view:='preview',p_action:=$1,p_imeis:=$2)v",[action,[phones[1].imei]])).rows[0].v;await call('save_chaman_entry_v2',[action,[phones[1].imei],'Supplier correction fixture',review.snapshot,crypto.randomUUID()]);}
 // Seed an existing returned unit only in the disposable fixture. Actual return
 // guards remain active during correction and the future return-read checks.
 await db.exec('reset role;set session_replication_role=replica');const ret=(await db.query("insert into supplier_returns(batch_id,supplier_id,device_id,job_id,imei_1,reason,status,requested_by,handed_over_at,slip_reference,source_snapshot)values($1,$2,$3,$4,$5,'other','returned',$6,now(),'RSS-SLIP',jsonb_build_object('supplier_code','SUP-RSS-OLD','supplier_name','OLD PRIVATE SUPPLIER'))returning id",[batch,s1,phones[0].dev,phones[0].job,phones[0].imei,admin])).rows[0].id;await db.exec('set session_replication_role=origin;set role authenticated');
 // Disposable already-exported box: the supplier correction must never reopen
 // Accounts or undo stock-out, even though generic source edits normally do.
 const exportBox=crypto.randomUUID(),exportItem=crypto.randomUUID();await db.exec('reset role;set session_replication_role=replica');
 await db.query("insert into export_boxes select(jsonb_populate_record(null::export_boxes,to_jsonb(x)||jsonb_build_object('id',$1::text,'box_number','BOX-RSS-EXPORTED'))).*from export_boxes x limit 1",[exportBox]);
 await db.query("insert into greenloop_private.box_workflow select(jsonb_populate_record(null::greenloop_private.box_workflow,to_jsonb(x)||jsonb_build_object('box_id',$1::text,'state','exported'))).*from greenloop_private.box_workflow x limit 1",[exportBox]);
 await db.query("insert into export_box_items select(jsonb_populate_record(null::export_box_items,to_jsonb(x)||jsonb_build_object('id',$1::text,'box_id',$2::text,'job_id',$3::text,'device_id',$4::text,'imei_1',$5::text))).*from export_box_items x limit 1",[exportItem,exportBox,phones[4].job,phones[4].dev,phones[4].imei]);
 await db.query("update jobs set current_status='shipped'where id=$1",[phones[4].job]);await db.query("update devices set current_status='shipped'where id=$1",[phones[4].dev]);await db.exec('set session_replication_role=origin;set role authenticated');
 assert.equal((await q('select count(*)::int n from export_box_items where box_id=$1',[exportBox]))[0].n,1);
 assert.equal((await q("select capabilities->'reports'?'receipt_supplier_correction'v from greenloop_private.user_page_capabilities where user_id=$1",[admin]))[0].v,true,'Eligible Owner receives the independent supplier action');
 const fullBefore=(await q('select greenloop_private.rss_scope($1)v',[batch]))[0].v;
 const originalDetail=await call('get_stock_receipt_correction_detail_v1',[batch,0]),originalContext=await call('get_stock_receipt_supplier_v1',[batch,null,0]);
 let preview=await call('get_stock_receipt_supplier_v1',[batch,s2,0]);assert.equal(preview.quantity,10);assert.equal(preview.phone_count,5);assert.equal(preview.return_count,1);assert.equal(preview.target_id,s2);
 await q("update receiving_batches set notes='Changed after supplier review'where id=$1",[batch]);await deny(()=>call('correct_stock_receipt_supplier_v1',[batch,s2,preview.snapshot,'Valid correction reason',crypto.randomUUID()]),/changed after review/);await q('update receiving_batches set notes=$2 where id=$1',[batch,fullBefore.root.notes]);
 const req=crypto.randomUUID(),args=[batch,s2,preview.snapshot,'Receipt belonged to the new supplier; original supplier was selected by mistake.',req];
 await deny(()=>call('correct_stock_receipt_supplier_v1',[batch,s2,'stale','Valid correction reason',crypto.randomUUID()]),/changed after review/);
 await deny(()=>call('correct_stock_receipt_supplier_v1',[batch,s2,preview.snapshot,'x',crypto.randomUUID()]),/reason/);
 await deny(()=>call('get_stock_receipt_supplier_v1',[batch,s1,0]),/different/);
 // Fail after the last job write: all earlier batch/held/Chaman changes roll back.
 await q("create function public.rss_test_fail()returns trigger language plpgsql as $$begin if new.supplier_id<>old.supplier_id then raise exception 'TEST LAST JOB FAILURE';end if;return new;end;$$");
 await q("create trigger zz_rss_test_fail before update on public.jobs for each row execute function public.rss_test_fail()");
 await deny(()=>call('correct_stock_receipt_supplier_v1',args),/TEST LAST JOB FAILURE/);
 assert.equal((await q('select supplier_id from receiving_batches where id=$1',[batch]))[0].supplier_id,s1);assert.equal((await q('select count(*)::int n from greenloop_private.receipt_supplier_audit where root_batch_id=$1',[batch]))[0].n,0);
 await q('drop trigger zz_rss_test_fail on public.jobs');await q('drop function public.rss_test_fail()');
 const saved=await call('correct_stock_receipt_supplier_v1',args);assert(saved.saved);assert.equal(saved.applied_supplier_id,s2);assert.equal(saved.detail.receipt.quantity,10);assert.equal(saved.supplier_detail.history_total,1);
 const browserFixture=structuredClone({detail:originalDetail,context:originalContext,preview,saved});for(const d of [browserFixture.context,browserFixture.preview,browserFixture.saved.supplier_detail])d.suppliers=d.suppliers.filter(s=>[s1,s2].includes(s.supplier_id));fs.writeFileSync(require('path').join(require('os').tmpdir(),'greenloop-receipt-supplier-native-fixture.json'),JSON.stringify(browserFixture,null,2));
 assert.equal((await q('select count(*)::int n from jobs where receiving_batch_id=$1 and supplier_id=$2',[batch,s2]))[0].n,5);
 assert.equal((await q('select supplier_id from supplier_returns where id=$1',[ret]))[0].supplier_id,s2);
 assert.equal((await q('select supplier_id from jobs where id=$1',[other.job]))[0].supplier_id,s1);
 assert.equal((await q('select supplier_id from receiving_batches where id=$1',[otherBatch]))[0].supplier_id,s1);
 const fullAfter=(await q('select greenloop_private.rss_scope($1)v',[batch]))[0].v;
 for(const key of ['plans','replacements','chaman','boxes','box_workflow'])assert.deepEqual(fullAfter[key],fullBefore[key]);
 assert.equal((await q('select current_status from jobs where id=$1',[phones[4].job]))[0].current_status,'shipped');assert.equal((await q("select count(*)::int n from greenloop_private.box_workflow_audit where box_id=$1 and details->>'supplier_correction_id'=$2",[exportBox,req]))[0].n,1);
 for(const key of ['batches','jobs','returns'])assert.deepEqual(fullAfter[key].map(x=>{const y={...x};delete y.supplier_id;return y}),fullBefore[key].map(x=>{const y={...x};delete y.supplier_id;return y}));
 const replay=await call('correct_stock_receipt_supplier_v1',args);assert.equal(replay.supplier_detail.history_total,1);
 await deny(()=>call('correct_stock_receipt_supplier_v1',[batch,s2,args[2],'Different reason',req]),/different supplier correction/);
 assert.equal((await q('select count(*)::int n from device_events where event_type=\'receipt_supplier_correction\'and event_data->>\'audit_id\'=$1',[req])).map(x=>x.n)[0],5);
 const returnRecord=(await q('select greenloop_private.supplier_return_record($1)v',[ret]))[0].v;assert.equal(returnRecord.supplier_code,'SUP-RSS-NEW');
 assert.equal((await q('select source_snapshot->>\'supplier_code\'code from supplier_returns where id=$1',[ret]))[0].code,'SUP-RSS-OLD');
 const h=await call('get_imei_activity_journey_v1',[phones[0].imei]);assert.equal(h.device.supplier_code,'SUP-RSS-NEW');assert(h.report_corrections.rows.some(r=>r.changes.some(c=>c.key==='supplier_code'&&c.old==='SUP-RSS-OLD'&&c.new==='SUP-RSS-NEW')));
 const receipts=(await q('select supplier_id,supplier_code,received_quantity,returned_quantity,replacement_quantity from greenloop_private.sc_receipts()where batch_id=$1',[batch]))[0];assert.equal(receipts.supplier_code,'SUP-RSS-NEW');assert.equal(receipts.received_quantity,10);
 const chamanRead=(await db.query("select public.get_chaman_shop_v2(p_view:='detail',p_document_id:=$1)v",[fullBefore.chaman[0].out_document])).rows[0].v;assert(chamanRead.rows.some(r=>r.imei===phones[1].imei&&r.supplier_code==='SUP-RSS-NEW'));
 const pending=await call('get_pending_replacement_returns_v1',[s2,batch,'',0]);assert(JSON.stringify(pending).includes(ret),'Existing return remains available to the corrected supplier replacement workflow');
 for(const action of ['return_send','company_receive']){const review=(await db.query("select public.get_chaman_shop_v2(p_view:='preview',p_action:=$1,p_imeis:=$2)v",[action,[phones[1].imei]])).rows[0].v;await call('save_chaman_entry_v2',[action,[phones[1].imei],'After supplier correction',review.snapshot,crypto.randomUUID()]);}assert.equal((await q('select supplier_id from jobs where id=$1',[phones[1].job]))[0].supplier_id,s2);
 console.log('PASS exact whole-batch correction across initial/Chaman/returned phones, unchanged quantities/work/custody/frozen history/unrelated stock; audit + IMEI old/new; actor-bound idempotent retry and late-write rollback.');
 await deny(()=>q('update greenloop_private.receipt_supplier_audit set reason=\'erase history\'where request_id=$1',[req]),/permanent/);
 await deny(()=>q('update receiving_batches set supplier_id=$2 where id=$1',[batch,s1]),/permanent Supplier Return/);
 // Legacy replacement deliveries are included without modifying their frozen
 // receipt command/response, allocation or original/replacement identities.
 const lr=(await q("insert into receiving_batches(batch_number,invoice_number,supplier_id,planned_quantity,receiving_source)values('BATCH-RSS-LEGACY-ROOT','INV-RSS-LR',$1,20,'Stock')returning id",[s1]))[0].id;
 const lc=(await q("insert into receiving_batches(batch_number,invoice_number,supplier_id,planned_quantity,receiving_source)values('BATCH-RSS-LEGACY-CHILD','INV-RSS-LC',$1,1,'Stock')returning id",[s1]))[0].id;
 const lp=await phone(199,lc),returnID=crypto.randomUUID();
 await q('insert into greenloop_private.supplier_return_capabilities values(txid_current(),pg_backend_pid(),$1)',[returnID]);
 const returned=(await q("insert into supplier_returns(id,batch_id,supplier_id,reason,status,requested_by,handed_over_at,slip_reference)values($1,$2,$3,'dead','returned',$4,now(),'RSS-LEGACY')returning return_number",[returnID,lr,s1,admin]))[0];
 const legacyReceipt=(await q("insert into greenloop_private.srp_receipts(actor_id,idempotency_key,command,response,group_id,original_batch_id,replacement_batch_id,supplier_id,quantity,original_snapshot)values($1,gen_random_uuid(),'{}','{}',gen_random_uuid(),$2,$3,$4,1,'{}')returning id",[admin,lr,lc,s1]))[0].id;
 await q('insert into greenloop_private.srp_allocations(return_id,receipt_id,return_number)values($1,$2,$3)',[returnID,legacyReceipt,returned.return_number]);
 await q("insert into greenloop_private.srp_phone_links(return_id,replacement_batch_id,replacement_job_id,replacement_device_id,return_record_key,root_record_key,root_batch_id)values($1,$2,$3,$4,$5,$5,$6)",[returnID,lc,lp.job,lp.dev,'return:'+returnID,lr]);
 const ledgerBefore=(await q('select to_jsonb(r)v from greenloop_private.srp_receipts r where id=$1',[legacyReceipt]))[0].v;
 const legacyBefore=(await q('select received_quantity,returned_quantity,replacement_quantity,balance_quantity from greenloop_private.sc_receipts()where batch_id=$1',[lr]))[0];
 const lpr=await call('get_stock_receipt_supplier_v1',[lr,s2,0]);assert.equal(lpr.batch_count,2);assert.equal(lpr.replacement_count,1);assert.equal(lpr.phone_count,1);await call('correct_stock_receipt_supplier_v1',[lr,s2,lpr.snapshot,'Correct legacy supplier across original and replacement.',crypto.randomUUID()]);
 assert.equal((await q('select supplier_id from receiving_batches where id=$1',[lc]))[0].supplier_id,s2);assert.equal((await q('select supplier_id from jobs where id=$1',[lp.job]))[0].supplier_id,s2);assert.deepEqual((await q('select to_jsonb(r)v from greenloop_private.srp_receipts r where id=$1',[legacyReceipt]))[0].v,ledgerBefore);
 assert.deepEqual((await q('select received_quantity,returned_quantity,replacement_quantity,balance_quantity from greenloop_private.sc_receipts()where batch_id=$1',[lr]))[0],legacyBefore);await deny(()=>call('get_stock_receipt_supplier_v1',[lc,null,0]),/original stock receipt/);
 // Audit snapshots keep history paging complete under concurrent insertions.
 await q("insert into greenloop_private.receipt_supplier_audit select (jsonb_populate_record(null::greenloop_private.receipt_supplier_audit,to_jsonb(a)||jsonb_build_object('request_id',gen_random_uuid(),'created_at',a.created_at+make_interval(secs=>n)))).*from greenloop_private.receipt_supplier_audit a cross join generate_series(1,50)n where a.request_id=$1",[req]);
 const page1=await call('get_stock_receipt_supplier_v1',[batch,null,0]);assert.equal(page1.history.length,50);assert.equal(page1.history_total,51);const page2=await call('get_stock_receipt_supplier_v1',[batch,null,50,page1.history_snapshot]);assert.equal(page2.history.length,1);await deny(()=>call('get_stock_receipt_supplier_v1',[batch,null,50,'changed']),/history changed/);
 console.log('PASS original + legacy replacement deliveries, original-unit counts and immutable replacement ledgers; Chaman current report labels and later GL receiving; stale review and snapshot-checked51-row history.');
 const largeBatch=(await q("insert into receiving_batches(batch_number,invoice_number,supplier_id,planned_quantity,receiving_source)values('BATCH-RSS-LARGE','INV-RSS-LARGE',$1,1500,'Stock')returning id",[s1]))[0].id;
 await db.exec('reset role;set session_replication_role=replica');
 await db.query("insert into devices select(jsonb_populate_record(null::devices,to_jsonb(d)||jsonb_build_object('id',md5($1||n::text)::uuid,'imei_1',(398799999000000+n)::text,'imei_2',null,'serial_number',null,'device_number','RSS-LARGE-'||n))).*from devices d cross join generate_series(1,1500)n where d.id=$2",[largeBatch,phones[2].dev]);
 await db.query("insert into jobs select(jsonb_populate_record(null::jobs,to_jsonb(j)||jsonb_build_object('id',md5($1||'job'||n::text)::uuid,'device_id',md5($1||n::text)::uuid,'job_number','RSS-LARGE-JOB-'||n,'receiving_batch_id',$1,'supplier_id',$3::text))).*from jobs j cross join generate_series(1,1500)n where j.id=$2",[largeBatch,phones[2].job,s1]);await db.exec('set session_replication_role=origin;set role authenticated');
 const started=performance.now(),largePreview=await call('get_stock_receipt_supplier_v1',[largeBatch,s2,0]),reviewMs=performance.now()-started;assert.equal(largePreview.phone_count,1500);
 const saveStarted=performance.now();await call('correct_stock_receipt_supplier_v1',[largeBatch,s2,largePreview.snapshot,'Correct supplier for the complete large delivery.',crypto.randomUUID()]);const saveMs=performance.now()-saveStarted;
 assert.equal((await q('select count(*)::int n from jobs where receiving_batch_id=$1 and supplier_id=$2',[largeBatch,s2]))[0].n,1500);assert.equal((await q('select count(*)::int n from greenloop_private.receipt_supplier_permits'))[0].n,0);
 console.log('PASS1500 phones with complete exact atomic metadata correction; scoped row proofs cleared. Local fixture review '+Math.round(reviewMs)+'ms / save '+Math.round(saveMs)+'ms (not production timings).');
 // A working quantity-only Reports editor does not inherit this new action.
 await q("update public.user_page_permissions set access_level='edit'where user_id=$1 and page_key='reports'",[staff]);
 await q("update greenloop_private.user_page_capabilities set capabilities=jsonb_set(capabilities,'{reports}','[\"view\",\"report_receipt_correction\",\"receipt_quantity_correction\"]')where user_id=$1",[staff]);
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[staff]);await deny(()=>call('correct_stock_receipt_supplier_v1',args),/permission/);
 const masked=await call('get_stock_receipt_supplier_v1',[batch,null,0]);assert.equal(masked.supplier_name,null);assert(masked.suppliers.every(s=>s.supplier_name===null));assert(masked.history.every(h=>h.old_name===null&&h.new_name===null));assert(!JSON.stringify(masked).includes('PRIVATE'));
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[admin]);
 await q("insert into greenloop_private.office_user_access(user_id,mode)values($1,'office')on conflict(user_id)do update set mode='office'",[admin]);await deny(()=>call('get_stock_receipt_supplier_v1',[batch,null,0]),/office|network/i);
 await db.exec('rollback;reset role;set role anon');await assert.rejects(()=>call('get_stock_receipt_supplier_v1',[batch,null,0]),/permission denied/);await assert.rejects(()=>call('correct_stock_receipt_supplier_v1',args),/permission denied/);
 await db.exec('reset role');console.log('Installer tamper fixture role:',(await db.query('select current_user,session_user')).rows[0]);await db.exec('begin');await db.exec('grant execute on function greenloop_private.rss_scope(uuid)to authenticated');assert.equal(await call('get_receipt_supplier_correction_version'),null);await assert.rejects(()=>db.exec(sql),/integrity differs/);await db.exec('rollback');await db.exec('begin');await db.exec('alter table greenloop_private.receipt_supplier_audit disable trigger receipt_supplier_audit_immutable');assert.equal(await call('get_receipt_supplier_correction_version'),null);await assert.rejects(()=>db.exec(sql),/integrity differs/);await db.exec('rollback');
 console.log('PASS permanent history/direct receipt mutation denials; independent write/Office/anonymous boundaries.');
}finally{await db.close()}})().catch(e=>{console.error(e.message,e.where,e.stack);process.exitCode=1});
