-- Add receipt categories; no workflow, record, permission or stock changes.
begin;
lock table public.stock_channels in share row exclusive mode;
do $channels$
declare wanted text;chosen uuid;
begin
 foreach wanted in array array['Repair Stock','RMA Stock']loop
  select c.id into chosen from public.stock_channels c
  where lower(regexp_replace(btrim(c.channel_name),'[[:space:]]+',' ','g'))=lower(wanted)
  order by c.is_active desc,c.created_at,c.id limit 1;
  if chosen is null then
   insert into public.stock_channels(channel_name,is_active,created_by)values(wanted,true,auth.uid());
  else
   update public.stock_channels set is_active=true where id=chosen;
  end if;
 end loop;
 if exists(select 1 from unnest(array['Repair Stock','RMA Stock'])n where not exists(select 1 from public.stock_channels c where lower(regexp_replace(btrim(c.channel_name),'[[:space:]]+',' ','g'))=lower(n)and c.is_active))then
  raise exception 'Stock channel installation was not verified.';
 end if;
end;$channels$;
commit;
select '20261027-stock-channels-1'::text as installed_stock_channels_version;
