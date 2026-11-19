const fs=require('fs'),assert=require('assert/strict');
const {PGlite}=require('C:/Users/zeeea/Documents/Codex/2026-09-15/greenloop-chat-3/work/audit-tests/node_modules/@electric-sql/pglite');
const base='C:/Users/zeeea/Documents/Codex/2026-09-15/greenloop-chat-3/work',root=require('path').resolve(__dirname,'../..'),sql=fs.readFileSync(root+'/supabase/migrations/20261119_331_receipt_supplier_correction.sql','utf8');
(async()=>{const d=new PGlite({loadDataDir:new Blob([fs.readFileSync(base+'/background-read-base.gz')])});try{
for(const f of ['20261118_327_background_read_speed.sql','20261118_328_lab_counter_membership.sql','20261118_329_lab_transfer_readiness.sql','20261119_330_chaman_custody_notice.sql'])await d.exec(fs.readFileSync(root+'/supabase/migrations/'+f,'utf8'));
const api='public.list_simple_stock_returns(date,date)';
async function deny(fn,rx){await d.exec('begin');try{await fn();await assert.rejects(()=>d.exec(sql),rx);}finally{await d.exec('rollback');}assert.equal((await d.query("select to_regclass('greenloop_private.receipt_supplier_installation')v")).rows[0].v,null);}
await deny(()=>d.query('delete from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure($1)',[api]),/Missing, ambiguous|prerequisites|integrity/);
await deny(()=>d.query("update greenloop_private.office_routines set original_hash=repeat('0',32)where to_regprocedure(identity)=to_regprocedure($1)",[api]),/changed registered|prerequisites|integrity/);
const target=(await d.query('select to_regprocedure(implementation)::oid oid from greenloop_private.office_routines where to_regprocedure(identity)=to_regprocedure($1)',[api])).rows[0].oid;
const old=(await d.query('select pg_get_functiondef($1::oid)s',[target])).rows[0].s;
const clone=old.replace(/FUNCTION greenloop_private\.[^(]+\(/,'FUNCTION greenloop_private.fixture_alternate_lab(');
await deny(async()=>{await d.exec(clone);await d.query("insert into greenloop_private.office_routines(identity,implementation,original_hash,wrapped_hash)values($1,'greenloop_private.fixture_alternate_lab(date,date)',md5(pg_get_functiondef('greenloop_private.fixture_alternate_lab(date,date)'::regprocedure)),md5(pg_get_functiondef(to_regprocedure($2))))",['public.list_simple_stock_returns(date, date)',api]);},/Missing, ambiguous|prerequisites|integrity/);
await deny(async()=>{await d.exec(clone);await d.query("update greenloop_private.office_routines set implementation='greenloop_private.fixture_alternate_lab(date,date)',original_hash=md5(pg_get_functiondef('greenloop_private.fixture_alternate_lab(date,date)'::regprocedure))where to_regprocedure(identity)=to_regprocedure($1)",[api]);},/Disconnected|prerequisites|integrity/);
assert(!/office_impl_[0-9]+|cap_impl_[0-9a-f]+/.test(sql));console.log('PASS missing, ambiguous, tampered and disconnected registered Stock Return implementations reject atomically; no generated names in delivered SQL.');
}finally{await d.close()}})().catch(e=>{console.error(e.message,e.where,e.stack);process.exitCode=1});
