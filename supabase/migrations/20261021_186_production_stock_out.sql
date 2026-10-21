-- Independent manual Stock Out. It never subtracts from counted closing stock.
begin;
do $$ begin if public.get_production_start_date_version() is distinct from '20261021-production-start-dates-1' then raise exception 'Install the Production Date Fix first.';end if;end; $$;
create table if not exists greenloop_private.production_stock_out(
 id uuid primary key default gen_random_uuid(),request_id uuid unique not null,
 actor_id uuid not null,actor_name text not null,recorded_at timestamptz not null default clock_timestamp(),
 production_day date not null check(production_day>='2000-01-01'),
 model_id uuid not null references greenloop_private.closing_stock_options,
 gb_id uuid not null references greenloop_private.closing_stock_options,
 grade_id uuid not null references greenloop_private.closing_stock_options,
 quantity integer not null check(quantity between 1 and 1000000),
 revision integer not null default 0,deleted_at timestamptz
);
create index if not exists production_stock_out_day on greenloop_private.production_stock_out(production_day,model_id,gb_id,grade_id) where deleted_at is null;
create table if not exists greenloop_private.production_stock_out_changes(
 id bigint generated always as identity primary key,entry_id uuid not null references greenloop_private.production_stock_out,
 action text not null check(action in ('edit','delete')),actor_id uuid not null,actor_name text not null,
 changed_at timestamptz not null default clock_timestamp(),before_data jsonb not null,after_data jsonb not null
);
alter table greenloop_private.production_stock_out enable row level security;
alter table greenloop_private.production_stock_out_changes enable row level security;
revoke all on greenloop_private.production_stock_out,greenloop_private.production_stock_out_changes from public,anon,authenticated;
revoke all on sequence greenloop_private.production_stock_out_changes_id_seq from public,anon,authenticated;
drop trigger if exists production_stock_out_log_immutable on greenloop_private.production_stock_out_changes;
create trigger production_stock_out_log_immutable before update or delete or truncate on greenloop_private.production_stock_out_changes for each statement execute function greenloop_private.prevent_manual_damage_quantity_changes();

-- Preserve existing effective grants; new staff permissions are opt-in.
do $$declare u record;begin for u in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
 insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps) on conflict(user_id) do nothing;
end loop;end;$$;
do $$declare ddl text;begin
 ddl:=pg_get_functiondef('greenloop_private.closing_stock_catalog()'::regprocedure);
 if strpos(ddl,'stock_out_entry')=0 then
  ddl:=replace(ddl,'{"key":"voice_entry"','{"key":"stock_out_entry","label":"Stock Out Entry / Save manual out quantities","write":true},{"key":"voice_entry"');
  if strpos(ddl,'stock_out_entry')=0 then raise exception 'Unexpected closing stock permission catalog.';end if;
  execute ddl;
 end if;
end;$$;
select greenloop_private.closing_stock_catalog();
update greenloop_private.closing_stock_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.production_voice_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity='greenloop_private.closing_stock_catalog()';
update greenloop_private.page_capability_catalog set capabilities=capabilities||'[{"key":"stock_out_view","label":"Daily Production Stock Out history","write":false},{"key":"stock_out_edit","label":"Correct Daily Production Stock Out","write":true},{"key":"stock_out_delete","label":"Delete Daily Production Stock Out","write":true}]'::jsonb where page_key='reports' and not capabilities @> '[{"key":"stock_out_view"}]'::jsonb;
update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
do $$declare u record;c jsonb;k text;begin
 for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where not greenloop_private.damage_tv_only(p.id) and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p.id and r.role_key::text in ('owner','super_admin')) loop
  c:=u.caps;
  if (c->'daily_production')?'view' and not(c->'daily_production')?'stock_out_entry' then c:=jsonb_set(c,'{daily_production}',(c->'daily_production')||'["stock_out_entry"]');end if;
  if (c->'reports')?'view' then foreach k in array array['stock_out_view','stock_out_edit','stock_out_delete'] loop
   if not(c->'reports')?k then c:=jsonb_set(c,'{reports}',(c->'reports')||jsonb_build_array(k));end if;
  end loop;end if;
  update greenloop_private.user_page_capabilities set capabilities=c where user_id=u.id;
 end loop;
