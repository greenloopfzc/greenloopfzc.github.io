/* Page actions are explicit grants. Database checks remain authoritative. */
(() => {
  'use strict';
  const current = () => window.GREENLOOP_PAGE_ACCESS?.pageKey || '';
  const catalog = () => window.GREENLOOP_PERMISSION_CATALOG?.byPage || {};
  const grants = () => window.GREENLOOP_CAPABILITIES || {};
  function pageKeys(page, capability) {
    if (page === 'manual_damage_report') return capability === 'view' ? ['damage_report','tv_manual_entry'] : ['damage_report'];
    if (page === 'supplier_returns') {
      if (capability === 'approve') return ['supplier_return_approval'];
      if (['handover','settle'].includes(capability)) return ['supplier_return_handover'];
      if (['view','search','sort'].includes(capability)) return ['supplier_returns','supplier_return_approval','supplier_return_handover'];
    }
    return [page];
  }
  window.GREENLOOP_CAN = (capability, page = current()) => pageKeys(page,capability).some(key => Array.isArray(grants()[key]) && grants()[key].includes(capability));
  window.GREENLOOP_HAS_WRITE = (page = current()) => {
    const keys = page === 'manual_damage_report' ? ['tv_manual_entry'] : page === 'supplier_returns' ? ['supplier_returns','supplier_return_approval','supplier_return_handover'] : [page];
    return keys.some(key => (catalog()[key]?.capabilities || []).some(cap => cap.write && window.GREENLOOP_CAN(cap.key,key)));
  };
  const writePattern = /^(add_|apply_|approve_|archive_|assign_|cancel_|close_|complete_|confirm_|consume_|correct_|create_|delete_|ensure_|execute_|finish_|issue_|mark_|move_|verify_|pause_|receive_|record_|remove_|request_|reset_|restore_|resume_|return_|review_|route_|save_|scan_|send_|set_|start_|transfer_|transition_|update_|get_or_create_)/;
  function allowedRule(rule) {
    if (!rule) return false;
    if (rule.any) return rule.any.some(allowedRule);
    if (Array.isArray(rule.all)) return rule.all.every(allowedRule);
    return window.GREENLOOP_CAN(rule.capability || rule.cap,rule.page || current());
  }
  window.GREENLOOP_RPC_CAPABILITY = (name,args={}) => {
    const map=window.GREENLOOP_RPC_CAPABILITIES || window.GREENLOOP_RPC_CAPABILITY_MAP || {};
    let rule=map[name] || map.rpc?.[name];
    if (typeof rule === 'function') rule=rule(args,current());
    if (rule?.dynamic) {
      const value=args[rule.parameter];
      if (rule.dynamic==='operational_removal') rule=value==='all'?rule.all:rule.otherwise;
      else if (rule.dynamic==='damage_removal') rule=value==null?rule.null:rule.otherwise;
      else if (rule.dynamic==='supplier_return') rule=rule.actions[value] || {page:current(),capability:'__unknown_action__'};
      else if (rule.dynamic==='daily_production_entry') rule=value==='remove'?rule.remove:rule.add;
      else if (rule.dynamic==='production_correction') rule=rule[value] || {page:'reports',capability:'__unknown_action__'};
      else if (rule.dynamic==='box_print') rule=current()==='accounts'?rule.accounts:rule.draft;
      else if (rule.dynamic==='accounts_stock') rule=rule[value] || {page:'accounts',capability:'__unknown_section__'};
      else if (rule.dynamic==='filter_source') rule=rule[value] || {page:current(),capability:'view'};
    }
    if (rule) return rule;
    // Unknown writes fail closed instead of inheriting another action's grant.
    return writePattern.test(name) ? {page:current(),capability:'__unmapped_write__'} : null;
  };
  window.GREENLOOP_RPC_ALLOWED = (name,args) => { const rule=window.GREENLOOP_RPC_CAPABILITY(name,args);return !rule || allowedRule(rule); };
  window.GREENLOOP_CAPABILITY_ALLOWED = allowedRule;
  window.GREENLOOP_TABLE_WRITE_ALLOWED = (table,method) => {
    const page=current();
    const capability=/supplier|customer|entry_option|technician/.test(table) ? (page==='accounts'?'manage_customers':'manage_options') : method==='delete'?'delete':method==='insert'?'entry':'edit';
    return window.GREENLOOP_CAN(capability,page);
  };
  const fieldSelector='input:not([type="hidden"]),select,textarea,[contenteditable]';
  const actionSelector='button,input[type="submit"],input[type="button"],input[type="reset"],a[role="button"],[role="button"],a[download]';
  const controls=fieldSelector+','+actionSelector;
  const readSelectors='.history-receipt-device,[data-user-id],#user-access-home,#refresh-ready-stock,#refresh-journey,#tv-mode,#full-board-view,#auto-technician-view,#queue-count,.cdd-retry,[data-technician-id],[data-export-box],[data-audit-details-index],[data-audit-view],[data-back-box],[data-return-report],[data-dm-audit],[data-dm-audit-refresh],[data-dm-home],[data-close-pending],.report-tab,[data-access-section="greenloop-accounts"],[data-sr-detail],[data-sr-close],[data-sr-back],[data-close-box],[data-open-box],[data-view-imei-stage],[data-receipt-more],[data-open-deleted-history],#damage-pdf-close,#open-menu,#close-menu,#global-logout,.module-link';
  const searchContainers='.table-filters,.ready-stock-filters,.global-imei-search,.search-panel,#greenloop-quick-imei-scanner,#report-filter,#box-queue-filter,#accounts-stock-filter,#journey-search-form,#login-activity-filters,#imei-search-form,.sr-report-search,.dm-search,.lab-live-filters';
  const choiceControls='.master-add,.master-remove,[data-add-choice],[data-remove-choice],[data-option-action],#add-lab-technician,#remove-lab-technician,#add-supplier,#remove-supplier,#save-supplier,#supplier-dialog,#contact-dialog,#damage-option-dialog,#add-part-name,#remove-part-name';
  function rule(capability,page) {return {capability,page:page || current()};}
  function targetRule(control) {
    if (!control || control.matches('input[type="hidden"]')) return null;
    // Opening controls or switching the visible table does not grant its edits.
    if (control.matches('.table-filter-toggle,.table-filter-close,.frame-view-tab,.gl-work-tab,.gl-header-search-close') || control.closest('.table-filter-pagination')) return null;
    if (control.matches('[data-gl-appearance]')) return {any:[rule('theme','appearance'),rule('display_mode','appearance')]};
    if (control.closest('#gl-appearance-settings')) {
      if (control.matches('.gl-settings-close,.gl-settings-done')) return null;
      if (control.matches('input[name="gl-design"]')) return rule('theme','appearance');
      if (control.matches('input[name="gl-mode"]')) return rule('display_mode','appearance');
      return rule('__unknown_appearance_control__','appearance');
    }
    const explicit=control.closest('[data-capability]');
    if (explicit) return rule(explicit.dataset.capability,explicit.dataset.capabilityPage);
    const page=current(),id=control.id || '',label=(control.getAttribute('aria-label') || control.textContent || control.value || '').trim();
    if (control.closest('.pc-shell')) {
      if (control.matches('[data-pc-action="restore"],[data-pc-restore-confirm]')) return rule('production_restore','reports');
      if (control.matches('[data-pc-action="edit"]') || control.closest('.pc-edit')) return rule('production_edit','reports');
      if (control.matches('[data-pc-action="delete"],[data-pc-confirm]')) return rule('production_delete','reports');
      return {any:[rule('production_view','reports'),rule('production_edit','reports'),rule('production_delete','reports'),rule('production_restore','reports'),rule('production_delete_all','reports')]};
    }
    if (control.closest('#dp-dates')) return rule('date_report','daily_production');
    if (control.matches('.table-sort-controls *,.table-sort-controls,[data-sort-key],.table-sort-button') || control.closest('.table-sort-controls') || /^Sort by /.test(label)) return rule('sort');
    if (control.matches('#damage-pdf-toggle,#damage-pdf-view,#damage-pdf-download,#damage-pdf-file,#damage-pdf-open')) return rule('download','damage_report');
    if (control.closest('#damage-pdf-form') && control.matches(fieldSelector)) return rule('search','damage_report');
    if (control.matches('[data-accounts-view="supplier"]')) return rule('supplier_stock','accounts');
    if (control.matches('[data-accounts-view="customer"]')) return rule('customer_stock','accounts');
    if (control.matches('[data-accounts-view="verify"]')) return rule('view','accounts');
    if (control.matches('[data-access-section="login-activity"],.login-activity-link')) return rule('login_activity','user_access');
    if (control.matches('[data-access-section="add-greenloop-user"]') || control.closest('#create-user-form')) return rule('create_users','user_access');
    if (control.closest('#access-editor')) return rule('manage_access','user_access');
    if (control.matches('[data-print-box],[data-sr-print],#print-box-sheet,#confirm-box-print,[data-confirm-print]') || /^Print(?:ing)?\b/i.test(label)) return rule('print');
    if (control.matches('a[download]') || /^Download\b/i.test(label)) return rule('download');
    if (control.matches(readSelectors)) return null;
    if (control.matches('[data-delete-export-box]')) return rule('delete','reports');
    if (control.matches('#start-packing')) return rule('scan','export_boxes');
    if (control.matches('#packing-job-select')) return {any:[rule('scan','export_boxes'),rule('save','export_boxes')]};
    if (control.matches('#stock-out-job-select') || control.closest('#packing-form,#stock-out-form')) return rule('save','export_boxes');
    if (control.matches('#delete-export-box')) return rule('delete','export_boxes');
    if (control.matches('#start-next-box')) return rule(/Start next/i.test(label)?'scan':'save','export_boxes');
    if (control.matches('#export-imei')) return rule('scan','export_boxes');
    if (control.matches('[data-verify-box]')) return rule('verify','accounts');
    if (control.matches('#box-customer')) return {any:[rule('verify','accounts'),rule('manage_customers','accounts')]};
    if (control.matches('[data-add-box-customer],[data-remove-box-customer]')) return rule('manage_customers','accounts');
    if (control.matches('[data-add-requirement],[data-remove-requirement],[data-add-choice],[data-remove-choice]')) return rule('entry');
    if (control.matches('[data-add-technician],[data-remove-technician],[data-add-grade],[data-remove-grade]')) return rule('manage_options');
    if (control.matches(choiceControls) || control.closest('#supplier-dialog,#contact-dialog,#damage-option-dialog')) return rule('manage_options');
    if (control.matches('#inventory-name') && page==='parts') return {any:[rule('edit'),rule('manage_options')]};
    if (control.matches('.manual-damage-choice select,.master-option-control select,.inventory-master-control select,[data-final-grade],[data-carry-field="technician"]')) return {any:[rule('entry'),rule('manage_options')]};
    if (control.matches('[data-dm-mode="correct"]')) return rule('damage_correction','reports');
    if (control.matches('[data-dm-mode="remove"]')) return {any:[rule('damage_delete','reports'),rule('damage_reset','reports')]};
    if (control.matches('[data-dm-scope="single"]')) return rule('damage_delete','reports');
    if (control.matches('[data-dm-scope="all"],[data-dm-preview-all]')) return rule('damage_reset','reports');
    if (control.closest('#dm-correction-form')) return rule('damage_correction','reports');
    if (control.closest('#dm-removal-form')) return rule(document.querySelector('[data-dm-scope="all"][aria-pressed="true"]')?'damage_reset':'damage_delete','reports');
    if (control.matches('[data-dm-select]')) return rule(/^Correct/i.test(label)?'damage_correction':'damage_delete','reports');
    const deletion=control.closest('[data-deletion-card],[data-deletion-review],[data-deletion-confirm]');
    if (deletion) return rule((deletion.dataset.deletionCard || deletion.dataset.deletionReview || deletion.dataset.deletionConfirm)==='all'?'reset':'delete','reports');
    if (control.matches('[data-box-correction],[data-box-correct-imei]')) return rule('box_correction','reports');
    if (control.closest('#correction-save-form,#correction-search-form')) return rule(document.querySelector('[data-back-box]')?'box_correction':'correction','reports');
    if (control.matches('[data-issue-request],[data-inventory-request],[data-quantity-request]')) return rule('issue','parts');
    if (control.matches('[data-cancel-request]')) return rule('edit','parts');
    if (control.matches('[data-review-return]')) return rule('return','parts');
    if (control.matches('#manual-lab-parts-toggle')) return rule('edit','parts');
    if (control.closest('#ready-stock-rework-form') || /^ready-stock-rework|^bulk-rework|^rework-|^ready-rework/.test(id)) return rule('rework','ready_stock');
    if (control.matches('#save-journey-cable-details,#save-cable-details,#connect-device,#disconnect-device') && page==='ready_stock_journey') return rule('edit','ready_stock_journey');
    if (control.matches('[data-sr-action]')) {const action=control.dataset.srAction;return /approve|reject/.test(action)?rule('approve','supplier_return_approval'):/handover/.test(action)?rule('handover','supplier_return_handover'):/settle|credit|refund|replacement/.test(action)?rule('settle','supplier_return_handover'):rule('entry','supplier_returns');}
    if (control.closest('[data-sr-create],.sr-request-form')) return rule('entry','supplier_returns');
    if (!control.matches(fieldSelector) && !/^View all$/i.test(label) && /^(view(?:\s|$)|show (?:more|details|history|records)|open (?:box|report|damage report|details|history)|refresh(?:\s|$)|reload(?:\s|$)|previous(?:\s|$)|next(?:\s|$)|back(?:\s|$)|close(?:\s|$)|cancel$|dismiss(?:\s|$)|logout$|sign out$)/i.test(label)) return null;
    if (control.closest(searchContainers) || control.matches('input[type="search"],[data-sr-report-search],#technician-imei-scan,#check-technician-imei') || /^(Search|Find|Clear filters|All dates|Apply date range)\b/i.test(label)) return rule('search');
    if (page==='reports') return rule('correction');
    if (page==='parts') return rule(control.closest('#inventory-form')?'edit':'issue');
    if (page==='export_boxes') return rule('scan');
    if (page==='accounts') return rule('verify');
    if (page==='user_access') return rule('manage_access');
    return rule('entry');
  }
  window.GREENLOOP_CONTROL_CAPABILITY=targetRule;
  window.GREENLOOP_ENFORCE_CAPABILITIES = main => {
    const blocked=control=>{const required=targetRule(control);return required && !allowedRule(required);};
    function lock(control) {
      if (!blocked(control)) return;
      if ('disabled' in control && !control.disabled) control.disabled=true;
      if (control.hasAttribute('contenteditable') && control.getAttribute('contenteditable')!=='false') control.setAttribute('contenteditable','false');
      if (control.getAttribute('aria-disabled')!=='true') control.setAttribute('aria-disabled','true');
      if (control.dataset.viewOnlyLocked!=='true') control.dataset.viewOnlyLocked='true';
      if (control.title!=='Access not granted') control.title='Access not granted';
    }
    function sweep(root=document){if(root.matches?.(controls))lock(root);root.querySelectorAll?.(controls).forEach(lock);}
    if (!window.GREENLOOP_HAS_WRITE() && main && !main.querySelector('.view-only-access-banner')) {
      const badge=document.createElement('div');badge.className='view-only-access-banner';badge.setAttribute('role','status');badge.innerHTML='<span class="view-only-access-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v3"/></svg></span><span>View Only Access</span>';(main.querySelector('.page-content')||main).prepend(badge);
    }
    sweep();
    new MutationObserver(changes=>{const roots=new Set();changes.forEach(change=>{roots.add(change.target);change.addedNodes.forEach(node=>{if(node.nodeType===1)roots.add(node);});});roots.forEach(sweep);}).observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['disabled','contenteditable','type','data-capability','data-capability-page']});
    const stop=event=>{event.preventDefault();event.stopImmediatePropagation();};
    ['click','dblclick','beforeinput','input','change','paste','cut','drop','search'].forEach(type=>window.addEventListener(type,event=>{const control=event.target.closest?.(controls);if(blocked(control)){lock(control);stop(event);}},true));
    window.addEventListener('keydown',event=>{const control=event.target.closest?.(controls);if(blocked(control)&&!['Tab','Escape'].includes(event.key)&&!(event.ctrlKey||event.metaKey)){lock(control);stop(event);}},true);
    window.addEventListener('submit',event=>{const control=event.submitter || event.target.querySelector('button[type="submit"],input[type="submit"]');const required=control?targetRule(control):targetRule(event.target);if(!control||required&&!allowedRule(required))stop(event);},true);
    window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS=sweep;
  };
})();
