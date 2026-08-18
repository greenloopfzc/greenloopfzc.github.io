begin;

-- One central master list for Initial QC, Laboratory, Parts and Inventory.
-- This version uses no temporary table, so it works reliably in Supabase SQL Editor.
do $$
declare
  v_part_name text;
  v_normalized_name text;
  v_existing_id uuid;
  v_saved_count integer := 0;
begin
  foreach v_part_name in array array[
    '0.51x Lens',
    '0.5 Lens',
    '0.5x Camera',
    '0.5x Lens',
    '1x Camera Empty Flex Cable',
    '1x Camera Flex With IC (JCID)',
    '1x Camera Lens',
    '1x Dot',
    '1x Lens',
    '3x Camera',
    '3x Camera Lens',
    '3x Dot',
    '5G Strip',
    'Anti Slip Silicon Mat',
    'Autosol Metal Polish',
    'Back Cover',
    'Back Cover Fixing Sticker',
    'Back Glass',
    'Back Glass Fixing Tape',
    'Battery',
    'Battery Boosting Flex',
    'Battery Boosting Strip',
    'Battery Cell',
    'Battery Fixing Tape',
    'Battery Shield',
    'Battery Tape',
    'Blade',
    'Blade No. 11',
    'Bluetooth / NFC',
    'Bluetooth Flex',
    'BMS Flex',
    'Bracket Pressure Retaining Moulds (NJLD)',
    'Bubble Bags',
    'Buttons',
    'Camera Glass',
    'Camera Lens (1x)',
    'Cell Change',
    'Charging Flex',
    'Cleaning Brush (Wooden)',
    'Cleaning Cloth',
    'Clear Adhesive Tape (Small)',
    'Clear Adhesive Tape Roll (Big)',
    'Clear Adhesive Tape Roll (Small)',
    'Clippers',
    'Clippers / Cutter',
    'CM Glass',
    'Complete Rear Camera',
    'Conductive Paste',
    'Cutting Wire',
    'Cutting Wire (Red)',
    'Dent',
    'Diagnostic Battery',
    'Display Message',
    'Down Screw',
    'Down Speaker',
    'Dr. Fone Sticker Roll',
    'Dr. Fones Printer Roll',
    'Ear Speaker',
    'Electronic Cleaner',
    'Electronic Scale',
    'Falcon 530',
    'Flash Light',
    'Frame',
    'Frames',
    'Frames / Screen Bracket',
    'Frames Screen Bracket',
    'Front Camera',
    'Glass',
    'Glass Polarizor',
    'Glue Dispenser & Needle',
    'Glue Remover - Needle Only',
    'Glue Removing Tool',
    'Gulf Thinner',
    'Housing',
    'Housing (4G)',
    'Housing (5G)',
    'Housing Accessories',
    'Housing (4G)',
    'Housing (5G)',
    'LCD',
    'LCD (DD)',
    'LCD Back Sheet',
    'LCD Back Sheet Sticker',
    'LCD Boosting Strip',
    'LCD Filters',
    'LCD Sticker',
    'LCD Testing Strip',
    'LCD Touch',
    'Lens (1x)',
    'Lens Cleaner',
    'Magnets (Large & Small)',
    'Metal Shield (Sensor)',
    'Mobile Pouch (4.5)',
    'Mobile Pouch (4.5CM)',
    'Mobile Pouch (5.5 CM)',
    'Mobile Pouch (5.5CM)',
    'Mobile Pouch 5.5 CM',
    'NFC',
    'NFC / Bluetooth',
    'OCA Cleaner Spray',
    'OCA Cleaning Nano Sponge',
    'OCA Remover Spray',
    'OCA Removing Spray',
    'Polarizer Glass',
    'Power Flex',
    'Ringer',
    'Safety Glass',
    'Scalper Blade',
    'Screen Fixing Sticker',
    'Screen Fixing Tape',
    'Screw Driver (Tri Point)',
    'Sensor',
    'Sensor Shield',
    'Shield (Battery)',
    'SIM Tray',
    'Soldering Iron Polishing Set',
    'Soldering Wire',
    'Thinner',
    'Touch',
    'TP',
    'UV Glue',
    'UV Glue LCD Polishing',
    'Vibrator',
    'Volume Flex',
    'Volume Flex / Wireless',
    'Wireless',
    'Wireless / Volume Flex'
  ]::text[]
  loop
    v_part_name := regexp_replace(btrim(v_part_name), '\s+', ' ', 'g');
    v_normalized_name := lower(v_part_name);
    v_existing_id := null;

    select entry.id
    into v_existing_id
    from public.entry_options as entry
    where entry.option_group = 'part_name'
      and lower(regexp_replace(btrim(entry.option_value), '\s+', ' ', 'g')) = v_normalized_name
    order by entry.is_active desc, entry.created_at, entry.id
    limit 1;

    if v_existing_id is not null then
      update public.entry_options
      set is_active = true,
          updated_at = now()
      where id = v_existing_id;
    else
      insert into public.entry_options (option_group, option_value, is_active)
      values ('part_name', v_part_name, true);
    end if;

    v_saved_count := v_saved_count + 1;
  end loop;

  raise notice 'Greenloop part-name list processed successfully: % supplied rows.', v_saved_count;
end;
$$;

notify pgrst, 'reload schema';

commit;

-- Independent verification: this does not depend on a temporary table.
select count(*) as total_active_part_names
from public.entry_options
where option_group = 'part_name'
  and is_active = true;
