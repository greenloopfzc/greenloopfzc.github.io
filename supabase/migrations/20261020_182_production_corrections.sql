-- Date-wise closing stock and audited correction of individual box counts.
begin;
do $$begin if public.get_production_voice_version() is distinct from '20261020-production-voice-1' then raise exception 'Install Production Voice first.';end if;end;$$;
create table if not exists greenloop_private.closing_stock_correction_log(
 id bigint generated always as identity primary key,
 entry_id bigint not null references greenloop_private.closing_stock_audit(id),
 action text not null check(action in ('edit','delete')),
 changed_at timestamptz not null default clock_timestamp(),
 actor_id uuid not null, actor_name text not null,
 old_model_id uuid not null, old_gb_id uuid not null, old_grade_id uuid not null, old_quantity integer not null,
 new_model_id uuid, new_gb_id uuid, new_grade_id uuid, new_quantity integer
);
alter table greenloop_private.closing_stock_correction_log enable row level security;
revoke all on greenloop_private.closing_stock_correction_log from public,anon,authenticated;
revoke all on sequence greenloop_private.closing_stock_correction_log_id_seq from public,anon,authenticated;
alter table greenloop_private.closing_stock_audit add column if not exists correction_revision integer not null default 0;
create index if not exists closing_stock_audit_date on greenloop_private.closing_stock_audit(stock_date desc,id desc);

-- Keep grade permissions dynamic when a new grade is created.
create or replace function greenloop_private.closing_stock_catalog() returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare caps jsonb;begin
 select '[{"key":"view","label":"Open Daily Production","write":false},{"key":"entry","label":"Daily Data Entry / Save box counts","write":true},{"key":"voice_entry","label":"Voice Entry (requires Daily Data Entry)","write":false},{"key":"total_stock","label":"Total Stock report (all grades)","write":false},{"key":"date_report","label":"Date-wise stock report","write":false},{"key":"manage_options","label":"Add / remove Model, GB and Grade","write":true},{"key":"search","label":"Search / Report date","write":false},{"key":"sort","label":"Sort table headings","write":false},{"key":"download","label":"Download permitted reports","write":false}]'::jsonb||coalesce(jsonb_agg(jsonb_build_object('key',greenloop_private.closing_grade_key(id),'label','Grade '||name||' report','write',false) order by lower(name)),'[]') into caps from greenloop_private.closing_stock_options where kind='grade';
 update greenloop_private.page_capability_catalog set capabilities=caps where page_key='daily_production';
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
end;$$;
select greenloop_private.closing_stock_catalog();
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"production_view","label":"Daily Production entry history","write":false},{"key":"production_edit","label":"Correct Daily Production entries","write":true},{"key":"production_delete","label":"Delete Daily Production entries","write":true}]'::jsonb where page_key='reports' and not capabilities @> '[{"key":"production_view"}]'::jsonb;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
-- Existing administrators who could use these pages receive the new controls;
-- other accounts remain opt-in through User Access.
do $$declare u record;c jsonb;k text;begin
 for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p.id and r.role_key::text in ('owner','super_admin')) loop
  select capabilities into c from greenloop_private.user_page_capabilities where user_id=u.id;
  if c is null then continue;end if;
  if (u.caps->'daily_production')?'view' and not (coalesce(c->'daily_production','[]'::jsonb)?'date_report') then c:=jsonb_set(c,'{daily_production}',coalesce(c->'daily_production','[]'::jsonb)||'["date_report"]'::jsonb);end if;
  if (u.caps->'reports')?'view' then
   foreach k in array array['production_view','production_edit','production_delete'] loop
    if not (coalesce(c->'reports','[]'::jsonb)?k) then c:=jsonb_set(c,'{reports}',coalesce(c->'reports','[]'::jsonb)||jsonb_build_array(k));end if;
   end loop;
  end if;
  update greenloop_private.user_page_capabilities set capabilities=c where user_id=u.id;
 end loop;