end;$$;

create or replace function greenloop_private.stock_out_require_reports(p_action text default null)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('reports','view') or not(public.has_page_capability_v1('reports','stock_out_view') or public.has_page_capability_v1('reports','stock_out_edit') or public.has_page_capability_v1('reports','stock_out_delete')) or (p_action is not null and not public.has_page_capability_v1('reports',p_action)) then raise exception 'Stock Out report permission required.' using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.stock_out_validate_options(p_model uuid,p_gb uuid,p_grade uuid,p_old_model uuid default null,p_old_gb uuid default null,p_old_grade uuid default null)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$begin
 perform 1 from greenloop_private.closing_stock_options where id=p_model and kind='model' and (active or id=p_old_model) for share;if not found then raise exception 'Choose an active model.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=p_gb and kind='gb' and (active or id=p_old_gb) for share;if not found then raise exception 'Choose active GB.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=p_grade and kind='grade' and (active or id=p_old_grade) for share;if not found then raise exception 'Choose an active grade.' using errcode='22023';end if;
end;$$;
create or replace function public.get_production_stock_out_context_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.closing_stock_require('stock_out_entry');
 return jsonb_build_object('current_day',greenloop_private.production_period_day(statement_timestamp())-1,'options',(select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name)),'[]') from greenloop_private.closing_stock_options o where active));
end;$$;
create or replace function public.save_production_stock_out_v1(p_request uuid,p_model uuid,p_gb uuid,p_grade uuid,p_quantity integer,p_day date)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.production_stock_out;stamp timestamptz;d date;begin
 perform greenloop_private.closing_stock_require('stock_out_entry');
 if p_request is null or p_model is null or p_gb is null or p_grade is null or p_quantity is null or p_quantity not between 1 and 1000000 or p_day is null then raise exception 'Choose Model, GB, Grade, production date and a whole Out quantity from 1 to 1,000,000.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(17920261019);perform pg_advisory_xact_lock(hashtextextended('production-out:'||p_request,0));
 select * into a from greenloop_private.production_stock_out where request_id=p_request;
 if found then
  if a.actor_id<>auth.uid() or (a.model_id,a.gb_id,a.grade_id,a.quantity,a.production_day) is distinct from (p_model,p_gb,p_grade,p_quantity,p_day) then raise exception 'This request was used for another Stock Out entry.' using errcode='22023';end if;
  if a.deleted_at is not null then raise exception 'This entry was deleted. Refresh before saving.' using errcode='22023';end if;
  return jsonb_build_object('saved',true,'id',a.id,'replayed',true);
 end if;
 stamp:=clock_timestamp();d:=greenloop_private.production_period_day(stamp)-1;
 if p_day<'2000-01-01'::date or p_day>d then raise exception 'Choose a valid production date. The new day starts at 6:00 PM UAE.' using errcode='22023';end if;
 if p_day<>d then perform greenloop_private.closing_stock_require('search');end if;
 perform greenloop_private.stock_out_validate_options(p_model,p_gb,p_grade);
 insert into greenloop_private.production_stock_out(request_id,actor_id,actor_name,recorded_at,production_day,model_id,gb_id,grade_id,quantity) values(p_request,auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),stamp,p_day,p_model,p_gb,p_grade,p_quantity) returning * into a;
 return jsonb_build_object('saved',true,'id',a.id);
