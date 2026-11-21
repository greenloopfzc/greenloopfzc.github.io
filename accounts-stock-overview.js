(() => {
  'use strict';
  const panel=document.querySelector('#accounts-overview-panel');
  if(!panel)return;
  const $=selector=>panel.querySelector(selector);
  const downloads=window.GREENLOOP_REPORT_DOWNLOADS;
  const can=cap=>window.GREENLOOP_CAN?.(cap,'accounts')===true;
  const allowed=()=>!stopped&&can('view')&&can('supplier_stock');
  const modes={
    in:{label:'In Stock',metrics:[['original_received','Original received'],['replacement_received','Replacement received'],['total_received','Total received']]},
    out:{label:'Out Stock',metrics:[['exported','Exported'],['supplier_returned','Returned to supplier'],['outside_chaman','Outside Greenloop (Chaman)'],['total_out','Total out']]},
    balance:{label:'Balance Stock',metrics:[['in_company','In company'],['ready','Ready Stock'],['in_process','In process'],['receipt_balance','Receipt balance (incl. exports & Chaman)']]}
  };
  const phoneHeaders=['S.No','IMEI','Model','GB','Color','Grade','Status','Supplier','Stock / Batch','Invoice'];
  const fields=['Supplier','Stock / Batch','Invoice','Date received'];
  const filterIds=['supplier','batch','invoice'];
  const toggle=document.querySelector('[data-accounts-view="overview"]');
  let mode='in',visible=false,details=null,offset=0,catalogue=null,report=null,phoneReport=null,query=null;
  let read=null,exportJob=null,stopped=false;
  const canExport=()=>can('imei_data')&&can('imei_download')&&can('print');

  panel.innerHTML='<div class="aso-heading"><h2>Stock Overview</h2><button type="button" class="secondary-button" id="aso-refresh" data-capability="supplier_stock" data-capability-page="accounts">Refresh</button></div>'+
    '<nav class="aso-modes" aria-label="Stock Overview sections">'+Object.entries(modes).map(([key,s])=>'<button type="button" class="secondary-button" data-aso-mode="'+key+'" aria-pressed="'+(key===mode)+'" data-capability="supplier_stock" data-capability-page="accounts">'+s.label+'</button>').join('')+'</nav>'+
    '<div class="aid-primary" id="aso-filters">'+[['supplier','Supplier','All suppliers'],['batch','Stock / Batch','All batches'],['invoice','Invoice','All invoices']].map(([key,label,all])=>'<label>'+label+'<select id="aso-'+key+'" data-capability="search" data-capability-page="accounts"><option value="">'+all+'</option></select></label>').join('')+'</div>'+
    '<div class="aid-toolbar aso-toolbar"><div class="aso-view-actions">'+
    '<button type="button" class="primary-button" id="aso-view" aria-controls="aso-details" aria-expanded="false" data-capability="supplier_stock" data-capability-page="accounts">View Table</button>'+
    '<button type="button" class="primary-button" id="aso-phones" aria-controls="aso-details" aria-expanded="false" data-capability="imei_data" data-capability-page="accounts">View IMEI Data</button></div>'+
    '<form id="aso-search" class="aso-search" role="search" hidden><label for="aso-imei">Search IMEI</label><input type="search" id="aso-imei" placeholder="IMEI 1 or IMEI 2" inputmode="numeric" autocomplete="off" data-capability="search" data-capability-page="accounts">'+
    '<button type="submit" class="secondary-button" data-capability="search" data-capability-page="accounts">Search</button><button type="button" id="aso-clear-imei" class="secondary-button" data-capability="search" data-capability-page="accounts" hidden>Clear</button></form>'+
    '<div class="aid-export-actions" id="aso-exports"></div></div>'+
    '<p id="aso-status" role="status" hidden></p><h3 class="greenloop-stock-heading" id="aso-summary-title">In Stock</h3><div class="aso-summary" id="aso-summary"></div>'+
    '<section id="aso-details" aria-label="Stock details" hidden><p id="aso-phone-note" hidden></p><div class="aid-table-wrap" tabindex="0" role="region" aria-label="Stock details table"><table class="aid-table" data-preserve-table-layout><thead></thead><tbody></tbody></table></div>'+
    '<div class="aid-footer"><span id="aso-count" aria-live="polite"></span><div><button type="button" class="secondary-button" id="aso-prev" data-capability="supplier_stock" data-capability-page="accounts">Previous</button><button type="button" class="secondary-button" id="aso-next" data-capability="supplier_stock" data-capability-page="accounts">Next</button></div></div></section>';

  const element=id=>$('#aso-'+id);
  const number=n=>n==null?'Not recorded':n.toLocaleString('en-GB');
  const metricKeys=()=>modes[mode].metrics.map(([key])=>key);
  const textCell=value=>value??'Not recorded';
  const current=()=>visible&&allowed();
  const filterValues=()=>filterIds.map(id=>can('search')?element(id).value:'');
  const args=()=>{const [supplier,batch,invoice]=filterValues();return {p_mode:mode,p_supplier_id:supplier||null,p_batch_id:batch||null,p_invoice_number:invoice||null};};
  const scope=()=>filterIds.map(id=>element(id).selectedOptions[0]?.textContent).filter(Boolean).join(' · ');
  const supplierName=r=>window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true?r.supplier_name:null;
  function supplierLabel(r,includeQuantity){
    const code=r.supplier_code||'';
    if(includeQuantity)return window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(code,r.receipt_quantity,supplierName(r),'Not recorded')||code||'Not recorded';
    return [code,supplierName(r)].filter(Boolean).join(' ')||'Not recorded';
  }
  function batchLabel(r){
    if(!r.batch_number)return 'Not recorded';
    if(r.receipt_quantity==null)return r.batch_number;
    return r.batch_number.replace(/-\(\d+\)$/,'')+'-('+r.receipt_quantity+')';
  }
  function status(message='',isError=false){
    const p=element('status');p.hidden=!message;p.textContent=message;p.classList.toggle('is-error',isError);
  }
  function controls(){
    const selected=details==='imei'?phoneReport:report;
    toggle.hidden=!allowed();
    element('filters').hidden=!can('search');
    panel.querySelectorAll('select').forEach(select=>{select.disabled=!catalogue||!can('search');});
    element('search').hidden=!can('imei_data')||!can('search');
    element('clear-imei').hidden=!query&&!element('imei').value;
    element('refresh').disabled=Boolean(read);
    element('phones').hidden=!can('imei_data');
    for(const [id,view,label] of [['view','receipt','Table'],['phones','imei','IMEI Data']]){
      const button=element(id);
      button.disabled=!report||Boolean(read);
      button.textContent=(details===view?'Hide ':'View ')+label;
      button.setAttribute('aria-expanded',String(details===view));
    }
    element('prev').disabled=!selected||Boolean(read)||offset===0;
    element('next').disabled=!selected||Boolean(read)||offset+50>=selected.total;
    element('exports').hidden=!canExport();
    panel.querySelectorAll('[data-aso-export]').forEach(button=>{
      button.disabled=!report||!report.total||!canExport()||Boolean(read||exportJob);
    });
  }
  function clearDetails(){
    element('details').hidden=true;
    element('phone-note').hidden=true;
    $('thead').replaceChildren();$('tbody').replaceChildren();element('count').textContent='';
  }
  function clearReport(){
    report=null;phoneReport=null;element('summary').replaceChildren();clearDetails();
  }
  function fillSelect(select,options,value=select.value){
    const first=new Option(select.options[0].textContent,'');
    select.replaceChildren(first,...options.map(([value,label])=>new Option(label,value)));
    select.value=options.some(([v])=>v===value)?value:'';
  }
  function pickOptions(reset=false){
    if(!catalogue)return;
    const suppliers=new Map(catalogue.filter(r=>r.supplier_id).map(r=>[r.supplier_id,supplierLabel(r,false)]));
    fillSelect(element('supplier'),[...suppliers].sort((a,b)=>a[1].localeCompare(b[1],'en',{numeric:true})),reset?'':element('supplier').value);
    const supplier=element('supplier').value;
    const receipts=catalogue.filter(r=>!supplier||r.supplier_id===supplier);
    const invoice=reset?'':element('invoice').value;
    fillSelect(element('batch'),receipts.filter(r=>!invoice||r.invoice_number===invoice)
      .map(r=>[r.batch_id,[batchLabel(r),r.invoice_number,supplierLabel(r,true)].filter(Boolean).join(' · ')]),reset?'':element('batch').value);
    const batch=element('batch').value;
    const invoices=[...new Set(receipts.filter(r=>!batch||r.batch_id===batch).map(r=>r.invoice_number).filter(Boolean))];
    fillSelect(element('invoice'),invoices.sort((a,b)=>a.localeCompare(b,'en',{numeric:true})).map(v=>[v,v]),invoice);
  }
  function valid(data,requestedMode,start,size){
    if(data?.mode!==requestedMode||data.offset!==start||!Number.isSafeInteger(data.total)||data.total<0||
      !/^[a-f0-9]{32}$/.test(data.snapshot)||!Array.isArray(data.rows)||data.rows.length!==Math.max(0,Math.min(size,data.total-start))||
      !data.summary||new Set(data.rows.map(row=>row.batch_id)).size!==data.rows.length)throw Error('Stock Overview data could not be verified. Refresh and try again.');
    const keys=modes[requestedMode].metrics.map(([key])=>key);
    const isQuantity=(value,key)=>value===null||(Number.isSafeInteger(value)&&(value>=0||key==='receipt_balance'));
    if((data.total&&keys.some(key=>!isQuantity(data.summary[key],key)))||
      data.rows.some(row=>!row.batch_id||keys.some(key=>!isQuantity(row[key],key))))throw Error('Stock quantities could not be verified. Refresh and try again.');
    return data;
  }
  function headers(){
    return ['S.No',...fields,...modes[mode].metrics.map(([,label])=>label)];
  }
  function rowCells(r,index,format){
    return [index+1,supplierLabel(r,true),batchLabel(r),textCell(r.invoice_number),downloads.date(r.received_at),
      ...metricKeys().map(key=>format?number(r[key]):r[key]??'Not recorded')];
  }
  function phoneCells(r,index){
    return [index+1,r.imei,textCell(r.model),r.storage_gb==null?'Not recorded':r.storage_gb+' GB',
      textCell(r.color),textCell(r.grade),r.status,supplierLabel(r,true),batchLabel(r),textCell(r.invoice_number)];
  }
  function validPhones(data,requested,start,size){
    if(data?.mode!==requested||data.offset!==start||!Number.isSafeInteger(data.total)||data.total<0||
      !/^[a-f0-9]{32}$/.test(data.snapshot)||!Array.isArray(data.rows)||data.rows.length!==Math.max(0,Math.min(size,data.total-start))||
      new Set(data.rows.map(row=>row.row_key)).size!==data.rows.length||
      data.rows.some(row=>!row.row_key||!/^\d{15}$/.test(row.imei)||!row.status)){
      throw Error('The IMEI list could not be verified. Refresh and try again.');
    }
    return data;
  }
  function phoneNote(total){
    if(query)return 'IMEI search '+query+' · '+number(total)+' matching IMEI '+(total===1?'record':'records');
    const count=report.summary[{in:'total_received',out:'total_out',balance:'in_company'}[mode]];
    if(!Number.isSafeInteger(count)||count===total)return '';
    if(count<total)return 'The recorded IMEI count differs from the stock total by '+number(total-count)+'.';
    const missing=count-total;
    return number(missing)+' '+(missing===1?'phone in the stock total has':'phones in the stock total have')+' no matching IMEI record.';
  }
  function render(){
    const summary=element('summary');
    summary.replaceChildren(...modes[mode].metrics.map(([key,label])=>{
      const div=document.createElement('div'),name=document.createElement('span'),value=document.createElement('strong');
      name.textContent=label;value.textContent=number(report.total?report.summary[key]:0);div.append(name,value);return div;
    }));
    const isPhone=details==='imei',selected=isPhone?phoneReport:report;
    if(!details||!selected){clearDetails();return;}
    const labels=isPhone?phoneHeaders:headers(),head=$('thead'),body=$('tbody');
    const note=element('phone-note'),message=isPhone?phoneNote(selected.total):'';
    note.hidden=!message;note.textContent=message;
    element('details').dataset.view=details;
    element('details').setAttribute('aria-label',isPhone?'IMEI data':'Stock by receipt');
    head.replaceChildren();
    const row=head.insertRow();
    for(const label of labels){const col=document.createElement('th');col.scope='col';col.textContent=label;row.append(col);}
    body.replaceChildren();
    for(const [index,record] of selected.rows.entries()){
      const line=body.insertRow();
      const cells=isPhone?phoneCells(record,offset+index):rowCells(record,offset+index,true);
      for(const value of cells)line.insertCell().textContent=value;
    }
    if(!selected.total){
      const cell=body.insertRow().insertCell();cell.colSpan=labels.length;
      cell.textContent=isPhone?'No IMEIs match this selection.':'No receipts match this selection.';
    }
    const unit=isPhone?'IMEI records':'receipts';
    element('count').textContent=selected.total?number(offset+1)+'–'+number(offset+selected.rows.length)+' of '+number(selected.total)+' '+unit:'0 '+unit;
    element('details').hidden=false;
  }
  async function rpc(name,params,signal){
    const response=await window.GREENLOOP_GET_CLIENT().rpc(name,params,{signal});
    if(response.error)throw response.error;
    return response.data;
  }
  function cancel(){
    read?.abort();read=null;exportJob?.abort();exportJob=null;
    downloads.close();
  }
  const phoneRpc='get_accounts_stock_overview_imeis_v1';
  const phoneArgs=()=>({...args(),p_imei:query});
  async function load({refresh=false,snapshot=null,scopeChanged=false}={}){
    if(!current())return;
    cancel();
    const controller=new AbortController();
    read=controller;
    const requested=mode,start=offset,view=details;
    const includeCatalogue=can('search')&&(refresh||!catalogue);
    if(scopeChanged||refresh)clearReport();
    else clearDetails();
    status(view==='imei'?'Loading IMEIs…':'Loading stock…');controls();
    try{
      if(view!=='imei'||!report||includeCatalogue){
        const showRows=view==='receipt';
        const data=await rpc('get_accounts_stock_overview_v1',{...args(),p_offset:showRows?start:0,p_show_rows:showRows,
          p_catalogue:includeCatalogue,p_expected_snapshot:showRows?snapshot:null},controller.signal);
        if(read!==controller||!current())return;
        valid(data,requested,showRows?start:0,showRows?50:0);
        if(includeCatalogue){
          if(!Array.isArray(data.catalogue)||data.catalogue.some(r=>!r.batch_id))throw Error('The stock filters could not be verified. Refresh and try again.');
          const previous=JSON.stringify(filterValues());
          catalogue=data.catalogue;pickOptions();
          if(previous!==JSON.stringify(filterValues())){offset=0;void load({scopeChanged:true});return;}
        }
        report=data;
      }
      if(view==='imei'){
        const data=await rpc(phoneRpc,{...phoneArgs(),p_offset:start,p_expected_snapshot:snapshot},controller.signal);
        if(read!==controller||!current())return;
        if(snapshot&&data?.snapshot!==snapshot)throw Error('The IMEI list changed. Refresh Stock Overview before trying again.');
        phoneReport=validPhones(data,requested,start,50);
      }
      render();status();
    }catch(error){
      if(read!==controller||!current())return;
      if(view==='imei')phoneReport=null;
      offset=0;
      status(error.code==='57014'?'Stock loading timed out. Use Refresh to try again.':error.message||'Stock Overview could not load.',true);
    }finally{if(read===controller){read=null;controls();}}
  }
  async function exportOverview(kind){
    if(!current()||!canExport()||!report?.total||read||exportJob)return;
    const controller=new AbortController(),selected=report,params=phoneArgs(),selectedScope=scope();
    exportJob=controller;
    controls();status('Preparing IMEI export…');
    const permit=()=>current()&&canExport()&&!controller.signal.aborted&&report===selected;
    try{
      const initial=details==='imei'&&phoneReport?phoneReport:validPhones(
        await rpc(phoneRpc,{...params,p_offset:0,p_summary_only:true},controller.signal),params.p_mode,0,0);
      if(!permit())return;
      if(!initial.total){status('No IMEIs match this selection.');return;}
      const rows=[],seen=new Set();
      while(rows.length<initial.total){
        const start=rows.length;
        const data=validPhones(await rpc(phoneRpc,{...params,p_offset:start,p_export:true,
          p_expected_snapshot:initial.snapshot},controller.signal),params.p_mode,start,250);
        if(!permit())return;
        if(data.snapshot!==initial.snapshot||data.total!==initial.total||data.rows.some(row=>seen.has(row.row_key))){
          throw Error('The IMEI list changed. Refresh Stock Overview before exporting.');
        }
        for(const row of data.rows){seen.add(row.row_key);rows.push(row);}
      }
      const note=phoneNote(initial.total);
      await downloads.output(kind,{
        title:'Stock Overview - '+modes[mode].label+' - IMEI List',
        subtitle:[selectedScope,number(initial.total)+' IMEI records',note].filter(Boolean).join(' | '),
        headers:phoneHeaders,rows:rows.map(phoneCells),numericColumns:[0],wrapWords:true
      },permit,'accounts','imei_download');
      if(permit())status();
    }catch(error){if(permit())status(error.message||'IMEI export could not be completed.',true);}
    finally{if(exportJob===controller){exportJob=null;controls();}}
  }
  function applySearch(value){
    if(!current()||!can('imei_data')||!can('search'))return;
    const term=value.trim();
    if(term&&!/^\d{3,15}$/.test(term)){status('Enter 3 to 15 IMEI digits.',true);return;}
    if((term||null)===query&&details==='imei'&&(read||phoneReport))return;
    query=term||null;details='imei';phoneReport=null;offset=0;void load();
  }
  function activate(view){
    cancel();visible=view==='overview'&&allowed();panel.hidden=!visible;
    if(!visible){clearReport();return;}
    status();
    element('exports').innerHTML=downloads.buttons('data-aso-export','accounts','imei_download');
    offset=0;details=null;void load({scopeChanged:true});
  }
  panel.addEventListener('click',event=>{
    const button=event.target.closest('button');
    if(!button||button.disabled||!current())return;
    const next=button.dataset.asoMode;
    if(next&&next!==mode){
      mode=next;offset=0;
      panel.querySelectorAll('[data-aso-mode]').forEach(tab=>tab.setAttribute('aria-pressed',String(tab.dataset.asoMode===mode)));
      element('summary-title').textContent=modes[mode].label;void load({scopeChanged:true});return;
    }
    if(button.dataset.asoExport){void exportOverview(button.dataset.asoExport);return;}
    if(button.id==='aso-refresh'){offset=0;void load({refresh:true});}
    if(button.id==='aso-clear-imei'){element('imei').value='';applySearch('');return;}
    if(button.id==='aso-view'||button.id==='aso-phones'){
      const view=button.id==='aso-view'?'receipt':'imei';
      details=details===view?null:view;offset=0;
      if(details)void load();
      else{clearDetails();controls();}
      return;
    }
    if(button.id==='aso-prev'||button.id==='aso-next'){
      const snapshot=(details==='imei'?phoneReport:report).snapshot;
      offset+=button.id==='aso-prev'?-50:50;
      void load({snapshot});
    }
  });
  element('filters').addEventListener('change',event=>{
    if(!current()||!can('search')||!catalogue)return;
    if(event.target===element('supplier')){element('batch').value='';element('invoice').value='';}
    pickOptions();offset=0;void load({scopeChanged:true});
  });
  element('search').addEventListener('submit',event=>{event.preventDefault();applySearch(element('imei').value);});
  element('imei').addEventListener('input',event=>{
    const value=event.target.value.trim();
    if(/^\d{15}$/.test(value)||(!value&&query))applySearch(value);
    controls();
  });
  document.addEventListener('greenloop:accounts-section',event=>activate(event.detail.view));
  for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed']){
    window.addEventListener(event,()=>{
      stopped=event!=='greenloop:permissions-changed'||stopped;
      activate(null);catalogue=null;query=null;element('imei').value='';
      for(const id of filterIds)fillSelect(element(id),[],'');
      controls();
    });
  }
  window.GREENLOOP_ACCESS_READY.then(controls);
})();
