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
  const fields=['Supplier','Stock / Batch','Invoice','Date received'];
  const filterIds=['supplier','batch','invoice'];
  const toggle=document.querySelector('[data-accounts-view="overview"]');
  let mode='in',visible=false,details=false,offset=0,catalogue=null,report=null;
  let read=null,exportJob=null,stopped=false;

  panel.innerHTML='<div class="aso-heading"><h2>Stock Overview</h2><button type="button" class="secondary-button" id="aso-refresh" data-capability="supplier_stock" data-capability-page="accounts">Refresh</button></div>'+
    '<nav class="aso-modes" aria-label="Stock Overview sections">'+Object.entries(modes).map(([key,s])=>'<button type="button" class="secondary-button" data-aso-mode="'+key+'" aria-pressed="'+(key===mode)+'" data-capability="supplier_stock" data-capability-page="accounts">'+s.label+'</button>').join('')+'</nav>'+
    '<div class="aid-primary" id="aso-filters">'+[['supplier','Supplier','All suppliers'],['batch','Stock / Batch','All batches'],['invoice','Invoice','All invoices']].map(([key,label,all])=>'<label>'+label+'<select id="aso-'+key+'" data-capability="search" data-capability-page="accounts"><option value="">'+all+'</option></select></label>').join('')+'</div>'+
    '<div class="aid-toolbar"><button type="button" class="primary-button" id="aso-view" aria-controls="aso-details" aria-expanded="false" data-capability="supplier_stock" data-capability-page="accounts">View Data</button><div class="aid-export-actions" id="aso-exports"></div></div>'+
    '<p id="aso-status" role="status" hidden></p><h3 class="greenloop-stock-heading" id="aso-summary-title">In Stock</h3><div class="aso-summary" id="aso-summary"></div>'+
    '<section id="aso-details" aria-label="Stock by receipt" hidden><div class="aid-table-wrap" tabindex="0" role="region" aria-label="Stock by receipt table"><table class="aid-table" data-preserve-table-layout><thead></thead><tbody></tbody></table></div>'+
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
    toggle.hidden=!allowed();
    element('filters').hidden=!can('search');
    panel.querySelectorAll('select').forEach(select=>{select.disabled=!catalogue||!can('search');});
    element('refresh').disabled=Boolean(read);
    element('view').disabled=!report||Boolean(read);
    element('view').textContent=details?'Hide Data':'View Data';
    element('view').setAttribute('aria-expanded',String(details));
    element('prev').disabled=!report||Boolean(read)||offset===0;
    element('next').disabled=!report||Boolean(read)||offset+50>=report.total;
    panel.querySelectorAll('[data-aso-export]').forEach(button=>{button.disabled=!report||!report.total||!can('print')||Boolean(read||exportJob);});
  }
  function clearDetails(){
    element('details').hidden=true;
    $('thead').replaceChildren();$('tbody').replaceChildren();element('count').textContent='';
  }
  function clearReport(){
    report=null;element('summary').replaceChildren();clearDetails();
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
  function render(){
    const summary=element('summary');
    summary.replaceChildren(...modes[mode].metrics.map(([key,label])=>{
      const div=document.createElement('div'),name=document.createElement('span'),value=document.createElement('strong');
      name.textContent=label;value.textContent=number(report.total?report.summary[key]:0);div.append(name,value);return div;
    }));
    if(!details){clearDetails();return;}
    const labels=headers(),head=$('thead'),body=$('tbody');
    head.replaceChildren();
    const row=head.insertRow();
    for(const label of labels){const col=document.createElement('th');col.scope='col';col.textContent=label;row.append(col);}
    body.replaceChildren();
    for(const [index,record] of report.rows.entries()){
      const line=body.insertRow();
      for(const value of rowCells(record,offset+index,true))line.insertCell().textContent=value;
    }
    if(!report.total){const cell=body.insertRow().insertCell();cell.colSpan=labels.length;cell.textContent='No receipts match this selection.';}
    element('count').textContent=report.total?number(offset+1)+'–'+number(offset+report.rows.length)+' of '+number(report.total)+' receipts':'0 receipts';
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
  async function load({refresh=false,snapshot=null}={}){
    if(!current())return;
    cancel();
    const controller=new AbortController();
    read=controller;
    const requested=mode,start=offset,showRows=details,includeCatalogue=can('search')&&(refresh||!catalogue);
    const params={...args(),p_offset:start,p_show_rows:showRows,p_catalogue:includeCatalogue,p_expected_snapshot:snapshot};
    clearReport();status('Loading stock…');controls();
    try{
      const data=await rpc('get_accounts_stock_overview_v1',params,controller.signal);
      if(read!==controller||!current())return;
      valid(data,requested,start,showRows?50:0);
      if(includeCatalogue){
        if(!Array.isArray(data.catalogue)||data.catalogue.some(r=>!r.batch_id))throw Error('The stock filters could not be verified. Refresh and try again.');
        const previous=JSON.stringify(filterValues());
        catalogue=data.catalogue;pickOptions();
        if(previous!==JSON.stringify(filterValues())){offset=0;void load();return;}
      }
      report=data;
      render();status();
    }catch(error){
      if(read!==controller||!current())return;
      if(error.code==='40001')offset=0;
      status(error.code==='57014'?'Stock loading timed out. Use Refresh to try again.':error.message||'Stock Overview could not load.',true);
    }finally{if(read===controller){read=null;controls();}}
  }
  async function exportOverview(kind){
    if(!current()||!can('print')||!report?.total||read||exportJob)return;
    const controller=new AbortController(),selected=report,params=args(),selectedScope=scope();
    exportJob=controller;
    controls();status('Preparing complete export…');
    const permit=()=>current()&&can('print')&&!controller.signal.aborted&&report===selected;
    try{
      const rows=[],seen=new Set();
      while(rows.length<selected.total){
        if(!permit())return;
        const start=rows.length;
        const data=valid(await rpc('export_accounts_stock_overview_v1',{...params,p_offset:start,p_expected_snapshot:selected.snapshot},controller.signal),params.p_mode,start,250);
        if(!permit())return;
        if(data.snapshot!==selected.snapshot||data.total!==selected.total||data.rows.some(row=>seen.has(row.batch_id)))throw Error('Stock changed. Refresh Stock Overview before exporting.');
        for(const row of data.rows){seen.add(row.batch_id);rows.push(row);}
      }
      await downloads.output(kind,{
        title:'Stock Overview - '+modes[mode].label,
        subtitle:selectedScope+' | '+modes[mode].metrics.map(([key,label])=>label+' '+number(selected.summary[key])).join(' · '),
        headers:headers(),rows:rows.map((row,index)=>rowCells(row,index,false)),
        numericColumns:[0,...metricKeys().map((_,index)=>index+5)],wrapWords:true
      },permit,'accounts','print');
      if(permit())status();
    }catch(error){if(permit())status(error.message||'Export could not be completed.',true);}
    finally{if(exportJob===controller){exportJob=null;controls();}}
  }
  function activate(view){
    cancel();visible=view==='overview'&&allowed();panel.hidden=!visible;
    if(!visible){clearReport();return;}
    status();
    element('exports').innerHTML=downloads.buttons('data-aso-export','accounts','print');
    offset=0;details=false;void load();
  }
  panel.addEventListener('click',event=>{
    const button=event.target.closest('button');
    if(!button||button.disabled||!current())return;
    const next=button.dataset.asoMode;
    if(next&&next!==mode){
      mode=next;offset=0;details=false;
      panel.querySelectorAll('[data-aso-mode]').forEach(tab=>tab.setAttribute('aria-pressed',String(tab.dataset.asoMode===mode)));
      element('summary-title').textContent=modes[mode].label;void load();return;
    }
    if(button.dataset.asoExport){void exportOverview(button.dataset.asoExport);return;}
    if(button.id==='aso-refresh'){offset=0;void load({refresh:true});}
    if(button.id==='aso-view'){
      details=!details;offset=0;
      if(details)void load();
      else{clearDetails();controls();}
    }
    if(button.id==='aso-prev'||button.id==='aso-next'){
      const snapshot=report.snapshot;
      offset+=button.id==='aso-prev'?-50:50;
      void load({snapshot});
    }
  });
  element('filters').addEventListener('change',event=>{
    if(!current()||!can('search')||!catalogue)return;
    if(event.target===element('supplier')){element('batch').value='';element('invoice').value='';}
    pickOptions();offset=0;details=false;void load();
  });
  document.addEventListener('greenloop:accounts-section',event=>activate(event.detail.view));
  for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed']){
    window.addEventListener(event,()=>{
      stopped=event!=='greenloop:permissions-changed'||stopped;
      activate(null);catalogue=null;
      for(const id of filterIds)fillSelect(element(id),[],'');
      controls();
    });
  }
  window.GREENLOOP_ACCESS_READY.then(controls);
})();
