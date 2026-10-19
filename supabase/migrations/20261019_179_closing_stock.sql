-- Daily box counts and closing-stock comparisons. Independent of IMEI/QC/export stock.
begin;
do $$begin if public.get_daily_production_version() is distinct from '20261019-daily-production-1' then raise exception 'Install the verified Daily Production update first.';end if;end;$$;
create table if not exists greenloop_private.closing_stock_installation(identity text primary key,hash text not null);
create table if not exists greenloop_private.closing_stock_options(id uuid primary key default gen_random_uuid(),kind text not null check(kind in ('model','gb','grade')),name text not null check(length(name) between 1 and 100),active boolean not null default true);
create unique index if not exists closing_stock_option_name on greenloop_private.closing_stock_options(kind,lower(name));
create table if not exists greenloop_private.closing_stock_daily(model_id uuid not null references greenloop_private.closing_stock_options,gb_id uuid not null references greenloop_private.closing_stock_options,grade_id uuid not null references greenloop_private.closing_stock_options,stock_date date not null,quantity integer not null check(quantity between 0 and 1000000),revision bigint not null default 1,stock_source text not null default 'legacy' check(stock_source in ('legacy','count')),baseline_quantity integer,updated_at timestamptz not null default clock_timestamp(),updated_by uuid,primary key(model_id,gb_id,grade_id,stock_date));
create table if not exists greenloop_private.closing_stock_audit(id bigint generated always as identity primary key,request_id uuid unique not null,actor_id uuid not null,actor_name text not null,recorded_at timestamptz not null default clock_timestamp(),model_id uuid not null,gb_id uuid not null,grade_id uuid not null,stock_date date not null,old_quantity integer,new_quantity integer not null,count_quantity integer not null check(count_quantity>=0),undone_at timestamptz,revision bigint not null);
create table if not exists greenloop_private.closing_stock_option_audit(id bigint generated always as identity primary key,option_id uuid not null,actor_id uuid not null,action text not null,recorded_at timestamptz not null default clock_timestamp());
create index if not exists closing_stock_audit_pair_day on greenloop_private.closing_stock_audit(model_id,gb_id,grade_id,stock_date) where undone_at is null;
create index if not exists closing_stock_grade_date on greenloop_private.closing_stock_daily(grade_id,stock_date desc);
-- Convert prior additions/removals to historical closing quantities once. Old ledgers remain intact.
do $migrate$ declare r record;m uuid;g uuid;model_name text;storage_name text;begin
 if not exists(select 1 from greenloop_private.closing_stock_installation where identity='migrated') then
  insert into greenloop_private.closing_stock_options(id,kind,name,active) select id,kind,name,active from greenloop_private.daily_production_options where kind='grade';
  insert into greenloop_private.closing_stock_options(kind,name) values('gb','64 GB'),('gb','128 GB'),('gb','256 GB'),('gb','512 GB'),('gb','1 TB'),('gb','2 TB') on conflict do nothing;
  create temporary table closing_migration_map(old_id uuid,model_id uuid,gb_id uuid) on commit drop;
  for r in select * from greenloop_private.daily_production_options where kind='model' loop
   storage_name:=upper(substring(r.name from '(?i)([0-9]+\s*(?:GB|TB))$'));
   model_name:=case when storage_name is null then r.name else btrim(regexp_replace(r.name,'(?i)\s*[0-9]+\s*(GB|TB)$','')) end;
   if model_name='' then model_name:=r.name;storage_name:=null;end if;
   storage_name:=case when storage_name is null then 'Not recorded' else regexp_replace(storage_name,'([0-9])\s*([GT]B)$','\1 \2') end;
   insert into greenloop_private.closing_stock_options(kind,name,active) values('model',model_name,r.active) on conflict(kind,lower(name)) do update set active=greenloop_private.closing_stock_options.active or excluded.active returning id into m;
   insert into greenloop_private.closing_stock_options(kind,name) values('gb',storage_name) on conflict(kind,lower(name)) do update set name=greenloop_private.closing_stock_options.name returning id into g;
   insert into closing_migration_map values(r.id,m,g);
  end loop;
  insert into greenloop_private.closing_stock_daily(model_id,gb_id,grade_id,stock_date,quantity)
  select model_id,gb_id,grade_id,production_date,(sum(delta) over(partition by model_id,gb_id,grade_id order by production_date))::integer from(select m.model_id,m.gb_id,e.grade_id,e.production_date,sum(case when e.kind='remove' then -e.quantity else e.quantity end) delta from greenloop_private.daily_production_entries e join closing_migration_map m on m.old_id=e.model_id group by m.model_id,m.gb_id,e.grade_id,e.production_date) x;
  insert into greenloop_private.closing_stock_installation values('migrated',clock_timestamp()::text);
 end if;