end;$$;

create or replace function public.get_closing_stock_date_report_v1(p_from date,p_to date,p_scope text,p_grade uuid default null,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare n integer;items jsonb;begin
 perform greenloop_private.closing_stock_require('date_report');
 if p_scope='total' then perform greenloop_private.closing_stock_require('total_stock');elsif p_scope='grade' and p_grade is not null then perform greenloop_private.closing_stock_require(greenloop_private.closing_grade_key(p_grade));else raise exception 'Choose Total Stock or a permitted grade.' using errcode='22023';end if;
 if p_from is null or p_to is null or p_from<'2000-01-01'::date or p_to<p_from or p_to>(statement_timestamp() at time zone 'Asia/Dubai')::date or p_to-p_from>366 or p_offset is null or p_offset<0 then raise exception 'Select a valid UAE date range of up to 367 days.' using errcode='22023';end if;
 with days as(select d::date as day from generate_series(p_from,p_to,'1 day'::interval) d),totals as(select d.day,coalesce(sum(r.previous),0) previous,coalesce(sum(r.quantity),0) quantity,coalesce(sum(r.production),0) production,coalesce(sum(r.stock_out),0) stock_out from days d left join lateral greenloop_private.closing_stock_rows(d.day) r on p_scope='total' or r.grade_id=p_grade group by d.day),paged as(select * from totals order by day desc offset p_offset limit 50) select coalesce(jsonb_agg(to_jsonb(paged) order by day desc),'[]') into items from paged;
 n:=p_to-p_from+1;
 return jsonb_build_object('rows',items,'total',n,'from',p_from,'to',p_to);
end;$$;

create or replace function public.get_closing_stock_entries_v1(p_from date,p_to date,p_query text default '',p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare rows jsonb;total integer;begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not (public.has_page_capability_v1('reports','production_view') or public.has_page_capability_v1('reports','production_edit') or public.has_page_capability_v1('reports','production_delete')) then raise exception 'Daily Production history permission required.' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from<'2000-01-01'::date or p_to<p_from or p_to>(statement_timestamp() at time zone 'Asia/Dubai')::date or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 then raise exception 'Invalid entry filters.' using errcode='22023';end if;
 with f as(select a.id,a.stock_date,a.recorded_at,a.actor_name,a.model_id,a.gb_id,a.grade_id,m.name model,b.name gb,g.name grade,a.count_quantity quantity,a.undone_at is not null deleted,a.correction_revision,l.action last_action,l.actor_name last_changed_by,l.changed_at last_changed_at from greenloop_private.closing_stock_audit a join greenloop_private.closing_stock_options m on m.id=a.model_id join greenloop_private.closing_stock_options b on b.id=a.gb_id join greenloop_private.closing_stock_options g on g.id=a.grade_id left join lateral(select action,actor_name,changed_at from greenloop_private.closing_stock_correction_log where entry_id=a.id order by id desc limit 1) l on true where a.stock_date between p_from and p_to and (btrim(coalesce(p_query,''))='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',m.name,b.name,g.name,a.actor_name,a.id::text)))>0))
 select (select count(*) from f),coalesce(jsonb_agg(to_jsonb(x) order by stock_date desc,id desc),'[]') into total,rows from(select * from f order by stock_date desc,id desc offset p_offset limit 50)x;
 return jsonb_build_object('rows',rows,'total',total,'options',case when public.has_page_capability_v1('reports','production_edit') then (select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name)),'[]') from greenloop_private.closing_stock_options o where active) else '[]'::jsonb end);
end;$$;

