-- Accounts stock views and mandatory export customer. Existing history is retained.
begin;
do $$ begin
 if public.get_box_workflow_version() is distinct from '20261010-box-workflow-1' then
  raise exception 'Install and verify the Box Workflow update first.';
 end if;
end; $$;
alter table greenloop_private.box_workflow add column if not exists customer_id uuid references public.customers(id) on delete restrict;
alter table greenloop_private.box_workflow add column if not exists customer_name text;
alter table greenloop_private.box_workflow add column if not exists customer_code text;
create table if not exists greenloop_private.accounts_customer_audit (
 id bigint generated always as identity primary key,customer_id uuid not null,action text not null,
 actor_id uuid not null,occurred_at timestamptz not null default now(),details jsonb not null
);
revoke all on greenloop_private.accounts_customer_audit from public,anon,authenticated;

create or replace function public.get_accounts_customers_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not greenloop_private.box_access('accounts') then raise exception 'Accounts permission required.' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',customer_code,'name',case when public.get_my_partner_name_access() then company_name end)
 order by lower(case when public.get_my_partner_name_access() then company_name else customer_code end),id)
 from public.customers where is_active and deleted_at is null),'[]');
end; $$;
create or replace function public.add_accounts_customer_v1(p_name text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_name text:=nullif(regexp_replace(btrim(p_name),'\s+',' ','g'),'');v_id uuid;v_code text;begin
 if not greenloop_private.box_access('accounts',true) or not coalesce(public.get_my_partner_name_access(),false) then raise exception 'Accounts Entry Allowed and Supplier & Customer Names access required.' using errcode='42501';end if;
 if v_name is null or length(v_name)>160 then raise exception 'Enter a customer name of 1 to 160 characters.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(16420261010);
 select id into v_id from public.customers where lower(regexp_replace(btrim(company_name),'\s+',' ','g'))=lower(v_name) and deleted_at is null order by is_active desc,created_at,id limit 1 for update;
 if v_id is null then
  loop
   v_code:='CUS-'||lpad(nextval('public.customer_number_sequence')::text,5,'0');
   exit when not exists(select 1 from public.customers where customer_code=v_code);
  end loop;
  insert into public.customers(customer_code,company_name,created_by) values(v_code,v_name,auth.uid()) returning id into v_id;
 else
  if exists(select 1 from public.customers where id=v_id and is_active) then return v_id;end if;
  update public.customers set is_active=true,updated_at=now() where id=v_id;
 end if;
 insert into greenloop_private.accounts_customer_audit(customer_id,action,actor_id,details) values(v_id,'added_to_dropdown',auth.uid(),jsonb_build_object('name',v_name));
 return v_id;
end; $$;
create or replace function public.remove_accounts_customer_v1(p_customer_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_name text;begin
 if not greenloop_private.box_access('accounts',true) or not coalesce(public.get_my_partner_name_access(),false) then raise exception 'Accounts Entry Allowed and Supplier & Customer Names access required.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(16420261010);
 select company_name into v_name from public.customers where id=p_customer_id and deleted_at is null for update;
 if not found then raise exception 'Customer not found.' using errcode='22023';end if;
 update public.customers set is_active=false,updated_at=now() where id=p_customer_id;
 insert into greenloop_private.accounts_customer_audit(customer_id,action,actor_id,details) values(p_customer_id,'removed_from_dropdown',auth.uid(),jsonb_build_object('name',v_name));
 return true;
end; $$;

-- Old browser tabs cannot bypass the new mandatory customer selection.
create or replace function public.verify_box_v1(p_box_id uuid,p_revision integer)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin raise exception 'Select a customer before verifying this box. Refresh Accounts to load the customer dropdown.' using errcode='22023';end; $$;

create or replace function public.verify_box_v2(p_box_id uuid,p_revision integer,p_customer_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare w greenloop_private.box_workflow%rowtype;b public.export_boxes%rowtype;c public.customers%rowtype;v_location uuid;begin
 if not greenloop_private.box_access('accounts',true) then raise exception 'Accounts Entry Allowed permission required to verify.' using errcode='42501';end if;
 if p_customer_id is null then raise exception 'Select a customer before verifying this box.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(16320261010);
 select * into b from public.export_boxes where id=p_box_id for update;
 select * into w from greenloop_private.box_workflow where box_id=p_box_id for update;
 if p_revision is distinct from w.revision then raise exception 'Box changed. Reload and review again.' using errcode='40001';end if;
 if w.state='exported' then
  if w.customer_id is distinct from p_customer_id then raise exception 'This box was already verified for another customer. Reload Accounts.' using errcode='40001';end if;
  return true;
 end if;
 if w.state is distinct from 'accounts' or not exists(select 1 from public.export_box_items where box_id=p_box_id) then raise exception 'Only a saved Accounts box can be verified.' using errcode='22023';end if;
 if w.printed_revision is distinct from w.revision or w.printed_at is null then raise exception 'Box was corrected. Print the updated box before verification.' using errcode='22023';end if;
 select * into c from public.customers where id=p_customer_id and is_active and deleted_at is null for share;
 if not found then raise exception 'Select an active customer. This customer is no longer available.' using errcode='22023';end if;
 select id into v_location from public.locations where location_code='OUTBOUND' and is_active;
 if v_location is null then raise exception 'Outbound location is not configured.';end if;
 update greenloop_private.box_workflow set state='exported',verified_at=now(),verified_by=auth.uid(),customer_id=c.id,customer_name=c.company_name,customer_code=c.customer_code where box_id=p_box_id;
 insert into public.device_location_history(device_id,job_id,from_location_id,to_location_id,movement_reason,notes,moved_by)
 select i.device_id,i.job_id,j.current_location_id,v_location,'Accounts verified box',b.box_number,auth.uid() from public.export_box_items i join public.jobs j on j.id=i.job_id where i.box_id=p_box_id;
 update public.jobs set current_status='shipped',current_location_id=v_location,closed_at=now(),customer_id=c.id where id in(select job_id from public.export_box_items where box_id=p_box_id);
 update public.devices set current_status='shipped',current_location_id=v_location where id in(select device_id from public.export_box_items where box_id=p_box_id);
 insert into greenloop_private.box_workflow_audit(box_id,box_number,action,actor,details) values(p_box_id,b.box_number,'verified_exported',auth.uid(),jsonb_build_object('customer_id',c.id,'customer_name',c.company_name,'customer_code',c.customer_code));
 insert into public.device_events(device_id,job_id,event_type,event_title,event_data,actor_id)
 select device_id,job_id,'box_accounts_verified','Accounts verified — Stock Exported',jsonb_build_object('box_number',b.box_number,'next_status','shipped','customer_code',c.customer_code),auth.uid() from public.export_box_items where box_id=p_box_id;
 return true;
end; $$;

-- Keep the existing box readers, masking the newly stored customer name.
do $patch$ declare v text;begin
 select pg_get_functiondef('public.get_box_workflow_v1(uuid,text)'::regprocedure) into v;
 if position('customer_name' in v)=0 then
  v:=replace(v,'to_jsonb(v_flow)','(to_jsonb(v_flow)-''customer_name'')||jsonb_build_object(''customer_name'',case when v_names then v_flow.customer_name end)');execute v;
 end if;
 select pg_get_functiondef('public.get_box_queue_v1(text,date,date,integer,integer)'::regprocedure) into v;
 if position('customer_name' in v)=0 then
  v:=replace(v,'w.verified_at,','w.verified_at,w.customer_code,case when public.get_my_partner_name_access() then w.customer_name end customer_name,');execute v;
 end if;
end;$patch$;

-- One row per receipt/model/GB/color. Unentered stock is included without
-- inventing details; plan lines supply details only for the remaining units.
create or replace function greenloop_private.accounts_supplier_rows()
returns table(supplier_id uuid,supplier_code text,supplier_name text,batch_id uuid,batch_number text,invoice_number text,received_at timestamptz,
 model text,storage_gb integer,color text,received bigint,in_company bigint,ready bigint,in_process bigint,exported bigint,returned bigint,awaiting_imei bigint)
language sql stable security definer set search_path=pg_catalog,public as $$
 with entered as materialized (
  select j.id,j.receiving_batch_id batch_id,coalesce(j.supplier_id,b.supplier_id) supplier_id,j.received_at,j.current_status::text status,
   d.model,d.storage_gb,d.color,matched.id plan_id,
   case when j.current_status::text='returned_to_supplier' then 'returned'
    when w.state in ('exported','legacy') or (w.box_id is null and j.current_status::text='shipped') then 'exported'
    when w.state in ('draft','accounts') then 'process'
    when j.current_status::text in ('qc_passed','production_pending','production_completed','ready_for_packing','ready_for_shipment')
     and exists(select 1 from public.final_qc_inspections f where f.job_id=j.id and f.result='pass') then 'ready'
    else 'process' end bucket
  from public.jobs j join public.devices d on d.id=j.device_id left join public.receiving_batches b on b.id=j.receiving_batch_id
  left join lateral(select x.* from public.stock_batch_plan_lines x where x.receiving_batch_id=j.receiving_batch_id
   and (x.model is null or lower(btrim(x.model))=lower(btrim(d.model))) and (x.storage_gb is null or x.storage_gb=d.storage_gb)
   and (x.color is null or lower(btrim(x.color))=lower(btrim(d.color)))
   order by (x.model is not null)::integer+(x.storage_gb is not null)::integer+(x.color is not null)::integer desc,x.created_at,x.id limit 1) matched on true
  left join public.export_box_items i on i.job_id=j.id left join greenloop_private.box_workflow w on w.box_id=i.box_id
  where j.deleted_at is null and d.deleted_at is null
 ), batch_totals as materialized (
  select b.*,greatest(coalesce(b.planned_quantity,0)-(select count(*) from entered e where e.batch_id=b.id)
   -(select count(*) from public.supplier_returns r where r.batch_id=b.id and r.device_id is null and r.archived_at is null and r.status='returned'),0)::bigint remaining
  from public.receiving_batches b
 ), plan_capacity as (
  select p.*,greatest(p.planned_quantity-(select count(*) from entered e where e.plan_id=p.id)
   -(select count(*) from public.supplier_returns r where r.plan_line_id=p.id and r.device_id is null and r.archived_at is null and r.status='returned'),0)::bigint capacity
  from public.stock_batch_plan_lines p
 ), plan_remaining as (
  select p.*,least(capacity,greatest(b.remaining-coalesce(sum(capacity) over(partition by p.receiving_batch_id order by p.created_at,p.id rows between unbounded preceding and 1 preceding),0),0))::bigint quantity
  from plan_capacity p join batch_totals b on b.id=p.receiving_batch_id
 ), units as (
  select e.supplier_id,e.batch_id,e.received_at,e.model,e.storage_gb,e.color,e.bucket,1::bigint quantity from entered e
  union all select b.supplier_id,b.id,b.received_at,p.model,p.storage_gb,p.color,'unentered',p.quantity from plan_remaining p join batch_totals b on b.id=p.receiving_batch_id where p.quantity>0
  union all select b.supplier_id,b.id,b.received_at,b.planned_model,null::integer,null::text,'unentered',b.remaining-coalesce((select sum(p.quantity) from plan_remaining p where p.receiving_batch_id=b.id),0)::bigint
   from batch_totals b where b.remaining>coalesce((select sum(p.quantity) from plan_remaining p where p.receiving_batch_id=b.id),0)
  union all select b.supplier_id,b.id,b.received_at,p.model,p.storage_gb,p.color,'returned',1::bigint
   from public.supplier_returns r join public.receiving_batches b on b.id=r.batch_id left join public.stock_batch_plan_lines p on p.id=r.plan_line_id
   where r.device_id is null and r.archived_at is null and r.status='returned'
 )
 select s.id,s.supplier_code,case when public.get_my_partner_name_access() then s.company_name end,b.id,b.batch_number,b.invoice_number,coalesce(b.received_at,min(u.received_at)),
  coalesce(nullif(btrim(u.model),''),'Not entered'),u.storage_gb,coalesce(nullif(btrim(u.color),''),'Not recorded'),sum(u.quantity)::bigint,
  coalesce(sum(u.quantity) filter(where bucket in ('ready','process','unentered')),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='ready'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket in ('process','unentered')),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='exported'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='returned'),0)::bigint,
  coalesce(sum(u.quantity) filter(where bucket='unentered'),0)::bigint
 from units u left join public.receiving_batches b on b.id=u.batch_id left join public.suppliers s on s.id=u.supplier_id
 group by s.id,s.supplier_code,s.company_name,b.id,b.batch_number,b.invoice_number,b.received_at,coalesce(nullif(btrim(u.model),''),'Not entered'),u.storage_gb,coalesce(nullif(btrim(u.color),''),'Not recorded');
$$;

create or replace function public.get_accounts_stock_v1(p_kind text,p_date_from date default null,p_date_to date default null,p_search text default null,p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_rows jsonb;v_result jsonb;v_names boolean:=coalesce(public.get_my_partner_name_access(),false);begin
 if not greenloop_private.box_access('accounts') then raise exception 'Accounts permission required.' using errcode='42501';end if;
 if p_kind is null or p_kind not in ('supplier','customer') or (p_date_from is null)<>(p_date_to is null) or p_date_from>p_date_to or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Select valid stock type, dates and page.' using errcode='22023';end if;
 if p_kind='supplier' then
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into v_rows from greenloop_private.accounts_supplier_rows() r
  where p_date_from is null or (r.received_at at time zone 'Asia/Dubai')::date between p_date_from and p_date_to;
 else
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into v_rows from (
   select w.box_id,b.box_number,coalesce(w.verified_at,b.closed_at) exported_at,w.state,
    coalesce(w.customer_code,c.customer_code,'Not recorded') customer_code,
    case when v_names then coalesce(w.customer_name,c.company_name,'Not recorded') end customer_name,
    coalesce(w.customer_id,c.id) customer_id,s.supplier_code,case when v_names then s.company_name end supplier_name,
    rb.invoice_number,rb.received_at,i.model,i.storage_gb,i.color,i.final_grade,count(*)::bigint quantity
   from greenloop_private.box_workflow w join public.export_boxes b on b.id=w.box_id join public.export_box_items i on i.box_id=b.id
   join public.jobs j on j.id=i.job_id left join public.receiving_batches rb on rb.id=j.receiving_batch_id
   left join public.suppliers s on s.id=coalesce(j.supplier_id,rb.supplier_id)
   left join public.customers c on c.id=coalesce(w.customer_id,j.customer_id)
   where w.state in ('exported','legacy') and (p_date_from is null or (coalesce(w.verified_at,b.closed_at) at time zone 'Asia/Dubai')::date between p_date_from and p_date_to)
   group by w.box_id,b.box_number,w.verified_at,b.closed_at,w.state,w.customer_code,c.customer_code,w.customer_name,c.company_name,w.customer_id,c.id,
    s.supplier_code,s.company_name,rb.invoice_number,rb.received_at,i.model,i.storage_gb,i.color,i.final_grade
  ) r;
 end if;
 with filtered as materialized(select value r from jsonb_array_elements(v_rows)
  where nullif(btrim(p_search),'') is null or strpos(lower(concat_ws(' ',value->>'supplier_code',value->>'supplier_name',value->>'customer_code',value->>'customer_name',value->>'invoice_number',value->>'batch_number',value->>'box_number',value->>'model',value->>'storage_gb',value->>'color')),lower(btrim(p_search)))>0),
 selected as (select r from filtered order by coalesce(r->>'exported_at',r->>'received_at') desc nulls last,r->>'supplier_code',r->>'customer_code',r->>'box_number',r->>'batch_number',r->>'model',r->>'storage_gb',r->>'color',r->>'final_grade',r->>'invoice_number' offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(r) from selected),'[]'),
 'totals',jsonb_build_object('received',coalesce((select sum((r->>'received')::bigint) from filtered),0),'in_company',coalesce((select sum((r->>'in_company')::bigint) from filtered),0),
 'ready',coalesce((select sum((r->>'ready')::bigint) from filtered),0),'in_process',coalesce((select sum((r->>'in_process')::bigint) from filtered),0),
 'exported',coalesce((select sum(coalesce(r->>'exported',r->>'quantity')::bigint) from filtered),0),'returned',coalesce((select sum((r->>'returned')::bigint) from filtered),0))) into v_result;
 return v_result;