end;$migrate$;
create or replace function greenloop_private.closing_grade_key(p_id uuid) returns text language sql immutable set search_path=pg_catalog as $$select 'grade_'||translate(replace(p_id::text,'-',''),'0123456789','ghijklmnop');$$;
create or replace function greenloop_private.closing_stock_require(p_cap text) returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if greenloop_private.damage_tv_only(auth.uid()) or not public.has_page_capability_v1('daily_production','view') or not public.has_page_capability_v1('daily_production',p_cap) then raise exception 'Daily Production % permission required.',p_cap using errcode='42501';end if;
end;$$;
create or replace function greenloop_private.closing_stock_catalog() returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare caps jsonb;begin
 select '[{"key":"view","label":"Open Daily Production","write":false},{"key":"entry","label":"Daily Data Entry / Save box counts","write":true},{"key":"total_stock","label":"Total Stock report (all grades)","write":false},{"key":"manage_options","label":"Add / remove Model, GB and Grade","write":true},{"key":"search","label":"Search / Report date","write":false},{"key":"sort","label":"Sort table headings","write":false},{"key":"download","label":"Download permitted reports","write":false}]'::jsonb||coalesce(jsonb_agg(jsonb_build_object('key',greenloop_private.closing_grade_key(id),'label','Grade '||name||' report','write',false) order by lower(name)),'[]') into caps from greenloop_private.closing_stock_options where kind='grade';
 update greenloop_private.page_capability_catalog set capabilities=caps where page_key='daily_production';
 update greenloop_private.page_capability_installation set hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c) where identity='catalog';
end;$$;
select greenloop_private.closing_stock_catalog();
do $$declare r record;caps jsonb;begin
 if not exists(select 1 from greenloop_private.closing_stock_installation where identity='access_migrated') then
  for r in select id,greenloop_private.user_capabilities(id) caps from public.user_profiles loop
   if (r.caps->'daily_production')?'view' then
    select coalesce(jsonb_agg(c),'[]') into caps from jsonb_array_elements_text(r.caps->'daily_production') c where c<>'adjust';
    caps:=caps||'["total_stock"]'::jsonb||(select coalesce(jsonb_agg(greenloop_private.closing_grade_key(id)),'[]') from greenloop_private.closing_stock_options where kind='grade');
    insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(r.id,r.caps||jsonb_build_object('daily_production',caps)) on conflict(user_id) do update set capabilities=excluded.capabilities;
   end if;
  end loop;
  insert into greenloop_private.closing_stock_installation values('access_migrated',clock_timestamp()::text);
 end if;
end;$$;
create or replace function public.get_closing_stock_access_catalog_v1() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin
 if not(public.has_page_capability_v1('user_access','view') or public.has_page_capability_v1('user_access','create_users') or public.has_page_capability_v1('user_access','manage_access')) or not public.has_role(array['owner','super_admin']::public.app_role_key[]) then raise exception 'User Access permission required.' using errcode='42501';end if;
 return (select capabilities from greenloop_private.page_capability_catalog where page_key='daily_production');
