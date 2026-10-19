-- Independent manual production ledger. No IMEI, QC, box or operational-stock writes.
begin;
do $$ begin
 if public.get_suspicious_activity_version() is distinct from '20261017-suspicious-activity-1' then raise exception 'Install the verified Suspicious Activity update first.';end if;
end; $$;
create table if not exists greenloop_private.daily_production_installation(identity text primary key,hash text not null);
create table if not exists greenloop_private.daily_production_options(
 id uuid primary key default gen_random_uuid(),kind text not null check(kind in ('model','grade')),
 name text not null check(length(name) between 1 and 100),active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(),created_by uuid
);
create unique index if not exists daily_production_option_name on greenloop_private.daily_production_options(kind,lower(name));
create table if not exists greenloop_private.daily_production_balances(
 model_id uuid not null references greenloop_private.daily_production_options(id),
 grade_id uuid not null references greenloop_private.daily_production_options(id),
 quantity bigint not null default 0 check(quantity>=0),primary key(model_id,grade_id)
);
create table if not exists greenloop_private.daily_production_entries(
 id uuid primary key default gen_random_uuid(),request_id uuid not null unique,
 model_id uuid not null references greenloop_private.daily_production_options(id),
 grade_id uuid not null references greenloop_private.daily_production_options(id),
 production_date date not null,kind text not null check(kind in ('add','remove','opening')),
 quantity integer not null check(quantity between 1 and 1000000),note text not null default '' check(length(note)<=1000),
 actor_id uuid not null,actor_name text not null,recorded_at timestamptz not null default clock_timestamp()
);
create index if not exists daily_production_entry_date on greenloop_private.daily_production_entries(production_date desc,id);
create index if not exists daily_production_entry_pair on greenloop_private.daily_production_entries(model_id,grade_id,production_date);
create table if not exists greenloop_private.daily_production_option_audit(
 id bigint generated always as identity primary key,option_id uuid not null,actor_id uuid not null,
 recorded_at timestamptz not null default clock_timestamp(),action text not null,details jsonb not null
);
insert into greenloop_private.daily_production_options(kind,name) values('grade','A'),('grade','B'),('grade','C'),('grade','D') on conflict do nothing;
insert into greenloop_private.page_capability_catalog values('daily_production','[{"key":"view","label":"View stock & daily reports","write":false},{"key":"search","label":"Search & date filters","write":false},{"key":"sort","label":"Sort table headings","write":false},{"key":"entry","label":"Add production / opening stock","write":true},{"key":"adjust","label":"Remove stock / corrections","write":true},{"key":"manage_options","label":"Add / remove models & grades","write":true},{"key":"download","label":"Download reports","write":false}]') on conflict(page_key) do update set capabilities=excluded.capabilities;
do $access$ declare d text;impl text;c record; begin
 select implementation into impl from greenloop_private.capability_routines where identity in ('save_user_page_access(uuid,text,text,boolean,text[])','public.save_user_page_access(uuid,text,text,boolean,text[])');
 if impl is null then raise exception 'Verified user access implementation not found.';end if;
 d:=pg_get_functiondef(to_regprocedure(impl));
 if position('''daily_production''' in d)=0 then
  if position('''accounts'',''stock_exported''' in d)=0 then raise exception 'Unexpected user access allow-list.';end if;
  execute replace(d,'''accounts'',''stock_exported''','''accounts'',''stock_exported'',''daily_production''');
  update greenloop_private.capability_routines set original_hash=md5(pg_get_functiondef(to_regprocedure(impl))) where implementation=impl;
 end if;
 select * into c from pg_constraint where conrelid='public.user_page_permissions'::regclass and conname='user_page_permissions_page_key_check';
 d:=pg_get_constraintdef(c.oid);
 if d is null then raise exception 'Page permission constraint missing.';end if;
 if position('daily_production' in d)=0 then
  if position('''stock_exported''::text' in d)=0 then raise exception 'Unexpected page permission constraint.';end if;
  execute 'alter table public.user_page_permissions drop constraint user_page_permissions_page_key_check';
  execute 'alter table public.user_page_permissions add constraint user_page_permissions_page_key_check '||replace(d,'''stock_exported''::text','''stock_exported''::text, ''daily_production''::text');
 end if;
end; $access$;
-- Grant the new independent page once to Super Admin. Preserve all other grants.
do $$ begin if not exists(select 1 from greenloop_private.daily_production_installation where identity='installed_at') then
 insert into greenloop_private.user_page_capabilities(user_id,capabilities)
 select u.id,greenloop_private.user_capabilities(u.id)||'{"daily_production":["view","search","sort","entry","adjust","manage_options","download"]}'::jsonb
 from public.user_profiles u where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text='super_admin') and not greenloop_private.damage_tv_only(u.id)
 on conflict(user_id) do update set capabilities=excluded.capabilities;
 insert into public.user_page_permissions(user_id,page_key,access_level)
 select u.id,'daily_production','edit' from public.user_profiles u where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=u.id and r.role_key::text='super_admin') and not greenloop_private.damage_tv_only(u.id) on conflict(user_id,page_key) do nothing;
 insert into greenloop_private.daily_production_installation values('installed_at',clock_timestamp()::text);