create or replace function public.get_closing_stock_entry_changes_v1(p_entry bigint) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not (public.has_page_capability_v1('reports','production_view') or public.has_page_capability_v1('reports','production_edit') or public.has_page_capability_v1('reports','production_delete')) then raise exception 'Daily Production history permission required.' using errcode='42501';end if;
 if not exists(select 1 from greenloop_private.closing_stock_audit where id=p_entry) then raise exception 'Entry not found.' using errcode='22023';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('action',l.action,'changed_at',l.changed_at,'actor_name',l.actor_name,'old_model',om.name,'old_gb',ob.name,'old_grade',og.name,'old_quantity',l.old_quantity,'new_model',nm.name,'new_gb',nb.name,'new_grade',ng.name,'new_quantity',l.new_quantity) order by l.id desc),'[]') from greenloop_private.closing_stock_correction_log l join greenloop_private.closing_stock_options om on om.id=l.old_model_id join greenloop_private.closing_stock_options ob on ob.id=l.old_gb_id join greenloop_private.closing_stock_options og on og.id=l.old_grade_id left join greenloop_private.closing_stock_options nm on nm.id=l.new_model_id left join greenloop_private.closing_stock_options nb on nb.id=l.new_gb_id left join greenloop_private.closing_stock_options ng on ng.id=l.new_grade_id where l.entry_id=p_entry);
end;$$;

create or replace function greenloop_private.recalculate_closing_pair_day(p_model uuid,p_gb uuid,p_grade uuid,p_day date) returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare n integer;q bigint;b integer;begin
 select baseline_quantity into b from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=p_day for update;
 select count(*),coalesce(sum(count_quantity),0) into n,q from greenloop_private.closing_stock_audit where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=p_day and undone_at is null;
 if q>1000000 then raise exception 'Combined box quantity cannot exceed 1,000,000.' using errcode='22023';end if;
 if n=0 and b is null then delete from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=p_day;
 elsif n>0 then insert into greenloop_private.closing_stock_daily(model_id,gb_id,grade_id,stock_date,quantity,stock_source,baseline_quantity,updated_by) values(p_model,p_gb,p_grade,p_day,q::integer,'count',b,auth.uid()) on conflict(model_id,gb_id,grade_id,stock_date) do update set quantity=excluded.quantity,stock_source='count',revision=greenloop_private.closing_stock_daily.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid();
 else update greenloop_private.closing_stock_daily set quantity=b,stock_source='legacy',revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=p_day;end if;
end;$$;