end;$$;
create or replace function public.save_closing_stock_option_v1(p_kind text,p_name text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare r greenloop_private.closing_stock_options;n text:=regexp_replace(btrim(p_name),'\s+',' ','g');u record;k text;begin
 perform greenloop_private.closing_stock_require('manage_options');
 if p_kind is null or p_kind not in ('model','gb','grade') or n is null or length(n) not between 1 and 100 then raise exception 'Enter a valid Model, GB or Grade name.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(17920261019);
 select * into r from greenloop_private.closing_stock_options where kind=p_kind and lower(name)=lower(n) for update;
 if found then if r.active then return to_jsonb(r);end if;update greenloop_private.closing_stock_options set active=true where id=r.id returning * into r;
 else insert into greenloop_private.closing_stock_options(kind,name) values(p_kind,n) returning * into r;end if;
 insert into greenloop_private.closing_stock_option_audit(option_id,actor_id,action) values(r.id,auth.uid(),'add_or_restore');
 if p_kind='grade' then
  perform greenloop_private.closing_stock_catalog();k:=greenloop_private.closing_grade_key(r.id);
  for u in select p.id,greenloop_private.user_capabilities(p.id) caps from public.user_profiles p where not greenloop_private.damage_tv_only(p.id) and exists(select 1 from public.user_roles ur join public.roles ro on ro.id=ur.role_id where ur.user_id=p.id and ro.role_key::text='super_admin') loop
   if (u.caps->'daily_production')?'view' and not(u.caps->'daily_production')?k then insert into greenloop_private.user_page_capabilities(user_id,capabilities) values(u.id,u.caps||jsonb_build_object('daily_production',(u.caps->'daily_production')||jsonb_build_array(k))) on conflict(user_id) do update set capabilities=greenloop_private.user_page_capabilities.capabilities||jsonb_build_object('daily_production',(greenloop_private.user_page_capabilities.capabilities->'daily_production')||jsonb_build_array(k)) where (greenloop_private.user_page_capabilities.capabilities->'daily_production')?'view' and not(greenloop_private.user_page_capabilities.capabilities->'daily_production')?k;end if;
  end loop;
 end if;
 return to_jsonb(r);
end;$$;
create or replace function public.archive_closing_stock_option_v1(p_id uuid) returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare r greenloop_private.closing_stock_options;begin
 perform greenloop_private.closing_stock_require('manage_options');perform pg_advisory_xact_lock(17920261019);
 select * into r from greenloop_private.closing_stock_options where id=p_id for update;if not found then raise exception 'Choice not found.' using errcode='22023';end if;
 if exists(select 1 from(select distinct on(model_id,gb_id,grade_id) quantity from greenloop_private.closing_stock_daily where model_id=p_id or gb_id=p_id or grade_id=p_id order by model_id,gb_id,grade_id,stock_date desc) b where quantity>0) then raise exception 'Set the remaining stock to zero before removing this choice.' using errcode='22023';end if;
 update greenloop_private.closing_stock_options set active=false where id=p_id;
 insert into greenloop_private.closing_stock_option_audit(option_id,actor_id,action) values(p_id,auth.uid(),'archive');
end;$$;
create or replace function public.get_closing_stock_selection_v1(p_model uuid,p_gb uuid,p_grade uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare d date:=(statement_timestamp() at time zone 'Asia/Dubai')::date;begin
 perform greenloop_private.closing_stock_require('entry');
 return jsonb_build_object('date',d,'revision',coalesce((select revision from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=d),0),'counted_today',coalesce((select quantity from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=d and stock_source='count'),0),'quantity',(select quantity from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date<=d order by stock_date desc limit 1));
end;$$;
create or replace function public.save_closing_stock_v1(p_request uuid,p_model uuid,p_gb uuid,p_grade uuid,p_day date,p_quantity integer,p_revision bigint) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare d date:=(clock_timestamp() at time zone 'Asia/Dubai')::date;r greenloop_private.closing_stock_audit;v_rev bigint;v_old integer;v_count integer;v_base integer;v_source text;v_total integer;begin
 perform greenloop_private.closing_stock_require('entry');
 if p_request is null or p_model is null or p_gb is null or p_grade is null or p_quantity is null or p_quantity not between 0 and 1000000 or p_revision is null or p_revision<0 then raise exception 'Choose Model, GB, Grade and a whole quantity from 0 to 1,000,000.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-request:'||p_request,0));
 select * into r from greenloop_private.closing_stock_audit where request_id=p_request;
 if found then if r.actor_id<>auth.uid() or r.model_id<>p_model or r.gb_id<>p_gb or r.grade_id<>p_grade or r.stock_date is distinct from p_day or r.count_quantity<>p_quantity then raise exception 'This request was used for another save.' using errcode='22023';end if;if r.undone_at is not null then raise exception 'This count was undone. Save a new entry if required.' using errcode='22023';end if;return jsonb_build_object('saved',true,'replayed',true,'quantity',r.new_quantity,'box_quantity',r.count_quantity);end if;
 if p_day is distinct from d then raise exception 'The UAE date has changed. Select the stock again before saving.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=p_model and kind='model' and active for share;if not found then raise exception 'Choose an active model.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=p_gb and kind='gb' and active for share;if not found then raise exception 'Choose active GB.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=p_grade and kind='grade' and active for share;if not found then raise exception 'Choose an active grade.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-pair:'||p_model||p_gb||p_grade,0));
 select revision,quantity,stock_source,baseline_quantity into v_rev,v_count,v_source,v_base from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date=d for update;
 -- Different boxes add atomically even when two users started from the same revision.
 v_total:=case when v_source='count' then v_count else 0 end+p_quantity;
 if v_total>1000000 then raise exception 'Today''s combined count cannot exceed 1,000,000.' using errcode='22023';end if;
 if v_source='legacy' then v_base:=v_count;end if;
 select quantity into v_old from greenloop_private.closing_stock_daily where model_id=p_model and gb_id=p_gb and grade_id=p_grade and stock_date<=d order by stock_date desc limit 1;
 insert into greenloop_private.closing_stock_daily(model_id,gb_id,grade_id,stock_date,quantity,stock_source,baseline_quantity,updated_by) values(p_model,p_gb,p_grade,d,v_total,'count',v_base,auth.uid()) on conflict(model_id,gb_id,grade_id,stock_date) do update set quantity=excluded.quantity,stock_source='count',baseline_quantity=excluded.baseline_quantity,revision=greenloop_private.closing_stock_daily.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() returning revision into v_rev;
 insert into greenloop_private.closing_stock_audit(request_id,actor_id,actor_name,model_id,gb_id,grade_id,stock_date,old_quantity,new_quantity,count_quantity,revision) values(p_request,auth.uid(),coalesce((select full_name from public.user_profiles where id=auth.uid()),'Staff'),p_model,p_gb,p_grade,d,v_old,v_total,p_quantity,v_rev);
 return jsonb_build_object('saved',true,'quantity',v_total,'box_quantity',p_quantity,'revision',v_rev);