end if;end; $$;
create or replace function greenloop_private.daily_production_require(p_cap text)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$ begin
 if not public.has_page_capability_v1('daily_production','view') or not public.has_page_capability_v1('daily_production',p_cap) then raise exception 'Daily Production % permission required.',p_cap using errcode='42501';end if;
end; $$;
create or replace function public.save_daily_production_option_v1(p_kind text,p_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_name text:=regexp_replace(btrim(p_name),'\s+',' ','g');r greenloop_private.daily_production_options;begin
 perform greenloop_private.daily_production_require('manage_options');
 if p_kind is null or p_kind not in ('model','grade') or v_name is null or length(v_name) not between 1 and 100 then raise exception 'Enter a model or grade name (1–100 characters).' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('daily-production-option:'||p_kind||lower(v_name),0));
 select * into r from greenloop_private.daily_production_options where kind=p_kind and lower(name)=lower(v_name) for update;
 if found then
  if not r.active then update greenloop_private.daily_production_options set active=true where id=r.id returning * into r;
   insert into greenloop_private.daily_production_option_audit(option_id,actor_id,action,details) values(r.id,auth.uid(),'restore',to_jsonb(r));end if;
 else
  insert into greenloop_private.daily_production_options(kind,name,created_by) values(p_kind,v_name,auth.uid()) returning * into r;
  insert into greenloop_private.daily_production_option_audit(option_id,actor_id,action,details) values(r.id,auth.uid(),'add',to_jsonb(r));
 end if;
 return to_jsonb(r);