end;$$;
create or replace function public.get_production_stock_out_entries_v1(p_from date,p_to date,p_query text default '',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare items jsonb;n integer;begin
 perform greenloop_private.stock_out_require_reports();
 if (p_from is distinct from date_trunc('month',(greenloop_private.production_period_day(statement_timestamp())-1)::timestamp)::date or p_to is distinct from greenloop_private.production_period_day(statement_timestamp())-1 or coalesce(p_query,'')<>'') and not public.has_page_capability_v1('reports','search') then raise exception 'Reports search permission required for custom dates or search.' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from<'2000-01-01'::date or p_to<p_from or p_to>greenloop_private.production_period_day(statement_timestamp())-1 or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 then raise exception 'Choose valid Stock Out filters.' using errcode='22023';end if;
 with f as(select a.id,a.production_day stock_date,a.recorded_at,a.actor_name,a.model_id,a.gb_id,a.grade_id,a.quantity,a.revision correction_revision,a.deleted_at is not null deleted,m.name model,b.name gb,g.name grade,l.action last_action,l.actor_name last_changed_by,l.changed_at last_changed_at from greenloop_private.production_stock_out a join greenloop_private.closing_stock_options m on m.id=a.model_id join greenloop_private.closing_stock_options b on b.id=a.gb_id join greenloop_private.closing_stock_options g on g.id=a.grade_id left join lateral(select action,actor_name,changed_at from greenloop_private.production_stock_out_changes where entry_id=a.id order by id desc limit 1) l on true where a.production_day between p_from and p_to and (btrim(coalesce(p_query,''))='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',m.name,b.name,g.name,a.actor_name,a.id::text)))>0))
 select (select count(*) from f),coalesce(jsonb_agg(to_jsonb(x) order by stock_date desc,recorded_at desc,id),'[]') into n,items from(select * from f order by stock_date desc,recorded_at desc,id offset p_offset limit 50)x;
 return jsonb_build_object('rows',items,'total',n,'options',case when public.has_page_capability_v1('reports','stock_out_edit') then (select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name)),'[]') from greenloop_private.closing_stock_options o) else '[]'::jsonb end);
end;$$;
create or replace function public.get_production_stock_out_changes_v1(p_entry uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 perform greenloop_private.stock_out_require_reports();
 if not exists(select 1 from greenloop_private.production_stock_out where id=p_entry) then raise exception 'Entry not found.' using errcode='22023';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('action',c.action,'changed_at',c.changed_at,'actor_name',c.actor_name,'old_model',om.name,'old_gb',ob.name,'old_grade',og.name,'old_quantity',(before_data->>'quantity')::integer,'old_day',before_data->>'production_day','new_model',nm.name,'new_gb',nb.name,'new_grade',ng.name,'new_quantity',(after_data->>'quantity')::integer,'new_day',after_data->>'production_day') order by c.id desc),'[]') from greenloop_private.production_stock_out_changes c left join greenloop_private.closing_stock_options om on om.id=(before_data->>'model_id')::uuid left join greenloop_private.closing_stock_options ob on ob.id=(before_data->>'gb_id')::uuid left join greenloop_private.closing_stock_options og on og.id=(before_data->>'grade_id')::uuid left join greenloop_private.closing_stock_options nm on nm.id=(after_data->>'model_id')::uuid left join greenloop_private.closing_stock_options nb on nb.id=(after_data->>'gb_id')::uuid left join greenloop_private.closing_stock_options ng on ng.id=(after_data->>'grade_id')::uuid where c.entry_id=p_entry);