end;$$;
create or replace function public.undo_closing_stock_count_v1(p_request uuid) returns void language plpgsql security definer set search_path=pg_catalog,public as $$declare r greenloop_private.closing_stock_audit;n integer;q integer;b integer;begin
 perform greenloop_private.closing_stock_require('entry');
 perform pg_advisory_xact_lock(hashtextextended('closing-request:'||p_request,0));
 select * into r from greenloop_private.closing_stock_audit where request_id=p_request for update;
 if not found or r.actor_id<>auth.uid() then raise exception 'Only your own count can be undone.' using errcode='42501';end if;
 if r.stock_date<>(clock_timestamp() at time zone 'Asia/Dubai')::date then raise exception 'Only today''s entries can be undone.' using errcode='22023';end if;
 if r.undone_at is not null then return;end if;
 perform 1 from greenloop_private.closing_stock_options where id=r.model_id and active for share;if not found then raise exception 'Restore the model before undoing this count.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=r.gb_id and active for share;if not found then raise exception 'Restore GB before undoing this count.' using errcode='22023';end if;
 perform 1 from greenloop_private.closing_stock_options where id=r.grade_id and active for share;if not found then raise exception 'Restore the grade before undoing this count.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('closing-pair:'||r.model_id||r.gb_id||r.grade_id,0));
 select baseline_quantity into b from greenloop_private.closing_stock_daily where model_id=r.model_id and gb_id=r.gb_id and grade_id=r.grade_id and stock_date=r.stock_date for update;
 update greenloop_private.closing_stock_audit set undone_at=clock_timestamp() where id=r.id;
 select count(*),coalesce(sum(count_quantity),0) into n,q from greenloop_private.closing_stock_audit where model_id=r.model_id and gb_id=r.gb_id and grade_id=r.grade_id and stock_date=r.stock_date and undone_at is null;
 if n=0 and b is null then delete from greenloop_private.closing_stock_daily where model_id=r.model_id and gb_id=r.gb_id and grade_id=r.grade_id and stock_date=r.stock_date;
 else update greenloop_private.closing_stock_daily set quantity=case when n=0 then b else q end,stock_source=case when n=0 then 'legacy' else 'count' end,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() where model_id=r.model_id and gb_id=r.gb_id and grade_id=r.grade_id and stock_date=r.stock_date;end if;
end;$$;
-- Latest saved quantity carries forward over days without entries. Differences are computed per combination.
create or replace function greenloop_private.closing_stock_rows(p_day date) returns table(model_id uuid,gb_id uuid,grade_id uuid,model text,gb text,grade text,previous bigint,quantity bigint,production bigint,stock_out bigint) language sql stable security definer set search_path=pg_catalog,public as $$
 with latest as(select distinct on(model_id,gb_id,grade_id) * from greenloop_private.closing_stock_daily where stock_date<=p_day order by model_id,gb_id,grade_id,stock_date desc),pairs as(
 select l.*,coalesce((select quantity from greenloop_private.closing_stock_daily h where h.model_id=l.model_id and h.gb_id=l.gb_id and h.grade_id=l.grade_id and h.stock_date<p_day order by stock_date desc limit 1),0) prior from latest l)
 select p.model_id,p.gb_id,p.grade_id,m.name,b.name,g.name,p.prior::bigint,p.quantity::bigint,greatest(p.quantity-p.prior,0)::bigint,greatest(p.prior-p.quantity,0)::bigint from pairs p join greenloop_private.closing_stock_options m on m.id=p.model_id join greenloop_private.closing_stock_options b on b.id=p.gb_id join greenloop_private.closing_stock_options g on g.id=p.grade_id;