end; $$;

revoke all on function greenloop_private.accounts_supplier_rows() from public,anon,authenticated;
do $acl$ declare n text;begin
 foreach n in array array['get_accounts_customers_v1()','add_accounts_customer_v1(text)','remove_accounts_customer_v1(uuid)','verify_box_v2(uuid,integer,uuid)','get_accounts_stock_v1(text,date,date,text,integer,integer)'] loop
  execute 'revoke all on function public.'||n||' from public,anon,authenticated';
  execute 'grant execute on function public.'||n||' to authenticated';
 end loop;
end;$acl$;
-- Refresh only the three predecessor definitions intentionally extended above.
update greenloop_private.box_workflow_installation set hash=md5(pg_get_functiondef(to_regprocedure(identity)))
 where identity in ('public.verify_box_v1(uuid,integer)','public.get_box_workflow_v1(uuid,text)','public.get_box_queue_v1(text,date,date,integer,integer)');
create table if not exists greenloop_private.accounts_stock_installation(identity text primary key,hash text not null);
revoke all on greenloop_private.accounts_stock_installation from public,anon,authenticated;
insert into greenloop_private.accounts_stock_installation select p,md5(pg_get_functiondef(to_regprocedure(p))) from unnest(array[
 'public.get_accounts_customers_v1()','public.add_accounts_customer_v1(text)','public.remove_accounts_customer_v1(uuid)','public.verify_box_v2(uuid,integer,uuid)',
 'public.verify_box_v1(uuid,integer)','public.get_box_workflow_v1(uuid,text)','public.get_box_queue_v1(text,date,date,integer,integer)',
 'public.get_accounts_stock_v1(text,date,date,text,integer,integer)','greenloop_private.accounts_supplier_rows()']) p on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_accounts_stock_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_box_workflow_version()='20261010-box-workflow-1'
 and (select count(*)=9 and bool_and(hash=md5(pg_get_functiondef(to_regprocedure(identity))) and not has_function_privilege('anon',to_regprocedure(identity),'EXECUTE')) from greenloop_private.accounts_stock_installation)
 and not has_table_privilege('authenticated','greenloop_private.accounts_customer_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and not has_table_privilege('anon','greenloop_private.accounts_customer_audit','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
 and exists(select 1 from pg_constraint where conrelid='greenloop_private.box_workflow'::regclass and contype='f' and confrelid='public.customers'::regclass and convalidated)
 then '20261010-accounts-stock-1' end;
$$;
revoke all on function public.get_accounts_stock_version() from public;
grant execute on function public.get_accounts_stock_version() to anon,authenticated;
notify pgrst,'reload schema';
commit;
select public.get_accounts_stock_version() as installed_accounts_stock_version;
