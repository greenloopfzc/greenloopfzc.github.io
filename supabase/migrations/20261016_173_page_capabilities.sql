-- Granular page capabilities; preserve existing business data and legacy grants.
begin;
do $$ begin if public.get_strict_view_only_version() is distinct from '20261016-strict-view-only-1' then raise exception 'Install the verified Strict View Only update first.';end if;end; $$;
create table if not exists greenloop_private.page_capability_catalog(page_key text primary key,capabilities jsonb not null);
create table if not exists greenloop_private.user_page_capabilities(user_id uuid primary key references public.user_profiles(id) on delete cascade,capabilities jsonb not null,updated_by uuid,updated_at timestamptz not null default now());
create table if not exists greenloop_private.capability_rpc_rules(rpc_name text primary key,rule jsonb not null);
create table if not exists greenloop_private.capability_scope(backend_pid integer not null,transaction_id bigint not null,user_id uuid not null,depth integer not null check(depth>0),primary key(backend_pid,transaction_id));
create table if not exists greenloop_private.capability_routines(identity text primary key,implementation text not null,original_hash text not null,wrapped_hash text,kind text not null);
insert into greenloop_private.page_capability_catalog values('overview','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('stock_received','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('imei_entry','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('imei_search','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('initial_qc','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('lab_glass','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('lab_live_board','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('damage_report','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "download", "label": "View / download PDF", "write": false}, {"key": "parts_details", "label": "Show parts details", "write": false}, {"key": "original_prices", "label": "Show Original prices", "write": false}, {"key": "copy_prices", "label": "Show Copy prices", "write": false}, {"key": "payable", "label": "Show payable amounts", "write": false}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('tv_manual_entry','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('frame_department','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('parts','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "issue", "label": "Issue parts", "write": true}, {"key": "return", "label": "Return / review returned parts", "write": true}, {"key": "edit", "label": "Edit records", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('inventory','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "edit", "label": "Edit records", "write": true}, {"key": "approve", "label": "Approve / reject", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}, {"key": "delete", "label": "Delete records", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('final_qc','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}, {"key": "manage_options", "label": "Manage names & dropdown choices", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('ready_stock','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "rework", "label": "Send / assign rework", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('export_boxes','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "scan", "label": "Scan IMEIs into boxes", "write": true}, {"key": "print", "label": "Print", "write": true}, {"key": "save", "label": "Save box to Accounts", "write": true}, {"key": "delete", "label": "Delete records", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('accounts','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "supplier_stock", "label": "View Supplier Stock", "write": false}, {"key": "customer_stock", "label": "View Customer Stock", "write": false}, {"key": "verify", "label": "Verify boxes for export", "write": true}, {"key": "manage_customers", "label": "Add / remove customers", "write": true}, {"key": "print", "label": "Print", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('stock_exported','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "print", "label": "Print", "write": false}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('ready_stock_journey','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "edit", "label": "Edit records", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('reports','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "correction", "label": "IMEI / device correction", "write": true}, {"key": "box_correction", "label": "Box correction", "write": true}, {"key": "damage_correction", "label": "Damage data correction", "write": true}, {"key": "delete", "label": "Delete records", "write": true}, {"key": "reset", "label": "Reset all records", "write": true}, {"key": "damage_delete", "label": "Delete damage entries", "write": true}, {"key": "damage_reset", "label": "Reset damage report", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('supplier_returns','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "entry", "label": "New entry / workflow actions", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('supplier_return_approval','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "approve", "label": "Approve / reject", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('supplier_return_handover','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "handover", "label": "Record handover", "write": true}, {"key": "settle", "label": "Record replacement / credit / refund", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.page_capability_catalog values('user_access','[{"key": "view", "label": "View page", "write": false}, {"key": "search", "label": "Search & date filters", "write": false}, {"key": "sort", "label": "Sort records", "write": false}, {"key": "login_activity", "label": "View Login Activity", "write": false}, {"key": "create_users", "label": "Add Greenloop User", "write": true}, {"key": "manage_access", "label": "Edit users & permissions", "write": true}]'::jsonb) on conflict(page_key) do update set capabilities=excluded.capabilities;
insert into greenloop_private.capability_rpc_rules values('add_accounts_customer_v1','{"page": "accounts", "capability": "manage_customers"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_entry_option','{"any": [{"page": "final_qc", "capability": "manage_options"}, {"page": "frame_department", "capability": "manage_options"}, {"page": "imei_entry", "capability": "manage_options"}, {"page": "initial_qc", "capability": "manage_options"}, {"page": "inventory", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}, {"page": "parts", "capability": "manage_options"}, {"page": "stock_received", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_lab_service_requirement','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_lab_technician','{"any": [{"page": "initial_qc", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_manual_damage_option_v1','{"page": "tv_manual_entry", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_part_inventory','{"any": [{"page": "inventory", "capability": "entry"}, {"page": "parts", "capability": "edit"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_stock_channel','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('add_technician_roster','{"any": [{"page": "initial_qc", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('approve_part_stock_adjustment','{"page": "inventory", "capability": "approve"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('archive_manual_damage_option_v1','{"page": "tv_manual_entry", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('archive_supplier_company','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('assign_ready_stock_rework_technician','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('cancel_part_request','{"page": "parts", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('close_export_box','{"page": "export_boxes", "capability": "save"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_final_qc','{"any": [{"page": "final_qc", "capability": "entry"}, {"page": "frame_department", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_final_qc_with_final_grade','{"any": [{"page": "final_qc", "capability": "entry"}, {"page": "frame_department", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_final_qc_with_final_grade_v2','{"any": [{"page": "final_qc", "capability": "entry"}, {"page": "frame_department", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_frame_and_return_to_final_qc','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_frame_to_production','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_frame_to_ready_stock','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_frame_to_ready_stock_with_grade','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_frame_to_ready_stock_with_grade_v2','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_glass_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_initial_qc','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_initial_qc_direct_to_frame','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_initial_qc_direct_to_frame_v2','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_initial_qc_lab_first','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_initial_qc_skip_lab_parts','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_lab_technician_line','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_laboratory_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_packing','{"page": "export_boxes", "capability": "save"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_production','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_scanned_initial_qc','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_scanned_initial_qc_with_roster','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_scanned_initial_qc_with_roster_and_grades','{"page": "initial_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('complete_stock_out','{"page": "export_boxes", "capability": "save"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('consume_workshop_part_lot','{"page": "inventory", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_imei_complete_record','{"any": [{"page": "reports", "capability": "correction"}, {"page": "reports", "capability": "box_correction"}], "boxedDevice": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_manual_damage_report_v1','{"page": "reports", "capability": "damage_correction"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_manual_damage_report_v2','{"page": "reports", "capability": "damage_correction"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_manual_damage_report_v3','{"page": "reports", "capability": "damage_correction"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_manual_damage_report_v4','{"page": "reports", "capability": "damage_correction"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('correct_manual_damage_report_v5','{"page": "reports", "capability": "damage_correction"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_customer','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v1','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v2','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v3','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v4','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v5','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_manual_damage_report_v6','{"page": "tv_manual_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_part_master','{"page": "inventory", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_receiving_job','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_simple_stock_entry_batch','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_stock_entry_batch','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_stock_entry_batch_with_lines','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_stock_received_channel_job','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_stock_received_job','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_supplier','{"any": [{"page": "inventory", "capability": "manage_options"}, {"page": "stock_received", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_supplier_from_company','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_supplier_part_claim','{"page": "inventory", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_supplier_return','{"page": "supplier_returns", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('create_supplier_with_code','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_all_test_operational_data','{"page": "reports", "capability": "reset"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_entry_option','{"any": [{"page": "final_qc", "capability": "manage_options"}, {"page": "frame_department", "capability": "manage_options"}, {"page": "imei_entry", "capability": "manage_options"}, {"page": "initial_qc", "capability": "manage_options"}, {"page": "inventory", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}, {"page": "parts", "capability": "manage_options"}, {"page": "stock_received", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_export_box_by_number_with_restore','{"any": [{"page": "export_boxes", "capability": "delete"}, {"page": "reports", "capability": "delete"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_export_box_with_restore','{"any": [{"page": "export_boxes", "capability": "delete"}, {"page": "reports", "capability": "delete"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_greenloop_test_data_selectively','{"page": "reports", "capability": "reset"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_stock_channel','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_technician_roster','{"any": [{"page": "initial_qc", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('delete_unused_supplier_company','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('ensure_ready_stock_frame_rework_cycle','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('ensure_ready_stock_frame_rework_cycle_v2','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('execute_greenloop_deletion','{"dynamic": "operational_removal", "parameter": "p_scope", "all": {"page": "reports", "capability": "reset"}, "otherwise": {"page": "reports", "capability": "delete"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_accounts_stock_v1','{"dynamic": "accounts_stock", "parameter": "p_kind", "read": true, "supplier": {"page": "accounts", "capability": "supplier_stock"}, "customer": {"page": "accounts", "capability": "customer_stock"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_damage_pdf_employees_v1','{"page": "damage_report", "capability": "download", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_filter_records_v1','{"dynamic": "filter_source", "parameter": "p_source", "read": true, "accounts_supplier": {"page": "accounts", "capability": "supplier_stock"}, "accounts_customer": {"page": "accounts", "capability": "customer_stock"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_login_activity_v1','{"page": "user_access", "capability": "login_activity", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_manual_damage_export_v1','{"page": "damage_report", "capability": "download", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_manual_damage_export_v2','{"page": "damage_report", "capability": "download", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_manual_damage_export_v3','{"page": "damage_report", "capability": "download", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_manual_damage_export_v4','{"page": "damage_report", "capability": "download", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_or_create_open_export_box','{"page": "export_boxes", "capability": "scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_sorted_filter_records_v1','{"dynamic": "filter_source", "parameter": "p_source", "read": true, "accounts_supplier": {"page": "accounts", "capability": "supplier_stock"}, "accounts_customer": {"page": "accounts", "capability": "customer_stock"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_sorted_filter_records_v2','{"dynamic": "filter_source", "parameter": "p_source", "read": true, "accounts_supplier": {"page": "accounts", "capability": "supplier_stock"}, "accounts_customer": {"page": "accounts", "capability": "customer_stock"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_sorted_login_activity_v1','{"page": "user_access", "capability": "login_activity", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('get_user_page_capabilities_v1','{"page": "user_access", "capability": "view", "read": true}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('initialize_user_capabilities_v1','{"page": "user_access", "capability": "create_users"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('issue_part_request','{"page": "parts", "capability": "issue"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('mark_box_printed_v1','{"dynamic": "box_print", "parameter": "p_box_id", "draft": {"page": "export_boxes", "capability": "print"}, "accounts": {"page": "accounts", "capability": "print"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('mark_initial_qc_part_not_required','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('move_part_lot_stock','{"page": "inventory", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('pause_laboratory_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_final_qc_phone','{"page": "final_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_part_inventory_with_invoice','{"page": "inventory", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_part_stock_lot','{"page": "inventory", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_stock_batch_imei','{"page": "imei_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_stock_batch_imei_with_plan','{"page": "imei_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('receive_stock_batch_imei_with_plan_v2','{"page": "imei_entry", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('record_frame_department_result','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('record_frame_department_result_v2','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('record_frame_department_result_v3','{"page": "frame_department", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('record_part_installation','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('record_simple_stock_return','{"page": "supplier_returns", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('remove_accounts_customer_v1','{"page": "accounts", "capability": "manage_customers"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('remove_lab_technician','{"any": [{"page": "initial_qc", "capability": "manage_options"}, {"page": "lab_glass", "capability": "manage_options"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('remove_manual_damage_reports_v1','{"dynamic": "damage_removal", "parameter": "p_id", "null": {"page": "reports", "capability": "damage_reset"}, "otherwise": {"page": "reports", "capability": "damage_delete"}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('remove_supplier_from_receipts','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_additional_part','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_initial_qc_part_from_lab','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_lab_part','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_lab_part_return','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('request_part_stock_adjustment','{"page": "inventory", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('reset_greenloop_to_zero','{"page": "reports", "capability": "reset"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('resume_laboratory_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('return_lab_issued_part_v2','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('return_lab_issued_part_v3','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('return_lab_unused_part','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('return_unused_part','{"any": [{"page": "parts", "capability": "return"}, {"page": "lab_glass", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('review_initial_qc_service_from_lab','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('review_lab_part_return','{"page": "parts", "capability": "return"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('route_final_qc_pass_to_frame','{"page": "final_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('route_final_qc_pass_to_frame_v2','{"any": [{"page": "final_qc", "capability": "entry"}, {"page": "initial_qc", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('route_final_qc_pass_to_frame_v3','{"page": "final_qc", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('route_job_to_laboratory_after_parts','{"page": "parts", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_lab_technician_line','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_lab_technician_line_v2','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_stock_device_cable_details','{"any": [{"page": "imei_entry", "capability": "entry"}, {"page": "ready_stock_journey", "capability": "edit"}, {"page": "stock_received", "capability": "entry"}]}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_access','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_access_capabilities_v1','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_access_complete','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_access_with_damage_tv_v1','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_page_access','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_page_access_v2','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('save_user_partner_name_access','{"page": "user_access", "capability": "manage_access"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('scan_imei_to_export_box','{"page": "export_boxes", "capability": "scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('send_ready_stock_for_rework','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('send_ready_stock_for_rework_atomic_v2','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('set_manual_lab_parts_mode','{"page": "parts", "capability": "edit"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('set_open_export_box_capacity','{"page": "export_boxes", "capability": "scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('start_glass_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('start_laboratory_work','{"page": "lab_glass", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('start_packing','{"page": "export_boxes", "capability": "scan"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('start_production','{"page": "ready_stock", "capability": "rework"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('transfer_device_to_retail_shop','{"page": "stock_received", "capability": "entry"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('transition_supplier_return','{"dynamic": "supplier_return", "parameter": "p_action", "actions": {"approve": {"page": "supplier_return_approval", "capability": "approve"}, "reject": {"page": "supplier_return_approval", "capability": "approve"}, "handover": {"page": "supplier_return_handover", "capability": "handover"}, "settlement": {"page": "supplier_return_handover", "capability": "settle"}, "cancel": {"page": "supplier_returns", "capability": "entry"}, "request_part_return": {"page": "supplier_returns", "capability": "entry"}}}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('update_supplier_company_name','{"page": "stock_received", "capability": "manage_options"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('verify_box_v1','{"page": "accounts", "capability": "verify"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;
insert into greenloop_private.capability_rpc_rules values('verify_box_v2','{"page": "accounts", "capability": "verify"}'::jsonb) on conflict(rpc_name) do update set rule=excluded.rule;

create or replace function greenloop_private.user_capabilities(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare configured jsonb;result jsonb:='{}';p record;level text;is_owner boolean;
begin
 if not exists(select 1 from public.user_profiles where id=p_user_id) then return (select jsonb_object_agg(page_key,'[]'::jsonb) from greenloop_private.page_capability_catalog);end if;
 select capabilities into configured from greenloop_private.user_page_capabilities where user_id=p_user_id;
 select exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_user_id and r.role_key::text in ('owner','super_admin')) into is_owner;
 for p in select * from greenloop_private.page_capability_catalog loop
  select access_level into level from public.user_page_permissions where user_id=p_user_id and page_key=p.page_key;
  level:=coalesce(level,case when is_owner and p.page_key=any(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported']) then 'edit' else 'none' end);
  if level='none' then result:=result||jsonb_build_object(p.page_key,'[]'::jsonb);
  elsif configured is not null then result:=result||jsonb_build_object(p.page_key,coalesce(configured->p.page_key,'[]'::jsonb));
  else result:=result||jsonb_build_object(p.page_key,(select coalesce(jsonb_agg(c->>'key'),'[]') from jsonb_array_elements(p.capabilities) c where level='edit' or c->>'key'='view' or (p.page_key='damage_report' and c->>'key'=any(array['parts_details','original_prices','copy_prices','payable']))));end if;
 end loop;
 return result;
end; $$;
create or replace function public.has_page_capability_v1(p_page_key text,p_capability text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce(public.is_active_staff(),false) and coalesce((greenloop_private.user_capabilities(auth.uid())->p_page_key)?p_capability,false);
$$;
create or replace function public.get_my_page_capabilities_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin if not coalesce(public.is_active_staff(),false) then raise exception 'Active account required.' using errcode='42501';end if;return greenloop_private.user_capabilities(auth.uid());end; $$;
create or replace function public.get_user_page_capabilities_v1()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.has_page_capability_v1('user_access','view') or not coalesce(public.has_role(array['owner','super_admin']::public.app_role_key[]),false) then raise exception 'User Access view permission required.' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('user_id',id,'capabilities',greenloop_private.user_capabilities(id))),'[]') from public.user_profiles);
end; $$;
create or replace function greenloop_private.normalize_capabilities(p_caps jsonb)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare p record;c jsonb;normalized jsonb:='{}';permissions jsonb:='{}';selected jsonb;writable boolean;
begin
 if jsonb_typeof(p_caps) is distinct from 'object' then raise exception 'Page capabilities must be an object.' using errcode='22023';end if;
 if exists(select 1 from jsonb_object_keys(p_caps) k where not exists(select 1 from greenloop_private.page_capability_catalog where page_key=k)) then raise exception 'Unknown capability page.' using errcode='22023';end if;
 for p in select * from greenloop_private.page_capability_catalog loop
  selected:=coalesce(p_caps->p.page_key,'[]');
  if jsonb_typeof(selected)<>'array' or exists(select 1 from jsonb_array_elements(selected) v where jsonb_typeof(v)<>'string') then raise exception 'Select valid capability checkboxes for %.',p.page_key using errcode='22023';end if;
  if exists(select 1 from jsonb_array_elements_text(selected) v where not exists(select 1 from jsonb_array_elements(p.capabilities) a where a->>'key'=v)) then raise exception 'Unknown capability for %.',p.page_key using errcode='22023';end if;
  select coalesce(jsonb_agg(v order by v),'[]') into selected from(select distinct value v from jsonb_array_elements_text(selected)) d;
  if jsonb_array_length(selected)>0 and not selected?'view' then raise exception 'View page must be selected for %.',p.page_key using errcode='22023';end if;
  if p.page_key='damage_report' and selected?'payable' and not(selected?'original_prices' or selected?'copy_prices') then raise exception 'Select Original Price or Copy Price before Payable.' using errcode='22023';end if;
  normalized:=normalized||jsonb_build_object(p.page_key,selected);
  select exists(select 1 from jsonb_array_elements(p.capabilities) a where (a->>'write')::boolean and selected?(a->>'key')) into writable;
  if selected?'view' then permissions:=permissions||jsonb_build_object(p.page_key,case when writable then 'edit' else 'view' end);
  elsif p.page_key=any(array['supplier_returns','supplier_return_approval','supplier_return_handover','damage_report','tv_manual_entry','accounts','stock_exported']) then permissions:=permissions||jsonb_build_object(p.page_key,'none');end if;
 end loop;
 if not exists(select 1 from jsonb_each_text(permissions) e where e.value in ('view','edit')) then raise exception 'Select at least one page.' using errcode='22023';end if;
 return jsonb_build_object('capabilities',normalized,'permissions',permissions);
end; $$;
create or replace function greenloop_private.require_capability_rule(p_rule jsonb,p_args jsonb)
returns void language plpgsql volatile security definer set search_path=pg_catalog,public as $$
declare chosen jsonb;option jsonb;v text;state text;
begin
 if coalesce((p_rule->>'boxedDevice')::boolean,false) and not public.has_page_capability_v1('reports','correction') and not exists(select 1 from public.export_box_items where device_id=nullif(p_args->>'p_device_id','')::uuid) then raise exception 'Box Correction only applies to a device in an export box.' using errcode='42501';end if;
 if p_rule?'dynamic' then
  v:=p_args->>(p_rule->>'parameter');
  case p_rule->>'dynamic'
   when 'damage_removal' then chosen:=p_rule->case when v is null then 'null' else 'otherwise' end;
   when 'operational_removal' then chosen:=p_rule->case when v='all' then 'all' else 'otherwise' end;
   when 'supplier_return' then chosen:=p_rule->'actions'->v;
   when 'box_print' then
    -- Match mark_box_printed_v1 / close_export_box lock order. The workflow
    -- state must stay unchanged between selecting a capability and printing.
    perform pg_advisory_xact_lock(16320261010);
    perform 1 from public.export_boxes where id=nullif(v,'')::uuid for update;
    select w.state into state from greenloop_private.box_workflow w where w.box_id=nullif(v,'')::uuid for update;
    chosen:=p_rule->state;
   when 'accounts_stock' then chosen:=p_rule->v;
   when 'filter_source' then if v not in ('accounts_supplier','accounts_customer') then return;end if;chosen:=p_rule->v;
   else chosen:=null;
  end case;
  if chosen is null then raise exception 'Permission is required for this action.' using errcode='42501';end if;
  perform greenloop_private.require_capability_rule(chosen,p_args);return;
 elsif p_rule?'any' then
  for option in select * from jsonb_array_elements(p_rule->'any') loop
   if public.has_page_capability_v1(option->>'page',option->>'capability') then return;end if;
  end loop;
 elsif public.has_page_capability_v1(p_rule->>'page',p_rule->>'capability') then return;
 end if;
 raise exception 'Permission is required for this action.' using errcode='42501';
end; $$;
create or replace function greenloop_private.begin_capability(p_name text,p_args jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare r jsonb;
begin
 if exists(select 1 from greenloop_private.capability_scope where backend_pid=pg_backend_pid() and transaction_id=txid_current() and user_id=auth.uid()) then
  update greenloop_private.capability_scope set depth=depth+1 where backend_pid=pg_backend_pid() and transaction_id=txid_current();return;
 end if;
 select rule into r from greenloop_private.capability_rpc_rules where rpc_name=p_name;
 if r is null then raise exception 'Action permissions are not configured.' using errcode='42501';end if;
 perform greenloop_private.require_capability_rule(r,p_args);
 insert into greenloop_private.capability_scope values(pg_backend_pid(),txid_current(),auth.uid(),1);
end; $$;
create or replace function greenloop_private.end_capability()
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 delete from greenloop_private.capability_scope where backend_pid=pg_backend_pid() and transaction_id=txid_current() and user_id=auth.uid() and depth=1;
 update greenloop_private.capability_scope set depth=depth-1 where backend_pid=pg_backend_pid() and transaction_id=txid_current() and user_id=auth.uid();
end; $$;

-- Mutation wrappers and read masking are installed below before the new editors.
do $wrap$
declare f record;existing record;impl_name text;impl_identity text;original text;body text;args text;arg_json text;kind text;declare_result text;invoke text;finish text;
begin
 for f in select p.*,pg_get_functiondef(p.oid) ddl,p.oid::regprocedure::text identity,l.lanname,
  coalesce(r.rule->>'read','false')::boolean read_rule
  from pg_proc p join pg_language l on l.oid=p.prolang left join greenloop_private.capability_rpc_rules r on r.rpc_name=p.proname
  where p.pronamespace='public'::regnamespace and p.prokind='f'
  and p.proname not in ('save_user_access_capabilities_v1','get_user_page_capabilities_v1','initialize_user_capabilities_v1')
  and (r.rpc_name is not null or p.proname=any(array[
   'get_my_damage_tv_settings_v1','get_damage_tv_cards_v1','get_damage_tv_employee_v1','get_damage_tv_details_v1',
   'get_manual_damage_cards_v1','get_manual_damage_cards_v2','get_manual_damage_cards_v3','get_manual_damage_cards_v4','get_manual_damage_cards_v5','get_manual_damage_cards_v6',
   'get_manual_damage_employee_rows_v1','get_manual_damage_employee_rows_v2','get_manual_damage_employee_rows_v3','get_manual_damage_employee_rows_v4','get_damage_tv_summary_v1','get_damage_tv_summary_v2']))
 loop
  kind:=case when f.proname='get_my_damage_tv_settings_v1' then 'profile' when f.proname like 'get_%damage%' and f.proname<>'get_damage_pdf_employees_v1' then 'damage' when f.read_rule then 'read' else 'write' end;
  select * into existing from greenloop_private.capability_routines where identity=f.identity;
  if strpos(f.prosrc,'greenloop-capability-wrapper-20261016')>0 then
   if existing.identity is null or existing.wrapped_hash is distinct from md5(f.ddl) then raise exception 'Capability wrapper changed unexpectedly: %',f.identity;end if;continue;
  end if;
  impl_name:='cap_impl_'||md5(f.identity);
  original:=regexp_replace(f.ddl,'^(CREATE OR REPLACE FUNCTION )public\.'||f.proname||'\(',E'\\1greenloop_private.'||impl_name||'(','i');
  if original=f.ddl then raise exception 'Cannot safely preserve original RPC: %',f.identity;end if;
  execute original;
  select p.oid::regprocedure::text into impl_identity from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and p.proname=impl_name;
  execute format('revoke all on function %s from public,anon,authenticated',impl_identity);
  insert into greenloop_private.capability_routines values(f.identity,impl_identity,md5(pg_get_functiondef(to_regprocedure(impl_identity))),null,kind)
   on conflict(identity) do update set implementation=excluded.implementation,original_hash=excluded.original_hash,kind=excluded.kind;
  select coalesce(string_agg(quote_ident(f.proargnames[i]),',' order by i),'') into args from generate_series(1,f.pronargs) i;
  if f.pronargs>0 and (args='' or f.proargnames is null) then raise exception 'Named input arguments required: %',f.identity;end if;
  select case when f.pronargs=0 then '''{}''::jsonb' else 'jsonb_build_object('||string_agg(quote_literal(f.proargnames[i])||','||quote_ident(f.proargnames[i]),',' order by i)||')' end into arg_json from generate_series(1,greatest(f.pronargs,1)) i;
  if f.proretset then declare_result:='';invoke:='return query select * from greenloop_private.'||impl_name||'('||args||');';finish:='return;';
  elsif f.prorettype='void'::regtype then declare_result:='';invoke:='perform greenloop_private.'||impl_name||'('||args||');';finish:='return;';
  else declare_result:='declare result '||f.prorettype::regtype::text||';';invoke:='result:=greenloop_private.'||impl_name||'('||args||');';finish:='return result;';end if;
  if kind='write' then
   body:=declare_result||E'\nbegin\n -- greenloop-capability-wrapper-20261016\n perform greenloop_private.begin_capability('||quote_literal(f.proname)||','||arg_json||'); begin '||invoke||' exception when others then perform greenloop_private.end_capability();raise;end;perform greenloop_private.end_capability();'||finish||'end;';
  else
   body:=declare_result||E'\nbegin\n -- greenloop-capability-wrapper-20261016\n ';
   if exists(select 1 from greenloop_private.capability_rpc_rules where rpc_name=f.proname) then body:=body||'perform greenloop_private.require_capability_rule((select rule from greenloop_private.capability_rpc_rules where rpc_name='||quote_literal(f.proname)||'),'||arg_json||');';end if;
   body:=body||invoke;
   if kind='damage' then body:=body||'result:=greenloop_private.mask_damage_capabilities(result);';end if;
   if kind='profile' then body:=body||'result:=greenloop_private.capability_display(result);';end if;
   body:=body||finish||'end;';
  end if;
  if f.lanname not in ('plpgsql','sql') then raise exception 'Reviewed capability endpoint uses an unsupported language: %',f.identity;end if;
  execute regexp_replace(replace(f.ddl,f.prosrc,body),'LANGUAGE sql','LANGUAGE plpgsql','i');
  update greenloop_private.capability_routines set wrapped_hash=md5(pg_get_functiondef(f.oid)) where identity=f.identity;
 end loop;
end;
$wrap$;

create or replace function greenloop_private.capability_display(p_display jsonb)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select p_display||jsonb_build_object(
 'show_parts',coalesce((p_display->>'show_parts')::boolean,true) and public.has_page_capability_v1('damage_report','parts_details'),
 'show_original',coalesce((p_display->>'show_original')::boolean,true) and public.has_page_capability_v1('damage_report','original_prices'),
 'show_copy',coalesce((p_display->>'show_copy')::boolean,true) and public.has_page_capability_v1('damage_report','copy_prices'),
 'show_payable',public.has_page_capability_v1('damage_report','payable') and ((coalesce((p_display->>'show_original')::boolean,true) and public.has_page_capability_v1('damage_report','original_prices')) or (coalesce((p_display->>'show_copy')::boolean,true) and public.has_page_capability_v1('damage_report','copy_prices'))));
$$;
create or replace function greenloop_private.mask_damage_fields(p_value jsonb,p_display jsonb)
returns jsonb language plpgsql immutable set search_path=pg_catalog,public as $$
declare k text;v jsonb;r jsonb:='{}';original boolean:=(p_display->>'show_original')::boolean;copy boolean:=(p_display->>'show_copy')::boolean;
begin
 if jsonb_typeof(p_value)='array' then return coalesce((select jsonb_agg(greenloop_private.mask_damage_fields(value,p_display) order by ordinality) from jsonb_array_elements(p_value) with ordinality),'[]');end if;
 if jsonb_typeof(p_value)<>'object' then return p_value;end if;
 if p_value?'part_name' then p_value:=p_value||jsonb_build_object('is_lcd',lower(btrim(coalesce(p_value->>'part_name','')))='lcd');end if;
 for k,v in select * from jsonb_each(p_value) loop
  if k=any(array['model','model_id','identifier','part_name','part_name_id','part_id','reason','reason_id','part_source','part_source_id']) and not (p_display->>'show_parts')::boolean then continue;end if;
  if k='price_amount' and not original then r:=r||jsonb_build_object(k,null);continue;end if;
  if k='copy_price_amount' and not copy then r:=r||jsonb_build_object(k,null);continue;end if;
  if k=any(array['entry_total','value_totals','unpriced_quantity','payable','confirmed_payable','pending_count','pending','lcd_average','waived_value']) and not original then continue;end if;
  if k=any(array['copy_entry_total','copy_value_totals','copy_unpriced_quantity','copy_payable','copy_confirmed_payable','copy_pending_count','copy_pending','copy_lcd_average','copy_waived_value']) and not copy then continue;end if;
  if k=any(array['payable','confirmed_payable','pending_count','pending','copy_payable','copy_confirmed_payable','copy_pending_count','copy_pending']) and not (p_display->>'show_payable')::boolean then continue;end if;
  if k=any(array['currency','currency_id','amount','deduction']) and not(original or copy) then continue;end if;
  r:=r||jsonb_build_object(k,greenloop_private.mask_damage_fields(v,p_display));
 end loop;return r;
end; $$;
create or replace function greenloop_private.mask_damage_capabilities(p_result jsonb)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;
begin
 d:=public.get_my_damage_tv_settings_v1();
 return greenloop_private.mask_damage_fields(p_result,d)||jsonb_build_object('visibility',jsonb_build_object('parts_details',(d->>'show_parts')::boolean,'original_prices',(d->>'show_original')::boolean,'copy_prices',(d->>'show_copy')::boolean,'payable',(d->>'show_payable')::boolean))
 ||case when p_result?'tv_display' then jsonb_build_object('tv_display',d) else '{}'::jsonb end;
end; $$;

-- The legacy management helper required Damage Entry edit as well as Reports.
-- An explicit management tick now authorizes that operation while preserving
-- active-account, TV-only and owner-only reset restrictions. Public mutation
-- wrappers still check correction/delete/reset independently before writes.
do $management$ declare target_identity text:='greenloop_private.manual_damage_management_access(boolean,boolean)';impl text:='greenloop_private.cap_impl_damage_management_access';original text;begin
 if not exists(select 1 from greenloop_private.capability_routines where capability_routines.identity=target_identity) then
  original:=pg_get_functiondef(target_identity::regprocedure);
  execute replace(original,'FUNCTION greenloop_private.manual_damage_management_access(','FUNCTION '||impl||'(');
 end if;
end; $management$;
create or replace function greenloop_private.manual_damage_management_access(p_edit boolean default false,p_reset boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select auth.uid() is not null and coalesce(public.is_active_staff(),false) and not greenloop_private.damage_tv_only(auth.uid())
 and public.has_page_capability_v1('reports','view')
 and case when p_reset then public.has_page_capability_v1('reports','damage_reset')
 when p_edit then public.has_page_capability_v1('reports','damage_correction') or public.has_page_capability_v1('reports','damage_delete') or public.has_page_capability_v1('reports','damage_reset')
 else public.has_page_capability_v1('reports','damage_correction') or public.has_page_capability_v1('reports','damage_delete') or public.has_page_capability_v1('reports','damage_reset') or greenloop_private.manual_damage_access() or greenloop_private.damage_report_access() end
 and (not p_reset or coalesce(public.has_role(array['owner','super_admin']::public.app_role_key[]),false));
$$;
insert into greenloop_private.capability_routines values('greenloop_private.manual_damage_management_access(boolean,boolean)','greenloop_private.cap_impl_damage_management_access(boolean,boolean)',md5(pg_get_functiondef('greenloop_private.cap_impl_damage_management_access(boolean,boolean)'::regprocedure)),md5(pg_get_functiondef('greenloop_private.manual_damage_management_access(boolean,boolean)'::regprocedure)),'helper') on conflict(identity) do update set wrapped_hash=excluded.wrapped_hash;


create or replace function public.save_user_access_capabilities_v1(
 p_user_id uuid,p_full_name text,p_login_username text,p_is_active boolean,p_page_permissions jsonb,p_partner_names_access text,
 p_tv_only boolean,p_show_parts boolean,p_show_original boolean,p_show_copy boolean,p_expected_revision text,p_capabilities jsonb
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare n jsonb;caps jsonb;existing_access jsonb;
begin
 if not public.has_page_capability_v1('user_access','manage_access') then raise exception 'Manage User Access permission required.' using errcode='42501';end if;
 caps:=p_capabilities;
 if p_tv_only then
  caps:=jsonb_build_object('damage_report',to_jsonb(array_remove(array['view',case when p_show_parts then 'parts_details' end,case when p_show_original then 'original_prices' end,case when p_show_copy then 'copy_prices' end,case when p_show_original or p_show_copy then 'payable' end],null)));
 end if;
 n:=greenloop_private.normalize_capabilities(caps);
 existing_access:=coalesce(greenloop_private.user_capabilities(p_user_id)->'user_access','[]');
 if not public.has_role(array['super_admin']::public.app_role_key[]) and not(existing_access @> (n->'capabilities'->'user_access') and existing_access <@ (n->'capabilities'->'user_access')) then raise exception 'Only Super Admin can change User Access permissions.' using errcode='42501';end if;
 if p_user_id=auth.uid() and not (n->'capabilities'->'user_access')?'manage_access' then raise exception 'You cannot remove your own permission-management access.' using errcode='42501';end if;
 perform public.save_user_access_with_damage_tv_v1(p_user_id,p_full_name,p_login_username,p_is_active,n->'permissions',p_partner_names_access,p_tv_only,p_show_parts,p_show_original,p_show_copy,p_expected_revision);
 insert into greenloop_private.user_page_capabilities values(p_user_id,n->'capabilities',auth.uid(),now()) on conflict(user_id) do update set capabilities=excluded.capabilities,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 return true;
end; $$;
create or replace function public.initialize_user_capabilities_v1(p_actor_user_id uuid,p_user_id uuid,p_full_name text,p_login_username text,p_page_permissions jsonb,p_capabilities jsonb,p_partner_names_access text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare prior_sub text:=current_setting('request.jwt.claim.sub',true);n jsonb;
begin
 if not exists(select 1 from public.user_profiles where id=p_actor_user_id and is_active) or not (greenloop_private.user_capabilities(p_actor_user_id)->'user_access')?'create_users'
 or not exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id where ur.user_id=p_actor_user_id and r.role_key::text in ('owner','super_admin')) then raise exception 'Add Greenloop User permission required.' using errcode='42501';end if;
 if p_actor_user_id=p_user_id or not exists(select 1 from public.user_profiles where id=p_user_id and created_at>now()-interval '15 minutes')
 or exists(select 1 from public.user_page_permissions where user_id=p_user_id) or exists(select 1 from public.user_roles where user_id=p_user_id) then raise exception 'Only a newly created, unassigned account may be initialized.' using errcode='42501';end if;
 n:=greenloop_private.normalize_capabilities(p_capabilities);
 perform set_config('request.jwt.claim.sub',p_actor_user_id::text,true);
 perform greenloop_private.begin_capability('initialize_user_capabilities_v1','{}');
 begin
  perform public.save_user_access_complete(p_user_id,p_full_name,p_login_username,true,n->'permissions',p_partner_names_access);
  insert into greenloop_private.user_page_capabilities values(p_user_id,n->'capabilities',p_actor_user_id,now());
 exception when others then perform greenloop_private.end_capability();perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);raise;end;
 perform greenloop_private.end_capability();perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
 return true;
end; $$;
-- Only refreshed functions explicitly wrapped above are resealed in their old
-- receipts. Unrelated function hashes and all schema receipts remain unchanged.
do $receipts$
declare t record;idcol text;hashcol text;
begin
 for t in select c.oid,c.relname from pg_class c where c.relnamespace='greenloop_private'::regnamespace and c.relkind='r' and c.relname not in ('capability_routines','page_capability_installation') loop
  select case when exists(select 1 from pg_attribute where attrelid=t.oid and attname='object_identity') then 'object_identity' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='function_identity') then 'function_identity' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='identity') then 'identity' end into idcol;
  select case when exists(select 1 from pg_attribute where attrelid=t.oid and attname='definition_hash') then 'definition_hash' when exists(select 1 from pg_attribute where attrelid=t.oid and attname='hash') then 'hash' end into hashcol;
  if idcol is not null and hashcol is not null then
   execute format('update greenloop_private.%I receipt set %I=md5(pg_get_functiondef(to_regprocedure(r.identity))) from greenloop_private.capability_routines r where (case when receipt.%I like ''%%(%%'' then to_regprocedure(receipt.%I) else null end)=to_regprocedure(r.identity)',t.relname,hashcol,idcol,idcol);
  end if;
 end loop;
 update greenloop_private.login_activity_installation set definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['public.get_login_activity_access_v1()','public.touch_login_activity_v1(text,text,boolean)','public.get_login_activity_v1(text,date,date,integer,integer,bigint)']) signature);
 update greenloop_private.manual_damage_export_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_export_v1(date,date)'::regprocedure));
 update greenloop_private.damage_live_details_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v3(integer,integer,integer)'::regprocedure));
 update greenloop_private.damage_tv_polish_installation set definition_hash=md5(pg_get_functiondef('public.get_manual_damage_cards_v5(integer,integer,integer)'::regprocedure));
 update greenloop_private.damage_tv_summary_installation set definition_hash=md5(pg_get_functiondef('public.get_damage_tv_summary_v1(text,integer,integer)'::regprocedure));
 update greenloop_private.damage_employee_totals_installation set definition_hash=(select md5(string_agg(pg_get_functiondef(signature::regprocedure),E'\n' order by signature)) from unnest(array['greenloop_private.manual_damage_employee_value(uuid)','public.get_manual_damage_employee_rows_v3(uuid,integer,integer)','public.get_manual_damage_cards_v4(integer,integer,integer)']) signature);
end;
$receipts$;
do $acl$ declare r record;begin
 for r in select p.oid::regprocedure::text identity from pg_proc p where p.pronamespace='greenloop_private'::regnamespace and (p.proname like 'cap_impl_%' or p.proname=any(array['user_capabilities','normalize_capabilities','require_capability_rule','begin_capability','end_capability','capability_display','mask_damage_fields','mask_damage_capabilities'])) loop execute format('revoke all on function %s from public,anon,authenticated',r.identity);end loop;
 for r in select p.oid::regprocedure::text identity from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=any(array['has_page_capability_v1','get_my_page_capabilities_v1','get_user_page_capabilities_v1','save_user_access_capabilities_v1','initialize_user_capabilities_v1']) loop
  execute format('revoke all on function %s from public,anon,authenticated',r.identity);
  if r.identity like 'initialize_user_capabilities_v1(%' then execute format('grant execute on function %s to service_role',r.identity);else execute format('grant execute on function %s to authenticated',r.identity);end if;
 end loop;
end;
$acl$;
create table if not exists greenloop_private.page_capability_installation(identity text primary key,hash text not null);
do $$ declare t text;begin foreach t in array array['page_capability_catalog','user_page_capabilities','capability_rpc_rules','capability_scope','capability_routines','page_capability_installation'] loop execute format('alter table greenloop_private.%I enable row level security',t);execute format('revoke all on greenloop_private.%I from public,anon,authenticated',t);end loop;end; $$;
insert into greenloop_private.page_capability_installation
 select p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid)) from pg_proc p where
 (p.pronamespace='greenloop_private'::regnamespace and p.proname=any(array['user_capabilities','normalize_capabilities','require_capability_rule','begin_capability','end_capability','capability_display','mask_damage_fields','mask_damage_capabilities']))
 or(p.pronamespace='public'::regnamespace and p.proname=any(array['has_page_capability_v1','get_my_page_capabilities_v1','get_user_page_capabilities_v1','save_user_access_capabilities_v1','initialize_user_capabilities_v1']))
 on conflict(identity) do update set hash=excluded.hash;
insert into greenloop_private.page_capability_installation values
 ('catalog',(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c)),
 ('rules',(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r))
 on conflict(identity) do update set hash=excluded.hash;
create or replace function public.get_page_capabilities_version()
returns text language sql stable security definer set search_path=pg_catalog,public as $$
 select case when public.get_strict_view_only_version()='20261016-strict-view-only-1'
 and (select count(*)=13 and bool_and(to_regprocedure(identity) is not null and hash=md5(pg_get_functiondef(to_regprocedure(identity)))) from greenloop_private.page_capability_installation where identity not in ('catalog','rules'))
 and not exists(select 1 from greenloop_private.page_capability_installation where identity like 'greenloop_private.%' and (has_function_privilege('anon',to_regprocedure(identity),'EXECUTE') or has_function_privilege('authenticated',to_regprocedure(identity),'EXECUTE')))
 and not exists(select 1 from greenloop_private.capability_routines where to_regprocedure(identity) is null or to_regprocedure(implementation) is null or wrapped_hash<>md5(pg_get_functiondef(to_regprocedure(identity))) or original_hash<>md5(pg_get_functiondef(to_regprocedure(implementation))) or has_function_privilege('anon',to_regprocedure(implementation),'EXECUTE') or has_function_privilege('authenticated',to_regprocedure(implementation),'EXECUTE'))
 and exists(select 1 from greenloop_private.page_capability_installation where identity='catalog' and hash=(select md5(jsonb_agg(to_jsonb(c) order by page_key)::text) from greenloop_private.page_capability_catalog c))
 and exists(select 1 from greenloop_private.page_capability_installation where identity='rules' and hash=(select md5(jsonb_agg(to_jsonb(r) order by rpc_name)::text) from greenloop_private.capability_rpc_rules r))
 and not exists(select 1 from unnest(array['page_capability_catalog','user_page_capabilities','capability_rpc_rules','capability_scope','capability_routines','page_capability_installation']) t join pg_class c on c.oid=('greenloop_private.'||t)::regclass where not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
 and not has_function_privilege('authenticated','public.initialize_user_capabilities_v1(uuid,uuid,text,text,jsonb,jsonb,text)','EXECUTE')
 and not has_function_privilege('anon','public.initialize_user_capabilities_v1(uuid,uuid,text,text,jsonb,jsonb,text)','EXECUTE')
 and has_function_privilege('service_role','public.initialize_user_capabilities_v1(uuid,uuid,text,text,jsonb,jsonb,text)','EXECUTE')
 then '20261016-page-capabilities-1' end;
$$;
revoke all on function public.get_page_capabilities_version() from public;
grant execute on function public.get_page_capabilities_version() to anon,authenticated;
do $$ begin if public.get_page_capabilities_version() is distinct from '20261016-page-capabilities-1' then raise exception 'Page capabilities verification failed. Nothing installed.';end if;end; $$;
notify pgrst,'reload schema';
commit;
select public.get_page_capabilities_version() as installed_page_capabilities_version;