$$;
create or replace function public.get_closing_stock_home_v1() returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare d date:=(statement_timestamp() at time zone 'Asia/Dubai')::date;cards jsonb;opts jsonb;tot jsonb;begin
 perform greenloop_private.closing_stock_require('view');
 select coalesce(jsonb_agg(jsonb_build_object('id',grade_id,'name',grade,'quantity',qty,'capability',greenloop_private.closing_grade_key(grade_id)) order by lower(grade)),'[]') into cards from(select grade_id,grade,sum(quantity) qty from greenloop_private.closing_stock_rows(d) where public.has_page_capability_v1('daily_production',greenloop_private.closing_grade_key(grade_id)) group by grade_id,grade) x;
 if public.has_page_capability_v1('daily_production','entry') or public.has_page_capability_v1('daily_production','manage_options') then select coalesce(jsonb_agg(to_jsonb(o) order by kind,lower(name)),'[]') into opts from greenloop_private.closing_stock_options o;else opts:='[]';end if;
 if public.has_page_capability_v1('daily_production','total_stock') then select jsonb_build_object('quantity',coalesce(sum(quantity),0),'production',coalesce(sum(production),0),'stock_out',coalesce(sum(stock_out),0)) into tot from greenloop_private.closing_stock_rows(d);end if;
 return jsonb_build_object('today',d,'cards',cards,'options',opts,'total',tot);
end;$$;
create or replace function public.get_closing_stock_report_v1(p_scope text,p_grade uuid default null,p_day date default null,p_query text default '',p_sort text default 'default',p_offset integer default 0,p_download boolean default false) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$declare d date:=coalesce(p_day,(statement_timestamp() at time zone 'Asia/Dubai')::date);v_rows jsonb;v_stats jsonb;v_total integer;lim integer;begin
 perform greenloop_private.closing_stock_require('view');
 if p_scope='total' then perform greenloop_private.closing_stock_require('total_stock');elsif p_scope='grade' and p_grade is not null then perform greenloop_private.closing_stock_require(greenloop_private.closing_grade_key(p_grade));else raise exception 'Choose a valid stock report.' using errcode='22023';end if;
 if p_day is not null or coalesce(p_query,'')<>'' then perform greenloop_private.closing_stock_require('search');end if;
 if p_sort is distinct from 'default' then perform greenloop_private.closing_stock_require('sort');end if;
 if p_download then perform greenloop_private.closing_stock_require('download');end if;
 if d<'2000-01-01'::date or length(p_query)>100 or p_offset is null or p_offset<0 or p_download is null or p_sort is null or p_sort not in ('default','model_asc','model_desc','gb_asc','gb_desc','grade_asc','grade_desc','previous_asc','previous_desc','quantity_asc','quantity_desc','production_asc','production_desc','stock_out_asc','stock_out_desc') then raise exception 'Invalid report filters.' using errcode='22023';end if;
 if d>(statement_timestamp() at time zone 'Asia/Dubai')::date then raise exception 'Future report dates are not available.' using errcode='22023';end if;
 lim:=case when p_download then 10000 else 50 end;
 with f as(select * from greenloop_private.closing_stock_rows(d) where (p_scope='total' or grade_id=p_grade) and (coalesce(p_query,'')='' or position(lower(btrim(p_query)) in lower(concat_ws(' ',model,gb,grade)))>0)),n as(select *,row_number() over(order by
 case when p_sort='model_desc' then lower(model) end desc,case when p_sort='gb_asc' then gb end asc,case when p_sort='gb_desc' then gb end desc,case when p_sort='grade_asc' then grade end asc,case when p_sort='grade_desc' then grade end desc,
 case when p_sort='previous_asc' then previous end asc,case when p_sort='previous_desc' then previous end desc,case when p_sort='quantity_asc' then quantity end asc,case when p_sort='quantity_desc' then quantity end desc,case when p_sort='production_asc' then production end asc,case when p_sort='production_desc' then production end desc,case when p_sort='stock_out_asc' then stock_out end asc,case when p_sort='stock_out_desc' then stock_out end desc,lower(model),gb,grade,model_id,gb_id,grade_id) rn from f)
 select (select count(*) from f),coalesce(jsonb_agg(to_jsonb(n)-'rn' order by rn) filter(where rn>p_offset and rn<=p_offset+lim),'[]'),(select jsonb_build_object('previous',coalesce(sum(previous),0),'quantity',coalesce(sum(quantity),0),'production',coalesce(sum(production),0),'stock_out',coalesce(sum(stock_out),0)) from f) into v_total,v_rows,v_stats from n;
 if p_download and v_total>10000 then raise exception 'Narrow the filters to download at most 10,000 rows.' using errcode='22023';end if;
 return jsonb_build_object('date',d,'today',(statement_timestamp() at time zone 'Asia/Dubai')::date,'rows',v_rows,'total',v_total,'stats',v_stats);
