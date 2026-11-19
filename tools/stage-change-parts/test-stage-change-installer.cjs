const fs=require('fs'),assert=require('assert/strict'),{PGlite}=require('C:/Users/zeeea/Documents/Codex/2026-09-15/greenloop-chat-3/work/audit-tests/node_modules/@electric-sql/pglite');
const sql=fs.readFileSync(require('path').resolve(__dirname,'../../supabase/migrations/20261119_332_stage_change_parts_recovery.sql'),'utf8');
(async()=>{const db=new PGlite({loadDataDir:new Blob([fs.readFileSync(process.env.STAGE_CHANGE_BASE||'C:/Users/zeeea/Documents/Codex/2026-11-12/gl4/work/stage-change-base.gz')])});try{
async function refused(mutation){await db.exec('begin');try{await mutation();await assert.rejects(()=>db.exec(sql),/integrity|verified|differs|verification/i);}finally{await db.exec('rollback');}}
for(const helper of ['greenloop_private.bdept_return_order(uuid)','greenloop_private.handover_technician_timer(uuid,uuid,uuid,text)','greenloop_private.wfs_read(text)'])await refused(async()=>{const def=(await db.query('select pg_get_functiondef($1::regprocedure)s',[helper])).rows[0].s;await db.exec(def.replace('AS $function$','AS $function$\n-- Unauthorized edit\n'));});
assert(!/office_impl_[0-9]+|cap_impl_[0-9a-f]+/.test(sql));await db.exec(sql);
async function repeatRefused(mutation){await db.exec('begin');try{await mutation();assert.equal((await db.query('select public.get_stage_change_parts_version()v')).rows[0].v,null);await assert.rejects(()=>db.exec(sql),/integrity/);}finally{await db.exec('rollback');}}
for(const [table,trigger]of [['stage_change_audit','stage_change_immutable'],['cancelled_phone_cases','cancelled_phone_immutable'],['cancelled_part_collections','cancelled_collection_immutable'],['qc_saved_issuance','stage_lease_finished']])await repeatRefused(()=>db.exec(`alter table greenloop_private.${table} disable trigger ${trigger}`));
await repeatRefused(()=>db.exec('alter table public.job_work_orders disable trigger stage_work_cancelled'));
for(const table of ['stage_change_audit','stage_qc_leases','cancelled_phone_cases','cancelled_part_collections','stage_change_parts_installation'])await repeatRefused(()=>db.exec(`alter table greenloop_private.${table} disable row level security`));
await repeatRefused(()=>db.exec('grant execute on function greenloop_private.scp_apply(uuid,text,text,uuid,text,text,uuid)to authenticated'));
await repeatRefused(()=>db.exec('grant execute on function public.collect_cancelled_phone_part_v1(uuid,uuid,text,integer,text,text,uuid)to anon'));
await repeatRefused(()=>db.exec("update greenloop_private.capability_rpc_rules set rule='{}'where rpc_name='apply_imei_stage_change_v1'"));
await repeatRefused(()=>db.exec('drop index public.stage_parts_install_issue_idx'));
await db.exec('set role anon');await assert.rejects(()=>db.exec("select public.get_cancelled_parts_phones_v1()"),/permission denied/);await assert.rejects(()=>db.exec("select public.get_imei_stage_change_v1('399100000000000')"),/permission denied/);
console.log('PASS reviewed helper tamper denial, all five trigger protections, five private RLS tables, private helper / anonymous write grants, RPC rule tamper, repeat fail-closed and no generated implementation names.');
}finally{await db.close()}})().catch(e=>{console.error(e.stack,e.where);process.exitCode=1});
