-- Keep Recheck corrections in the existing guarded workflow and expose the box capacity.
begin;
set local lock_timeout='5s';

do $install$
declare
  target record;
  private_fn regprocedure;
  before_definition text;
  after_definition text;
  previous_hash text;
  next_hash text;
begin
  for target in select * from (values
    ('public.get_box_entry_review_v1(uuid)', 'review', $review$declare b public.export_boxes%rowtype;w greenloop_private.box_workflow%rowtype;items jsonb;names boolean;$review$),
    ('public.add_box_recheck_imei_v1(uuid,integer,text)', 'add', 'recheck_imei_added'),
    ('public.remove_box_recheck_imei_v1(uuid,integer,uuid)', 'remove', 'recheck_imei_removed')
  ) as targets(signature,kind,anchor) loop
    select to_regprocedure(o.implementation) into strict private_fn
    from greenloop_private.office_routines o
    where to_regprocedure(o.identity)=to_regprocedure(target.signature);

    before_definition:=pg_get_functiondef(private_fn);
    previous_hash:=md5(before_definition);
    if not exists(select 1 from greenloop_private.office_routines o
      where to_regprocedure(o.identity)=to_regprocedure(target.signature)
        and o.original_hash=previous_hash
        and o.wrapped_hash=md5(pg_get_functiondef(to_regprocedure(target.signature)))) then
      raise exception 'Existing Box Recheck definition differs for %.',target.signature;
    end if;
    if strpos(before_definition,'-- recheck-imei-controls-372')>0 then continue;end if;
    after_definition:=replace(before_definition,chr(13),'');
    if strpos(after_definition,target.anchor)=0 then raise exception 'Box Recheck entry differs for %.',target.signature;end if;

    if target.kind='review' then
      after_definition:=replace(after_definition,$old$'box_number',b.box_number,'state'$old$,
        $next$'box_number',b.box_number,'capacity',b.capacity,'state'$next$);
      after_definition:=replace(after_definition,'i.id,i.serial_no,i.imei,i.model,','i.id,i.serial_no,i.imei,d.imei_2,i.model,');
      if strpos(after_definition,'''capacity'',b.capacity')=0 or strpos(after_definition,'d.imei_2')=0 then
        raise exception 'Box review row layout differs.';
      end if;
    else
      after_definition:=replace(after_definition,$old$;perform greenloop_private.lock_box_recheck(p_box_id,p_revision);$old$,
        ';'||chr(10)||' perform greenloop_private.lock_box_recheck(p_box_id,p_revision);'||chr(10)||
        ' perform greenloop_private.begin_capability('||quote_literal(split_part(split_part(target.signature,'(',1),'.',2))||',''{}'');');
      after_definition:=replace(after_definition,';return true;', ';perform greenloop_private.end_capability();return true;');
      if strpos(after_definition,'greenloop_private.begin_capability')=0 or strpos(after_definition,'greenloop_private.end_capability')=0 then
        raise exception 'Box Recheck action boundaries differ for %.',target.signature;
      end if;

      if target.kind='add' then
        after_definition:=replace(after_definition,'bnum text;cap integer;', 'bnum text;cap integer;existing_box text;');
        after_definition:=replace(after_definition,$old$if exists(select 1 from public.export_box_items where imei=p_imei) then raise exception 'This IMEI is already in an export box.' using errcode='23505';end if;$old$,$next$
 select b.box_number into existing_box from public.export_box_items i
 join public.export_boxes b on b.id=i.box_id
 where i.device_id in (select id from public.devices where imei_1=p_imei and deleted_at is null)
    or i.imei=p_imei
 order by (i.imei=p_imei) desc,i.id limit 1;
 if existing_box is not null then
   raise exception 'This IMEI is already in %. Open that box to review it first.',existing_box using errcode='22023';
 end if;$next$);
        after_definition:=replace(after_definition,'This box has reached its capacity.', 'This box is full. Remove an IMEI first, then add the replacement.');
        if strpos(after_definition,'into existing_box')=0 or strpos(after_definition,'Remove an IMEI first')=0 then
          raise exception 'Box Recheck add checks differ.';
        end if;
      end if;
    end if;

    after_definition:=regexp_replace(after_definition,'\mbegin\M','begin'||chr(10)||' -- recheck-imei-controls-372');
    execute after_definition;
    next_hash:=md5(pg_get_functiondef(private_fn));
    update greenloop_private.office_routines o set original_hash=next_hash
      where to_regprocedure(o.implementation)=private_fn and original_hash=previous_hash;
    update greenloop_private.qc_direct_ready_installation q set hash=next_hash
      where to_regprocedure(q.identity)=private_fn and q.hash=previous_hash;
  end loop;
end;
$install$;

create or replace function public.get_box_recheck_imei_controls_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $version$
  select case when (select count(*)=3 and bool_and(
       o.original_hash=md5(pg_get_functiondef(to_regprocedure(o.implementation)))
       and strpos(pg_get_functiondef(to_regprocedure(o.implementation)),'-- recheck-imei-controls-372')>0
       and not has_function_privilege('authenticated',to_regprocedure(o.implementation),'EXECUTE'))
      from greenloop_private.office_routines o where to_regprocedure(o.identity) in (
        'public.get_box_entry_review_v1(uuid)'::regprocedure,
        'public.add_box_recheck_imei_v1(uuid,integer,text)'::regprocedure,
        'public.remove_box_recheck_imei_v1(uuid,integer,uuid)'::regprocedure))
    then '20261125-box-recheck-imei-controls-1' end;
$version$;
revoke all on function public.get_box_recheck_imei_controls_version() from public,anon,authenticated;
grant execute on function public.get_box_recheck_imei_controls_version() to anon,authenticated;

do $verify$ begin
  if public.get_box_recheck_imei_controls_version() is distinct from '20261125-box-recheck-imei-controls-1' then
    raise exception 'The Box Recheck IMEI update could not be verified.';
  end if;
end; $verify$;
notify pgrst,'reload schema';
commit;
select public.get_box_recheck_imei_controls_version() as installed_box_recheck_imei_controls_version;