end;$$;
-- Retire old additive endpoints so cached pages cannot modify or expose the old all-grade register.
create or replace function public.record_daily_production_v1(p_request_id uuid,p_model_id uuid,p_grade_id uuid,p_date date,p_kind text,p_quantity integer,p_note text default '') returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin raise exception 'Daily Production now uses closing stock. Refresh this page with Ctrl+F5.' using errcode='0A000';end;$$;
create or replace function public.get_daily_production_v1(p_view text default 'stock',p_filters jsonb default '{}',p_sort text default 'default',p_offset integer default 0,p_download boolean default false) returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$begin raise exception 'Daily Production now uses grade reports. Refresh this page with Ctrl+F5.' using errcode='0A000';end;$$;
create or replace function public.save_daily_production_option_v1(p_kind text,p_name text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$begin raise exception 'Refresh Daily Production with Ctrl+F5 before changing options.' using errcode='0A000';end;$$;
create or replace function public.archive_daily_production_option_v1(p_id uuid) returns void language plpgsql security definer set search_path=pg_catalog,public as $$begin raise exception 'Refresh Daily Production with Ctrl+F5 before changing options.' using errcode='0A000';end;$$;
update greenloop_private.daily_production_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity))) where identity<>'installed_at';
do $acl$declare t text;f record;begin
 foreach t in array array['closing_stock_installation','closing_stock_options','closing_stock_daily','closing_stock_audit','closing_stock_option_audit'] loop execute format('alter table greenloop_private.%I enable row level security',t);execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);end loop;
 revoke all on sequence greenloop_private.closing_stock_audit_id_seq,greenloop_private.closing_stock_option_audit_id_seq from public,anon,authenticated;
 for f in select p.oid::regprocedure::text identity,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','greenloop_private') and p.proname in ('closing_grade_key','closing_stock_require','closing_stock_catalog','closing_stock_rows','get_closing_stock_access_catalog_v1','save_closing_stock_option_v1','archive_closing_stock_option_v1','get_closing_stock_selection_v1','save_closing_stock_v1','get_closing_stock_home_v1','get_closing_stock_report_v1','undo_closing_stock_count_v1','record_daily_production_v1','get_daily_production_v1','save_daily_production_option_v1','archive_daily_production_option_v1') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.identity);if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.identity);end if;
  insert into greenloop_private.closing_stock_installation values(f.identity,md5(pg_get_functiondef(to_regprocedure(f.identity)))) on conflict(identity) do update set hash=excluded.hash;
 end loop;
end;$acl$;
create or replace function public.get_closing_stock_version() returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_daily_production_version()='20261019-daily-production-1'
 and (select count(*)=16 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') and has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')=(identity not like 'greenloop_private.%')) from greenloop_private.closing_stock_installation where identity not in ('migrated','access_migrated'))
 and not exists(select 1 from pg_class where relnamespace='greenloop_private'::regnamespace and relname in ('closing_stock_installation','closing_stock_options','closing_stock_daily','closing_stock_audit','closing_stock_option_audit') and(not relrowsecurity or has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')))
 then '20261019-closing-stock-1' end;
$$;
revoke all on function public.get_closing_stock_version() from public;grant execute on function public.get_closing_stock_version() to anon,authenticated;
do $$begin if public.get_closing_stock_version() is distinct from '20261019-closing-stock-1' then raise exception 'Closing Stock verification failed. Installation rolled back.';end if;end;$$;
notify pgrst,'reload schema';commit;
select public.get_closing_stock_version() as installed_closing_stock_version;