end; $$;
create or replace function public.archive_daily_production_option_v1(p_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare r greenloop_private.daily_production_options;begin
 perform greenloop_private.daily_production_require('manage_options');
 select * into r from greenloop_private.daily_production_options where id=p_id for update;
 if not found then raise exception 'Model or grade not found.' using errcode='22023';end if;
 if exists(select 1 from greenloop_private.daily_production_balances where (model_id=p_id or grade_id=p_id) and quantity<>0) then raise exception 'Remove the remaining stock before removing this model or grade.' using errcode='22023';end if;
 if r.active then
  update greenloop_private.daily_production_options set active=false where id=p_id;
  insert into greenloop_private.daily_production_option_audit(option_id,actor_id,action,details) values(p_id,auth.uid(),'archive',to_jsonb(r));
 end if;
end; $$;
create or replace function public.record_daily_production_v1(p_request_id uuid,p_model_id uuid,p_grade_id uuid,p_date date,p_kind text,p_quantity integer,p_note text default '')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r greenloop_private.daily_production_entries;v_delta bigint;v_balance bigint;v_note text:=btrim(coalesce(p_note,''));v_min bigint;begin
 perform greenloop_private.daily_production_require(case when p_kind='remove' then 'adjust' else 'entry' end);
 if p_request_id is null or p_model_id is null or p_grade_id is null or p_kind is null or p_kind not in ('add','remove','opening') or p_quantity is null or p_quantity not between 1 and 1000000 or p_date is null or p_date<'2000-01-01'::date or p_date>(clock_timestamp() at time zone 'Asia/Dubai')::date or length(v_note)>1000 or (p_kind='remove' and length(v_note)<3) then raise exception 'Choose a valid date, model, grade and whole quantity. Removals need a reason; future dates are not allowed.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('daily-production-request:'||p_request_id::text,0));
 select * into r from greenloop_private.daily_production_entries where request_id=p_request_id;
 if found then
  if r.actor_id<>auth.uid() or r.model_id<>p_model_id or r.grade_id<>p_grade_id or r.production_date<>p_date or r.kind<>p_kind or r.quantity<>p_quantity or r.note<>v_note then raise exception 'This save request was already used for a different entry. Refresh before saving.' using errcode='22023';end if;
  return jsonb_build_object('id',r.id,'replayed',true);
 end if;
 perform 1 from greenloop_private.daily_production_options where id=p_model_id and kind='model' and active for share;
 if not found then raise exception 'Choose an active model.' using errcode='22023';end if;
 perform 1 from greenloop_private.daily_production_options where id=p_grade_id and kind='grade' and active for share;
 if not found then raise exception 'Choose an active grade.' using errcode='22023';end if;
 insert into greenloop_private.daily_production_balances(model_id,grade_id) values(p_model_id,p_grade_id) on conflict do nothing;
 select quantity into v_balance from greenloop_private.daily_production_balances where model_id=p_model_id and grade_id=p_grade_id for update;
 v_delta:=case when p_kind='remove' then -p_quantity else p_quantity end;
 if v_balance+v_delta<0 then raise exception 'Not enough stock. Available: %.',v_balance using errcode='22023';end if;
 -- A backdated removal cannot create a negative closing balance on any later event_day.
 if p_kind='remove' then
  select min(balance) into v_min from (
   select sum(delta) over(order by event_day rows unbounded preceding) balance from (
    select event_day,sum(delta) delta from (
     select production_date event_day,case when kind='remove' then -quantity else quantity end::bigint delta from greenloop_private.daily_production_entries where model_id=p_model_id and grade_id=p_grade_id
     union all select p_date,v_delta
    ) events group by event_day
   ) days
  ) running;
  if v_min<0 then raise exception 'This date would create negative historical stock. Choose the correct removal date.' using errcode='22023';end if;
 end if;
 insert into greenloop_private.daily_production_entries(request_id,model_id,grade_id,production_date,kind,quantity,note,actor_id,actor_name)
 values(p_request_id,p_model_id,p_grade_id,p_date,p_kind,p_quantity,v_note,auth.uid(),coalesce((select nullif(full_name,'') from public.user_profiles where id=auth.uid()),'Staff')) returning * into r;
 update greenloop_private.daily_production_balances set quantity=quantity+v_delta where model_id=p_model_id and grade_id=p_grade_id;
 return jsonb_build_object('id',r.id,'balance',v_balance+v_delta,'replayed',false);
end; $$;
create or replace function public.get_daily_production_v1(p_view text default 'stock',p_filters jsonb default '{}',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_today date:=(statement_timestamp() at time zone 'Asia/Dubai')::date;v_from date;v_to date;v_query text;v_model text;v_grade text;v_rows jsonb;v_total integer;v_limit integer;v_grade_sort text;v_stats jsonb;v_options jsonb;begin
 perform greenloop_private.daily_production_require('view');
 if p_view is null or p_view not in ('stock','daily','history') or jsonb_typeof(p_filters) is distinct from 'object' or p_offset is null or p_offset<0 or p_download is null then raise exception 'Invalid report request.' using errcode='22023';end if;
 if p_filters<>'{}'::jsonb then perform greenloop_private.daily_production_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.daily_production_require('sort');end if;
 if p_download then perform greenloop_private.daily_production_require('download');end if;
 if exists(select 1 from jsonb_object_keys(p_filters) k where k not in ('from','to','query','model','grade')) then raise exception 'Unknown filter.' using errcode='22023';end if;
 v_query:=btrim(coalesce(p_filters->>'query',''));v_model:=nullif(p_filters->>'model','');v_grade:=nullif(p_filters->>'grade','');
 if length(v_query)>100 then raise exception 'Search is too long.' using errcode='22023';end if;
 v_from:=nullif(p_filters->>'from','')::date;v_to:=nullif(p_filters->>'to','')::date;
 if v_from>v_to then raise exception 'From must be on or before To.' using errcode='22023';end if;
 if p_view='stock' and (v_from is not null or v_to is not null) then raise exception 'Current stock includes all dates.' using errcode='22023';end if;
 if p_view='daily' and not(p_filters?'from' or p_filters?'to') then v_from:=v_today;v_to:=v_today;end if;
 if p_sort like 'grade:%' then
  v_grade_sort:=split_part(p_sort,':',2);
  if p_view<>'stock' or split_part(p_sort,':',3) not in ('asc','desc') or not exists(select 1 from greenloop_private.daily_production_options where id::text=v_grade_sort and kind='grade') then raise exception 'Invalid grade sort.' using errcode='22023';end if;
 elsif p_sort is null or p_sort not in ('default','model_asc','model_desc','date_asc','date_desc','quantity_asc','quantity_desc','added_asc','added_desc','removed_asc','removed_desc','grade_asc','grade_desc') then raise exception 'Invalid sorting.' using errcode='22023';end if;
 v_limit:=case when p_download then 10000 else 50 end;
 select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name),id),'[]') into v_options from greenloop_private.daily_production_options o;
 select jsonb_build_object('current_stock',(select coalesce(sum(quantity),0) from greenloop_private.daily_production_balances),
  'added_today',coalesce(sum(quantity) filter(where kind='add' and production_date=v_today),0),'removed_today',coalesce(sum(quantity) filter(where kind='remove' and production_date=v_today),0),
  'opening_today',coalesce(sum(quantity) filter(where kind='opening' and production_date=v_today),0)) into v_stats from greenloop_private.daily_production_entries;
 if p_view='stock' then
  with data as (
   select m.id model_id,m.name model,coalesce(sum(b.quantity),0) quantity,coalesce(jsonb_object_agg(b.grade_id,b.quantity) filter(where b.grade_id is not null),'{}') grades
   from greenloop_private.daily_production_options m left join greenloop_private.daily_production_balances b on b.model_id=m.id and (v_grade is null or b.grade_id::text=v_grade)
   where m.kind='model' and m.active and (v_model is null or m.id::text=v_model) and (v_query='' or position(lower(v_query) in lower(m.name))>0) group by m.id
  ), numbered as (
   select *,row_number() over(order by
    case when p_sort='model_desc' then lower(model) end desc,
    case when p_sort='quantity_asc' then quantity end asc,case when p_sort='quantity_desc' then quantity end desc,
    case when v_grade_sort is not null and split_part(p_sort,':',3)='asc' then coalesce((grades->>v_grade_sort)::bigint,0) end asc,
    case when v_grade_sort is not null and split_part(p_sort,':',3)='desc' then coalesce((grades->>v_grade_sort)::bigint,0) end desc,
    lower(model),model_id) rn from data
  ) select (select count(*) from data),coalesce(jsonb_agg(to_jsonb(n)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+v_limit),'[]') into v_total,v_rows from numbered n;
 else
  with days as (
   select production_date event_day,model_id,grade_id,sum(quantity) filter(where kind='add') added,sum(quantity) filter(where kind='remove') removed,sum(quantity) filter(where kind='opening') opening,
    sum(case when kind='remove' then -quantity else quantity end) delta from greenloop_private.daily_production_entries group by production_date,model_id,grade_id
  ), running as (select *,sum(delta) over(partition by model_id,grade_id order by event_day rows unbounded preceding) closing from days),
  data as (
   select null::text id,d.event_day date,d.model_id,d.grade_id,m.name model,g.name grade,coalesce(d.added,0) added,coalesce(d.removed,0) removed,coalesce(d.opening,0) opening,d.closing quantity,
    (d.closing-d.delta) opening_balance,null::text kind,null::text note,null::text actor_name,null::timestamptz recorded_at
   from running d join greenloop_private.daily_production_options m on m.id=d.model_id join greenloop_private.daily_production_options g on g.id=d.grade_id where p_view='daily'
   union all
   select e.id::text,e.production_date,e.model_id,e.grade_id,m.name,g.name,null,null,null,e.quantity,null,e.kind,e.note,e.actor_name,e.recorded_at
   from greenloop_private.daily_production_entries e join greenloop_private.daily_production_options m on m.id=e.model_id join greenloop_private.daily_production_options g on g.id=e.grade_id where p_view='history'
  ), filtered as (select * from data where (v_from is null or date>=v_from) and (v_to is null or date<=v_to) and (v_model is null or model_id::text=v_model) and (v_grade is null or grade_id::text=v_grade)
   and (v_query='' or position(lower(v_query) in lower(concat_ws(' ',model,grade,note,actor_name)))>0)),
  numbered as (select *,row_number() over(order by
   case when p_sort='model_asc' then lower(model) end asc,case when p_sort='model_desc' then lower(model) end desc,
   case when p_sort='grade_asc' then lower(grade) end asc,case when p_sort='grade_desc' then lower(grade) end desc,
   case when p_sort='quantity_asc' then quantity end asc,case when p_sort='quantity_desc' then quantity end desc,
   case when p_sort='added_asc' then added end asc,case when p_sort='added_desc' then added end desc,
   case when p_sort='removed_asc' then removed end asc,case when p_sort='removed_desc' then removed end desc,
   case when p_sort='date_asc' then date end asc,date desc,recorded_at desc,lower(model),lower(grade),id) rn from filtered)
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(n)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+v_limit),'[]') into v_total,v_rows from numbered n;
 end if;
 if p_download and v_total>10000 then raise exception 'More than 10,000 rows. Narrow the date or model filters before downloading.' using errcode='22023';end if;
 return jsonb_build_object('rows',v_rows,'total',v_total,'options',v_options,'stats',v_stats,'today',v_today,'from',v_from,'to',v_to,'view',p_view);