end;$$;
create or replace function public.correct_production_stock_out_v1(p_entry uuid,p_expected_revision integer,p_action text,p_model uuid default null,p_gb uuid default null,p_grade uuid default null,p_quantity integer default null,p_day date default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare a greenloop_private.production_stock_out;b greenloop_private.production_stock_out;begin
 perform greenloop_private.stock_out_require_reports();
 if p_action is null or p_action not in ('edit','delete') or p_entry is null or p_expected_revision is null then raise exception 'Invalid correction request.' using errcode='22023';end if;
 perform greenloop_private.stock_out_require_reports(case when p_action='edit' then 'stock_out_edit' else 'stock_out_delete' end);
 perform pg_advisory_xact_lock(17920261019);select * into a from greenloop_private.production_stock_out where id=p_entry for update;
 if not found or a.deleted_at is not null then raise exception 'This Stock Out entry is no longer active. Refresh the report.' using errcode='22023';end if;
 if a.revision<>p_expected_revision then raise exception 'This entry changed. Refresh before saving.' using errcode='40001';end if;
 b:=a;
 if p_action='edit' then
  b.model_id:=coalesce(p_model,a.model_id);b.gb_id:=coalesce(p_gb,a.gb_id);b.grade_id:=coalesce(p_grade,a.grade_id);b.quantity:=coalesce(p_quantity,a.quantity);b.production_day:=coalesce(p_day,a.production_day);
  if b.quantity not between 1 and 1000000 or b.production_day<'2000-01-01'::date or b.production_day>greenloop_private.production_period_day(clock_timestamp())-1 then raise exception 'Choose a valid production date and whole Out quantity from 1 to 1,000,000.' using errcode='22023';end if;
  if (b.model_id,b.gb_id,b.grade_id,b.quantity,b.production_day)=(a.model_id,a.gb_id,a.grade_id,a.quantity,a.production_day) then raise exception 'No values changed.' using errcode='22023';end if;
  perform greenloop_private.stock_out_validate_options(b.model_id,b.gb_id,b.grade_id,a.model_id,a.gb_id,a.grade_id);
 else b.deleted_at:=clock_timestamp();end if;
 b.revision:=a.revision+1;
 insert into greenloop_private.production_stock_out_changes(entry_id,action,actor_id,actor_name,before_data,after_data) values(a.id,p_action,auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),to_jsonb(a),to_jsonb(b));
 update greenloop_private.production_stock_out set model_id=b.model_id,gb_id=b.gb_id,grade_id=b.grade_id,quantity=b.quantity,production_day=b.production_day,revision=b.revision,deleted_at=b.deleted_at where id=a.id;
 return jsonb_build_object('saved',true,'id',a.id,'revision',b.revision);
end;$$;

create or replace function greenloop_private.accounted_production_rows(p_from date,p_to date)
returns table(period_day date,model_id uuid,gb_id uuid,grade_id uuid,model text,gb text,grade text,opening bigint,closing bigint,stock_out bigint,production bigint,issue text)
language sql stable security definer set search_path=pg_catalog,public as $$
 with counted as (
  select greenloop_private.production_period_day(recorded_at)-1 as day,model_id,gb_id,grade_id,sum(count_quantity)::bigint quantity,1 priority from greenloop_private.closing_stock_audit where undone_at is null and greenloop_private.production_period_day(recorded_at)-1<=p_to group by 1,model_id,gb_id,grade_id
 ), snapshots as (
  select distinct on(day,model_id,gb_id,grade_id) * from (select * from counted union all select stock_date-1,model_id,gb_id,grade_id,quantity::bigint,0 from greenloop_private.closing_stock_daily where stock_source='legacy' and stock_date-1<=p_to)x order by day,model_id,gb_id,grade_id,priority desc
 ), outs as (select production_day as day,model_id,gb_id,grade_id,sum(quantity)::bigint quantity from greenloop_private.production_stock_out where deleted_at is null and production_day<=p_to group by production_day,model_id,gb_id,grade_id),
 activity as(select day,model_id,gb_id,grade_id from snapshots where day between p_from and p_to union select day,model_id,gb_id,grade_id from outs where day between p_from and p_to),
 balances as (
  select a.*,coalesce(p.quantity,0) opening,c.quantity closing,coalesce(o.quantity,0) stock_out,
   case when c.quantity is null then 'Closing count needed'
    when exists(select 1 from outs gap where gap.model_id=a.model_id and gap.gb_id=a.gb_id and gap.grade_id=a.grade_id and gap.day>coalesce(p.day,'1999-12-31'::date) and gap.day<a.day and not exists(select 1 from snapshots s where s.day=gap.day and s.model_id=gap.model_id and s.gb_id=gap.gb_id and s.grade_id=gap.grade_id)) then 'Earlier closing count needed'
    when c.quantity-coalesce(p.quantity,0)+coalesce(o.quantity,0)<0 then 'Check closing count or Stock Out' end issue
  from activity a left join snapshots c on (c.day,c.model_id,c.gb_id,c.grade_id)=(a.day,a.model_id,a.gb_id,a.grade_id)
  left join lateral(select * from snapshots s where s.model_id=a.model_id and s.gb_id=a.gb_id and s.grade_id=a.grade_id and s.day<a.day order by day desc limit 1)p on true
  left join outs o on(o.day,o.model_id,o.gb_id,o.grade_id)=(a.day,a.model_id,a.gb_id,a.grade_id)
 ) select x.day,x.model_id,x.gb_id,x.grade_id,m.name,b.name,g.name,x.opening,x.closing,x.stock_out,case when x.issue is null then x.closing-x.opening+x.stock_out end,x.issue from balances x join greenloop_private.closing_stock_options m on m.id=x.model_id join greenloop_private.closing_stock_options b on b.id=x.gb_id join greenloop_private.closing_stock_options g on g.id=x.grade_id;