create or replace function public.correct_closing_stock_entry_v1(p_entry bigint,p_expected_revision integer,p_action text,p_model uuid default null,p_gb uuid default null,p_grade uuid default null,p_quantity integer default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.closing_stock_audit;new_model uuid;new_gb uuid;new_grade uuid;new_qty integer;old_key text;new_key text;k text;begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not (public.has_page_capability_v1('reports','production_view') or public.has_page_capability_v1('reports','production_edit') or public.has_page_capability_v1('reports','production_delete')) then raise exception 'Daily Production history permission required.' using errcode='42501';end if;
 if p_action not in ('edit','delete') or p_entry is null or p_expected_revision is null then raise exception 'Invalid correction request.' using errcode='22023';end if;
 if not public.has_page_capability_v1('reports',case when p_action='edit' then 'production_edit' else 'production_delete' end) then raise exception 'Daily Production correction permission required.' using errcode='42501';end if;
 -- Serialize every correction and normal box save to preserve daily totals.
 perform pg_advisory_xact_lock(17920261019);
 select * into a from greenloop_private.closing_stock_audit where id=p_entry for update;
 if not found or a.undone_at is not null then raise exception 'This entry is no longer active. Refresh the report.' using errcode='22023';end if;
 if a.correction_revision<>p_expected_revision then raise exception 'This entry changed. Refresh before saving.' using errcode='40001';end if;
 new_model:=coalesce(p_model,a.model_id);new_gb:=coalesce(p_gb,a.gb_id);new_grade:=coalesce(p_grade,a.grade_id);new_qty:=coalesce(p_quantity,a.count_quantity);
 if p_action='edit' then
  if new_qty<0 or new_qty>1000000 then raise exception 'Enter a whole quantity from 0 to 1,000,000.' using errcode='22023';end if;
  if (new_model,new_gb,new_grade,new_qty)=(a.model_id,a.gb_id,a.grade_id,a.count_quantity) then raise exception 'No values changed.' using errcode='22023';end if;
  perform 1 from greenloop_private.closing_stock_options where id=new_model and kind='model' and active for share;if not found then raise exception 'Choose an active model.' using errcode='22023';end if;
  perform 1 from greenloop_private.closing_stock_options where id=new_gb and kind='gb' and active for share;if not found then raise exception 'Choose active GB.' using errcode='22023';end if;
  perform 1 from greenloop_private.closing_stock_options where id=new_grade and kind='grade' and active for share;if not found then raise exception 'Choose an active grade.' using errcode='22023';end if;
 end if;
 old_key:='closing-pair:'||a.model_id||a.gb_id||a.grade_id;new_key:='closing-pair:'||new_model||new_gb||new_grade;
 for k in select distinct x from unnest(array[old_key,new_key]) x order by x loop perform pg_advisory_xact_lock(hashtextextended(k,0));end loop;
 insert into greenloop_private.closing_stock_correction_log(entry_id,action,actor_id,actor_name,old_model_id,old_gb_id,old_grade_id,old_quantity,new_model_id,new_gb_id,new_grade_id,new_quantity) values(a.id,p_action,auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),a.model_id,a.gb_id,a.grade_id,a.count_quantity,case when p_action='edit' then new_model end,case when p_action='edit' then new_gb end,case when p_action='edit' then new_grade end,case when p_action='edit' then new_qty end);
 if p_action='delete' then update greenloop_private.closing_stock_audit set undone_at=clock_timestamp(),correction_revision=correction_revision+1 where id=a.id;
 else update greenloop_private.closing_stock_audit set model_id=new_model,gb_id=new_gb,grade_id=new_grade,count_quantity=new_qty,correction_revision=correction_revision+1 where id=a.id;end if;
 perform greenloop_private.recalculate_closing_pair_day(a.model_id,a.gb_id,a.grade_id,a.stock_date);
 if p_action='edit' and (new_model,new_gb,new_grade) is distinct from (a.model_id,a.gb_id,a.grade_id) then perform greenloop_private.recalculate_closing_pair_day(new_model,new_gb,new_grade,a.stock_date);end if;
 return jsonb_build_object('saved',true,'entry_id',a.id,'action',p_action,'revision',a.correction_revision+1);
end;$$;

do $$declare f record;begin
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.proname in ('get_closing_stock_date_report_v1','get_closing_stock_entries_v1','get_closing_stock_entry_changes_v1','recalculate_closing_pair_day','correct_closing_stock_entry_v1') and n.nspname in ('public','greenloop_private') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
 end loop;
end;$$;
create or replace function public.get_production_corrections_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_voice_version()='20261020-production-voice-1'
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"date_report","write":false}]'::jsonb)
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"production_view","write":false},{"key":"production_edit","write":true},{"key":"production_delete","write":true}]'::jsonb)
 and to_regclass('greenloop_private.closing_stock_correction_log') is not null
 and not has_table_privilege('authenticated','greenloop_private.closing_stock_correction_log','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and (select count(*)=4 and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE') and has_function_privilege('authenticated',p.oid,'EXECUTE')) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_closing_stock_date_report_v1','get_closing_stock_entries_v1','get_closing_stock_entry_changes_v1','correct_closing_stock_entry_v1'))
 and not has_function_privilege('authenticated','greenloop_private.recalculate_closing_pair_day(uuid,uuid,uuid,date)','EXECUTE')
 then '20261020-production-corrections-1' end;
$$;
revoke all on function public.get_production_corrections_version() from public;grant execute on function public.get_production_corrections_version() to anon,authenticated;
do $$begin if public.get_production_corrections_version() is distinct from '20261020-production-corrections-1' then raise exception 'Production corrections verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_production_corrections_version() as installed_production_corrections_version;