end; $$;
-- Only guarded RPCs can touch this independent ledger.
do $acl$ declare t text;f record;begin
 foreach t in array array['daily_production_installation','daily_production_options','daily_production_balances','daily_production_entries','daily_production_option_audit'] loop
  execute format('alter table greenloop_private.%I enable row level security',t);
  execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);
 end loop;
 revoke all on sequence greenloop_private.daily_production_option_audit_id_seq from public,anon,authenticated;
 for f in select p.oid::regprocedure::text signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('daily_production_require','save_daily_production_option_v1','archive_daily_production_option_v1','record_daily_production_v1','get_daily_production_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end; $acl$;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
do $$ declare t text;begin foreach t in array array['greenloop_private.tv_damage_access_installation','greenloop_private.supplier_return_installation'] loop
 execute format('update %s i set definition_hash=md5(pg_get_constraintdef(c.oid)||c.convalidated::text) from pg_constraint c where i.object_kind=''constraint'' and c.conrelid=''public.user_page_permissions''::regclass and c.conname=i.object_identity and c.conname=''user_page_permissions_page_key_check''',t);
end loop;end; $$;
insert into greenloop_private.daily_production_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('daily_production_require','save_daily_production_option_v1','archive_daily_production_option_v1','record_daily_production_v1','get_daily_production_v1') on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_daily_production_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_suspicious_activity_version()='20261017-suspicious-activity-1'
 and (select count(*)=5 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.daily_production_installation where identity<>'installed_at')
 and (select count(*)=5 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in ('daily_production_installation','daily_production_options','daily_production_balances','daily_production_entries','daily_production_option_audit'))
 and not exists(select 1 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in ('daily_production_installation','daily_production_options','daily_production_balances','daily_production_entries','daily_production_option_audit') and (not relrowsecurity or has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 then '20261019-daily-production-1' end;
$$;
revoke all on function public.get_daily_production_version() from public;
grant execute on function public.get_daily_production_version() to anon,authenticated;
do $$ begin if public.get_daily_production_version() is distinct from '20261019-daily-production-1' then raise exception 'Daily Production verification failed. Installation rolled back.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_daily_production_version() as installed_daily_production_version;
