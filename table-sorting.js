(() => {
  'use strict';
  const numberKeys = new Set(('storage storage_gb memory battery battery_health quantity quantity_received quantity_requested quantity_issued total total_qty total_received stock_quantity used_in_phones damaged_quantity faulty_quantity issued_pending unit_cost stock_value total_cost price_amount total_value in_stock received in_company ready in_process exported returned awaiting_imei requested issued installed jobs_assigned jobs_completed active_hours rework_count attempt days_open planned_quantity entered_quantity pending_quantity working_count pending_count completed_today completed_month overdue_count oldest_pending_hours damage_month qc_returns_month').split(' '));
  const extras = {
    'inventory-stock-filters': ['sku','total_received','stock_quantity','used_in_phones','damaged_quantity','faulty_quantity','issued_pending','unit_cost','stock_value','last_invoice_number','last_received_at'],
    'inventory-receipt-filters': ['receipt_number','invoice_number','sku','quantity_received','total_cost','unit_cost'],
    'parts-availability-filters': ['invoice','sku','stock_quantity','unit_cost'],
    'parts-request-filters': ['imei','model','quantity_requested','quantity_issued'],
    'parts-return-filters': ['imei','invoice_number','quantity','unit_cost','total_value','returned_by_name','technician_name'],
    'stock-return-filters': ['received_at','received_quantity','returned_quantity','returned_by_name','invoice_number'],
    'lab-work-filters': ['imei','battery_health'],
    'frame-result-filters': ['imei'],
    'qc-pending-filters': ['imei'],
    'user-list-filters': ['full_name','login_username'],
    'lab-live-filters': ['pending_count','working_count','completed_today','completed_month','overdue_count','oldest_pending_hours','damage_month'],
    'dashboard-queue-filters': ['received_at','days_open'],
    'damage-history-filters': ['identifier','quantity','price_amount','total_value','reported_by','created_at'],
    'damage-correction-filters': ['identifier','quantity','price_amount','total_value','reported_by','created_at'],
    'journey-record-filters': ['date_entered','imei','device_number','device_details','date_received','date_completed','export_date','stock_channel','invoice_number','supplier_company','quantity_received','battery_health','supplier_grade','company_initial_grade','parts_issued','parts_cost','service_done','technician_name','box_number','customer_name'],
    'box-record-filters': ['box_number','quantity','saved_at','verified_at'],
    'report-stock-returns': ['received_at','returned_at','received_quantity','returned_quantity','returned_by_name'],
    'report-supplier-progress': ['supplier_code','storage_label','batch_numbers','stock_channels','planned_quantity','received_quantity','imei_entry_pending','initial_qc_pending','lab_glass_pending','parts_pending','final_qc_pending','ready_quantity','exported_quantity','other_quantity'],
    'audit-deletion-filters': ['deleted_at','record_label','deletion_method'],
    'audit-change-filters': ['changed_at','device_number','imei_before','imei_after','job_number'],
    'report-box-filters': ['boxNumber','opened_at','quantity']
  };
  const labels = {full_name:'Name',login_username:'Username',price_amount:'Price / part',total_value:'Total value',date_entered:'Date entered',created_at:'Recorded date',filter_date:'Date',quantity:'Quantity',storage_gb:'GB',storage:'GB',boxNumber:'Box number',latest:'Latest Final QC pass',total:'Total Qty'};
  const aliases = {quantity:['qty','phones'],part_name:['part','part name'],stock_quantity:['in stock'],last_received_at:['last received'],received_at:['received','stock received'],occurred_at:['date','damage date'],reviewed_at:['checked','date'],date_entered:['entry date'],filter_date:['date'],price_amount:['price','price / part'],supplier_code:['supplier code'],damaged_by:['employee','technician','damaged by'],reviewed_by_name:['checked by'],quantity_requested:['requested','required'],quantity_issued:['issued'],device_details:['device'],current_stage:['current stage'],total_cost:['total cost','cost']};
  const clean = value => String(value || '').toLowerCase().replace(/·\s*uae|[↑↓↕]/g,'').replace(/\s+/g,' ').trim();
  Object.assign(aliases,{
    unit_cost:['unit cost','average unit cost'],receipt_number:['receipt no.'],invoice_number:['invoice','invoice / receipt'],
    total_received:['total received'],used_in_phones:['used'],damaged_quantity:['damaged'],faulty_quantity:['faulty'],issued_pending:['issued / pending'],last_invoice_number:['latest invoice'],
    date_entered:['imei entered','entry date'],device_details:['model · gb · color · region','device'],date_completed:['latest final qc pass'],parts_cost:['parts cost (aed)'],imei:['imei / journey'],
    filter_date:['date','time'],received_quantity:['received qty','quantity received','imeis entered'],returned_quantity:['return stock'],returned_at:['returned','return date / reference'],
    received_at:['received','stock received','receipt / received date'],supplier_code:['supplier','supplier / code'],returned_by_name:['recorded by','returned by'],
    total_value:['total','total value'],planned_quantity:['planned'],storage_label:['gb'],batch_numbers:['batch'],stock_channels:['channel'],
    imei_entry_pending:['imei entry pending'],initial_qc_pending:['initial qc'],lab_glass_pending:['lab & glass'],parts_pending:['parts'],final_qc_pending:['final qc'],ready_quantity:['ready stock'],exported_quantity:['exported'],other_quantity:['other'],days_open:['age','days open']
  });
  const title = key => labels[key] || key.replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
  const typeOf = key => /(?:_at|_date)$|^date_/.test(key) || key==='latest' ? 'date' : numberKeys.has(key) || /(?:_count|_quantity|_cost|_value|_hours|_pending)$/.test(key) ? 'number' : 'text';
  const read = (row,key) => key.split('.').reduce((v,k)=>v?.[k],row);
  const collator = new Intl.Collator('en',{sensitivity:'base'});
  function create(id, bar, initialOptions, changed) {
    let options=initialOptions, columns=[], by='', direction='asc', busy=false;
    const group=document.createElement('div'); group.className='table-sort-controls';
    const make=(name,label) => {
      const wrap=document.createElement('label');wrap.className='table-filter-field';
      const caption=document.createElement('span');caption.textContent=label;
      const select=document.createElement('select');select.id=id+'-sort-'+name;select.dataset.searchReadOnly='';select.setAttribute('aria-label',label);
      wrap.append(caption,select);group.append(wrap);return select;
    };
    const field=make('by','Sort by'), order=make('order','Order');
    const reset=document.createElement('button');reset.className='secondary-button';reset.type='button';reset.textContent='Clear sorting';reset.dataset.searchReadOnly='';group.append(reset);
    bar.append(group);
    function current(){return columns.find(c=>c.key===by);}
    function sync(){
      field.value=by;
      const type=current()?.type;
      const names=!by?['Default order']:type==='date'?['Oldest first','Newest first']:type==='number'?['Smallest first','Largest first']:['A–Z','Z–A'];
      order.replaceChildren(...names.map((label,i)=>new Option(label,i?'desc':'asc')));order.value=direction;
      field.disabled=busy;order.disabled=busy||!by;reset.disabled=busy||!by;
    }
    async function choose(key,dir){
      if(busy || (key && !columns.some(c=>c.key===key)))return;
      by=key;direction=dir==='desc'?'desc':'asc';sync();decorate();
      await changed();
    }
    field.onchange=()=>choose(field.value,'asc');order.onchange=()=>choose(by,order.value);reset.onclick=()=>choose('','asc');
    function refresh(next=options){
      options=next;
      const definitions=options.sortFields || [
        ...(options.dateKey?[[options.dateKey,(options.dateLabel || 'Record')+' date','date']]:[]),
        ...(options.fields || []),...(extras[id] || []).map(key=>[key,title(key)])
      ];
      columns=[...new Map(definitions.map(([key,label,type])=>[key,{key,label,type:type || typeOf(key)}])).values()];
      if(by && !columns.some(c=>c.key===by)){by='';direction='asc';}
      field.replaceChildren(new Option('Default order',''),...columns.map(c=>new Option(c.label,c.key)));
      group.hidden=columns.length===0 || options.sorting===false;sync();
      queueMicrotask(decorate);
    }
    function sort(rows,project=options.project){
      const column=current();if(!column)return [...rows];
      const key=column.key, type=column.type;
      const value=row=>{
        const v=read(project?project(row):row,key);
        if(v==null || String(v).trim()==='' || v==='—')return null;
        const result=type==='number'?Number(String(v).replace(/\s*(GB|%)$/i,'').trim()):type==='date'?new Date(v).getTime():String(v).trim();
        return typeof result==='number'&&!Number.isFinite(result)?null:result;
      };
      return rows.map((row,index)=>({row,index,value:value(row)})).sort((a,b)=>{
        if(a.value===null||b.value===null)return a.value===b.value?a.index-b.index:a.value===null?1:-1;
        const cmp=type==='text'?collator.compare(a.value,b.value):a.value-b.value;
        return (direction==='desc'?-cmp:cmp)||a.index-b.index;
      }).map(item=>item.row);
    }
    function target(){const t=options.sortTarget || options.before;return typeof t==='string'?document.querySelector(t):t;}
    function decorate(){
      if(group.hidden)return;
      const root=target();if(!root)return;
      root.querySelectorAll('thead th').forEach(th=>{
        const label=th.dataset.sortLabel || th.textContent.trim();
        const column=columns.find(c=>clean(c.label)===clean(label)||clean(c.key)===clean(label)||(aliases[c.key]||[]).includes(clean(label)));
        if(!column)return;
        let button=th.querySelector('button.table-sort-heading');
        if(!button){
          if(th.querySelector('input,select,button'))return;
          th.dataset.sortLabel=label;button=document.createElement('button');button.type='button';button.className='table-sort-heading';button.dataset.searchReadOnly='';th.replaceChildren(button);
        }
        th.setAttribute('aria-sort',by===column.key?(direction==='asc'?'ascending':'descending'):'none');
        button.textContent=label+' '+(by===column.key?(direction==='asc'?'↑':'↓'):'↕');button.disabled=busy;
        button.setAttribute('aria-label','Sort by '+label);
        button.onclick=()=>choose(column.key,by===column.key&&direction==='asc'?'desc':'asc');
      });
    }
    refresh();
    return {sort,refresh,decorate,clear(){by='';direction='asc';sync();},args:()=>({p_sort_by:by||null,p_sort_direction:direction}),setBusy(value){busy=value;sync();decorate();}};
  }
  function table(id, table, rows, fields) {
    if(!table || !rows.length)return;
    const body=table.tBodies[0], elements=[...body.rows];
    if(elements.length!==rows.length)return;
    const byRow=new Map(rows.map((row,i)=>[row,elements[i]]));
    if (window.GREENLOOP_FILTERS) {
      const options = {before:table.parentElement,sortTarget:table,fields:[],sortFields:fields,searchFields:fields.map(([key])=>key),
        onChange:()=>filter.bind(rows,rows.map(row=>byRow.get(row)),options)};
      const filter = window.GREENLOOP_FILTERS.get(id,options);
      filter.bind(rows,rows.map(row=>byRow.get(row)),options);
      return filter;
    }
    const bar=document.createElement('div');bar.className='table-filters table-only-sorting';table.parentElement.before(bar);
    const sorter=create(id,bar,{sortTarget:table,sortFields:fields},()=>{
      sorter.sort(rows).forEach((row,i)=>{const el=byRow.get(row);if(body.children[i]!==el)body.insertBefore(el,body.children[i]||null);});
    });
    return sorter;
  }
  window.GREENLOOP_SORTING={create,typeOf,table};
})();