$$;
create or replace function public.get_production_period_report_v3(p_from date default null,p_to date default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare stamp timestamptz:=statement_timestamp();current_day date:=greenloop_private.production_period_day(stamp)-1;d_from date;d_to date;items jsonb;stats jsonb;n integer;lim integer;begin
 perform greenloop_private.closing_stock_require('production_report');d_from:=coalesce(p_from,current_day);d_to:=coalesce(p_to,current_day);
 if d_from<>current_day or d_to<>current_day or (p_day is not null and p_day<>current_day) or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d_from<'2000-01-01'::date or d_to<d_from or d_to>current_day or d_to-d_from>366 or (p_day is not null and p_day not between d_from and d_to) or length(coalesce(p_query,''))>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in('default','date_asc','date_desc','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','production_asc','production_desc','stock_out_asc','stock_out_desc') then raise exception 'Choose a valid production date range of up to 367 days.' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 if p_day is null then
  with f as(select * from greenloop_private.accounted_production_rows(d_from,d_to) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),days as(
   select d::date as day,coalesce(sum(f.production),0)::bigint confirmed_production,case when count(f.issue)=0 then coalesce(sum(f.production),0)::bigint end production,coalesce(sum(f.stock_out),0)::bigint stock_out,count(f.issue)::integer pending_count,count(distinct f.model_id)::integer models from generate_series(d_from::timestamp,d_to::timestamp,'1 day')d left join f on f.period_day=d::date group by d
  ),ranked as(select *,row_number() over(order by case when p_sort='date_asc' then day end asc,case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='stock_out_asc' then stock_out end asc,case when p_sort='stock_out_desc' then stock_out end desc,day desc)rn from days)
  select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',case when sum(pending_count)=0 then coalesce(sum(confirmed_production),0) end,'confirmed_production',coalesce(sum(confirmed_production),0),'pending_count',coalesce(sum(pending_count),0),'stock_out',coalesce(sum(stock_out),0),'days',count(*)) from days) into n,items,stats from ranked r;
 else
  with f as(select * from greenloop_private.accounted_production_rows(p_day,p_day) where coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0),ranked as(
   select *,row_number() over(order by case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='stock_out_asc' then stock_out end asc,case when p_sort='stock_out_desc' then stock_out end desc,case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,lower(model),gb,grade,model_id,gb_id,grade_id)rn from f
  ) select (select count(*) from ranked),coalesce(jsonb_agg(to_jsonb(r)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('production',case when count(issue)=0 then coalesce(sum(production),0) end,'confirmed_production',coalesce(sum(production),0),'pending_count',count(issue),'opening',coalesce(sum(opening),0),'closing',coalesce(sum(closing),0),'stock_out',coalesce(sum(stock_out),0),'models',count(distinct model_id)) from f) into n,items,stats from ranked r;
 end if;
 if p_download and n>10000 then raise exception 'Narrow the filters to export at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('rows',items,'total',n,'stats',stats,'date_basis','start','calculation_basis','closing_plus_out','from',d_from,'to',d_to,'day',p_day,'current_day',current_day,'server_now',stamp,'current_period_end',((current_day+1)+time '18:00') at time zone 'Asia/Dubai','period_start',case when p_day is not null then (p_day+time '18:00') at time zone 'Asia/Dubai' end,'period_end',case when p_day is not null then ((p_day+1)+time '18:00') at time zone 'Asia/Dubai' end);
end;$$;

create table if not exists greenloop_private.production_stock_out_installation(identity text primary key,hash text not null);
alter table greenloop_private.production_stock_out_installation enable row level security;
revoke all on greenloop_private.production_stock_out_installation from public,anon,authenticated;
create or replace function greenloop_private.production_stock_out_schema() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select md5(jsonb_build_object('columns',(select jsonb_agg(jsonb_build_array(attrelid::regclass::text,attname,atttypid::regtype::text,attnotnull) order by attrelid,attnum) from pg_attribute where attrelid=any(array['greenloop_private.production_stock_out'::regclass,'greenloop_private.production_stock_out_changes'::regclass]) and attnum>0),'constraints',(select jsonb_agg(pg_get_constraintdef(oid) order by conrelid,conname) from pg_constraint where conrelid=any(array['greenloop_private.production_stock_out'::regclass,'greenloop_private.production_stock_out_changes'::regclass])),'trigger',(select pg_get_triggerdef(oid)||tgenabled::text from pg_trigger where tgname='production_stock_out_log_immutable'))::text);
$$;
do $$declare f record;begin for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.proname in('stock_out_require_reports','stock_out_validate_options','accounted_production_rows','get_production_stock_out_context_v1','save_production_stock_out_v1','get_production_stock_out_entries_v1','get_production_stock_out_changes_v1','correct_production_stock_out_v1','get_production_period_report_v3','production_stock_out_schema') and n.nspname in('public','greenloop_private') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.identity);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
 insert into greenloop_private.production_stock_out_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
end loop;end;$$;
insert into greenloop_private.production_stock_out_installation values('schema',greenloop_private.production_stock_out_schema()) on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_production_stock_out_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_production_start_date_version()='20261021-production-start-dates-1'
 and (select count(*)=10 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',identity,'EXECUTE') and has_function_privilege('authenticated',identity,'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.production_stock_out_installation where identity<>'schema')
 and exists(select 1 from greenloop_private.production_stock_out_installation where identity='schema' and hash=greenloop_private.production_stock_out_schema())
 and not exists(select 1 from unnest(array['greenloop_private.production_stock_out','greenloop_private.production_stock_out_changes','greenloop_private.production_stock_out_installation'])t where has_table_privilege('anon',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or not(select relrowsecurity from pg_class where oid=t::regclass))
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='daily_production' and capabilities @> '[{"key":"stock_out_entry","write":true}]')
 and exists(select 1 from greenloop_private.page_capability_catalog where page_key='reports' and capabilities @> '[{"key":"stock_out_view","write":false},{"key":"stock_out_edit","write":true},{"key":"stock_out_delete","write":true}]')
 then '20261021-production-stock-out-1' end;
$$;
revoke all on function public.get_production_stock_out_version() from public;grant execute on function public.get_production_stock_out_version() to anon,authenticated;
do $$begin if public.get_production_stock_out_version() is distinct from '20261021-production-stock-out-1' then raise exception 'Production Stock Out verification failed.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_production_stock_out_version() as installed_production_stock_out_version;
