/* Saved Initial QC inspections are assigned and transferred from this full page. */
(() => {
  'use strict';
  const $=s=>document.querySelector(s),app=$('#issuance-app'),body=$('#issuance-body');
  const client=window.GREENLOOP_GET_CLIENT(),records=new Map(),timers=new WeakMap(),prepared=new Map();
  let technicians=[],sequence=0,busy=false,stopped=false,paste,editing=null,workCatalog=null,catalogAt=0;
  const selectionTemplate={technician:'',destination:'lab_glass'};
  const can=()=>!stopped&&window.GREENLOOP_CAN?.('entry','initial_qc')===true;
  const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const storage=n=>!n?'—':n>=1024&&n%1024===0?`${n/1024} TB`:`${n} GB`;
  const date=s=>s?new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',dateStyle:'medium',timeStyle:'short'}).format(new Date(s))+' UAE':'—';
  function message(text='',success=false){const e=$('#issuance-message');e.textContent=text;e.hidden=!text;e.classList.toggle('is-visible',Boolean(text));e.classList.toggle('is-success',success);}
  function state(row,text='',error=false){const e=row.querySelector('[data-row-state]');e.textContent=text;e.hidden=!text;row.classList.toggle('is-error',error);}
  function options(value=''){return '<option value="">Choose technician</option>'+technicians.map(t=>`<option value="${esc(t.id)}" ${t.id===value?'selected':''}>${esc(t.name)}</option>`).join('');}
  function sync(row){
    if(row.dataset.completed==='yes'){row.querySelectorAll('input,select,button').forEach(e=>e.disabled=true);return;}
    const r=records.get(row),destination=row.querySelector('[data-destination]');
    row.querySelectorAll('input,select,button').forEach(e=>e.disabled=busy||paste?.busy||!can()||Boolean(editing));
    const tech=row.querySelector('[data-technician]');tech.disabled=busy||paste?.busy||!can()||Boolean(editing)||destination.value==='b_dept';
    row.querySelector('[data-transfer]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!r;
    row.querySelector('[data-edit-work]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!r;
    row.querySelector('[data-reload]').disabled=busy||paste?.busy||!can()||Boolean(editing)||!row.querySelector('.qc-issuance-imei').value;
  }
  function syncAll(){for(const row of body.rows)sync(row);syncWorkEditor();window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(app);}
  function carrySelection(row,field){
    const selector=field==='technician'?'[data-technician]':'[data-destination]',flag=field==='technician'?'manualTechnician':'manualDestination';
    if(row!==body.firstElementChild){row.dataset[flag]='yes';return;}
    const value=row.querySelector(selector).value;selectionTemplate[field]=value;
    for(const other of [...body.rows].slice(1)){
      if(other.dataset.completed==='yes'||other.dataset[flag]==='yes')continue;
      other.querySelector(selector).value=value;delete other.dataset.issueRequest;sync(other);
    }
  }
  function createRows(n){for(let i=0;i<n;i++)body.insertAdjacentHTML('beforeend',`<tr data-row-id="issue-${++sequence}"><td class="issuance-imei-cell"><input class="qc-issuance-imei" placeholder="Scan IMEI" maxlength="15" inputmode="numeric" autocomplete="off" data-capability="entry" aria-label="Scan IMEI"><small data-row-state role="status" hidden></small></td><td data-phone>—</td><td data-storage>—</td><td data-color>—</td><td data-battery>—</td><td data-stock>—</td><td data-supplier-grade>—</td><td data-gl-grade>—</td><td data-parts>—</td><td data-services>—</td><td><select data-technician data-capability="entry" aria-label="Assign technician">${options(selectionTemplate.technician)}</select></td><td><select data-destination data-capability="entry" aria-label="Destination"><option value="lab_glass">Lab &amp; Glass</option><option value="b_dept">B-DEPT</option></select></td><td><div class="issuance-row-actions"><button type="button" class="primary-button" data-work-save data-capability="entry" hidden>Save</button><button type="button" class="secondary-button" data-work-cancel data-capability="entry" hidden>Cancel</button><button type="button" class="secondary-button issuance-edit" data-edit-work data-capability="entry" title="Edit Parts / Services" aria-label="Edit Parts / Services" disabled>Edit</button><button type="button" class="primary-button" data-transfer data-capability="entry" disabled>Transfer</button><button type="button" class="secondary-button issuance-reload" data-reload data-capability="entry" aria-label="Reload details" title="Reload saved details">↻</button></div></td></tr>`);
    for(const row of [...body.rows].slice(-n))row.querySelector('[data-destination]').value=selectionTemplate.destination;
    $('#issuance-lines').textContent=`${body.rows.length} lines`;if(!paste?.busy)syncAll();
  }
  function clearRow(row){records.delete(row);row.dataset.ticket=String(Number(row.dataset.ticket||0)+1);delete row.dataset.issueRequest;row.dataset.loading='';for(const selector of ['[data-phone]','[data-storage]','[data-color]','[data-battery]','[data-stock]','[data-supplier-grade]','[data-gl-grade]','[data-parts]','[data-services]']){const cell=row.querySelector(selector);cell.textContent='—';cell.removeAttribute('title');cell.removeAttribute('aria-label');}state(row);sync(row);}
  async function rpc(name,args={}){const{data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function workMessage(text=''){
    if(editing)state(editing.row,text,Boolean(text)&&text!=='Saving changes…');
  }
  function syncWorkEditor(){
    const locked=busy||paste?.busy||!can();
    for(const row of body.rows){
      const active=editing?.row===row;
      for(const selector of ['[data-edit-work]','[data-transfer]','[data-reload]'])row.querySelector(selector).hidden=active;
      for(const selector of ['[data-work-save]','[data-work-cancel]']){
        const button=row.querySelector(selector);button.hidden=!active;button.disabled=locked||!active;
      }
      if(active)for(const cell of row.querySelectorAll('[data-parts],[data-services]'))cell.querySelectorAll('select,button').forEach(e=>e.disabled=locked);
    }
    for(const id of ['issuance-transfer-all','issuance-add','issuance-clear','issuance-load-all','issuance-refresh']){
      const e=$('#'+id);e.disabled=busy||paste?.busy||Boolean(editing)||(e.dataset.capability==='entry'&&!can());
    }
  }
  function renderSavedWork(row,r){
    for(const [selector,values]of [['[data-parts]',r.parts.map(p=>p.name)],['[data-services]',r.services]]){
      const cell=row.querySelector(selector);cell.textContent=values.length?values.join('; '):'None';cell.title=cell.textContent;
    }
  }
  function workSelect(kind,value){
    const items=editing.catalog[kind==='part'?'parts':'services'].map(p=>p.name);
    if(value&&!items.includes(value))items.push(value);
    return `<select data-work-choice="${kind}" data-capability="entry" aria-label="${kind==='part'?'Select part':'Select service'}"><option value="">${kind==='part'?'Select part':'Select service'}</option>${items.map(name=>`<option value="${esc(name)}"${name===value?' selected':''}>${esc(name)}</option>`).join('')}</select>`;
  }
  function renderWorkEditor(){
    if(!editing)return;
    for(const kind of ['part','service']){
      const values=kind==='part'?editing.parts.map(p=>p.name):editing.services;
      const cell=editing.row.querySelector(kind==='part'?'[data-parts]':'[data-services]');cell.removeAttribute('title');
      cell.innerHTML=`<div class="issuance-inline-group" data-work-group="${kind}"><div class="issuance-inline-list">${values.map(value=>workSelect(kind,value)).join('')}</div><button type="button" class="secondary-button" data-work-add="${kind}" data-capability="entry" title="Add another ${kind}" aria-label="Add another ${kind}">+</button><button type="button" class="secondary-button issuance-inline-minus" data-work-remove="${kind}" data-capability="entry" title="Remove last ${kind}" aria-label="Remove last ${kind}">−</button></div>`;
    }
    syncWorkEditor();
  }
  function closeWorkEditor(){
    const row=editing?.row;editing=null;
    if(row?.isConnected){row.classList.remove('is-editing');const r=records.get(row);if(r)renderSavedWork(row,r);state(row,'Awaiting Issuance');}
    syncAll();
  }
  async function openWorkEditor(row){
    const r=records.get(row);
    if(editing||busy||paste?.busy||!can()||!r||row.dataset.completed==='yes')return;
    lock(true);state(row,'Loading options…');message();
    try{
      const catalog=workCatalog&&Date.now()-catalogAt<60000?workCatalog:await rpc('get_ranked_qc_dropdowns_v1');
      if(!can()||!row.isConnected||records.get(row)!==r)return;
      if(!Array.isArray(catalog?.parts)||!Array.isArray(catalog?.services)||![...catalog.parts,...catalog.services].every(o=>typeof o.name==='string'&&o.name.trim()))throw Error('Parts and services options could not load. Try Edit again.');
      workCatalog=catalog;catalogAt=Date.now();
      editing={row,record:r,catalog,parts:r.parts.length?r.parts.map(p=>({name:p.name,quantity:p.quantity})):[{name:'',quantity:1}],services:r.services.length?[...r.services]:[''],request:null};
      row.classList.add('is-editing');renderWorkEditor();state(row,'Editing parts / services');
    }catch(e){state(row,e.message||'The editor could not be opened.',true);}
    finally{lock(false);}
  }
  async function saveWorkEditor(){
    if(!editing||busy||paste?.busy||!can())return;
    const draft=editing,r=draft.record,parts=draft.parts.filter(p=>p.name),services=draft.services.filter(Boolean);
    if(parts.length>100||services.length>100){workMessage('Select no more than 100 different parts and 100 services.');return;}
    const key=v=>String(v).trim().replace(/\s+/g,' ').toLowerCase();
    if(new Set(parts.map(p=>key(p.name))).size!==parts.length||new Set(services.map(key)).size!==services.length){workMessage('Select each part and service only once.');return;}
    draft.request ||= crypto.randomUUID();lock(true);workMessage('Saving changes…');
    try{
      const result=await rpc('update_qc_issuance_requirements_v1',{
        p_job_id:r.job_id,p_revision:r.revision,p_parts:parts.map(p=>({part_name:p.name,quantity:p.quantity})),p_services:services,p_request_id:draft.request
      });
      if(stopped||editing!==draft||!can()||!draft.row.isConnected)return;
      const updated=result?.row;
      if(result.saved!==true||updated?.job_id!==r.job_id||updated?.imei!==r.imei||!Array.isArray(updated.parts)||!Array.isArray(updated.services)||typeof updated.revision!=='string')throw Error('Saved changes could not be verified. Retry Save or cancel and reload the phone.');
      prepared.clear();populate(draft.row,updated);closeWorkEditor();state(draft.row,'Changes saved · Awaiting Issuance');
      window.dispatchEvent(new CustomEvent('greenloop:workflow-committed',{detail:{source:'qc-issuance-edit',imeis:[r.imei]}}));
    }catch(e){if(editing===draft)workMessage(e.message||'Changes were not saved. Your selections are still here.');}
    finally{lock(false);}
  }
  function changeWorkChoice(select){
    if(!editing||busy||paste?.busy||!can()||select.closest('tr')!==editing.row)return;
    const kind=select.dataset.workChoice,index=[...editing.row.querySelectorAll(`[data-work-choice="${kind}"]`)].indexOf(select);
    if(kind==='part'){
      const old=editing.parts[index];editing.parts[index]={name:select.value,quantity:old.name===select.value?old.quantity:1};
    }else editing.services[index]=select.value;
    editing.request=null;workMessage();
  }
  function changeWorkLines(kind,add){
    if(!editing||busy||paste?.busy||!can())return;
    const list=kind==='part'?editing.parts:editing.services;
    if(add)list.push(kind==='part'?{name:'',quantity:1}:'');
    else if(list.length>1)list.pop();else list[0]=kind==='part'?{name:'',quantity:1}:'';
    editing.request=null;workMessage();renderWorkEditor();
  }
  body.addEventListener('paste',event=>{if(editing){event.preventDefault();event.stopImmediatePropagation();workMessage('Save or cancel this row before pasting more phones.');}},true);
  window.addEventListener('storage',event=>{if(event.key==='greenloop-qc-work-options-changed'){workCatalog=null;catalogAt=0;}});

  function populate(row,r){
    records.set(row,r);delete row.dataset.issueRequest;
    const cell=(selector,value,title=value)=>{const e=row.querySelector(selector);e.textContent=value;e.title=title;};
    cell('[data-phone]',r.model||'—');cell('[data-storage]',storage(r.storage_gb));cell('[data-color]',r.color||'—');cell('[data-battery]',r.battery_health==null?'N/A':r.battery_health+'%');
    const supplier=window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(r.supplier_code,r.stock_quantity,r.supplier_name,'—')||r.supplier_code||'—';
    const receipt=`${supplier}\nStock / Batch: ${r.batch_number||'—'}\nInvoice: ${r.invoice_number||'—'}`;
    cell('[data-stock]',supplier,receipt);row.querySelector('[data-stock]').setAttribute('aria-label',receipt);
    const saved=`Inspection saved: ${date(r.saved_at)}${r.saved_by?' · '+r.saved_by:''}`;
    cell('[data-supplier-grade]',r.supplier_grade||'—',saved);cell('[data-gl-grade]',r.gl_grade||'—',saved);
    renderSavedWork(row,r);
    row.dataset.inspectionRevision=r.revision;state(row,'Awaiting Issuance');sync(row);
  }
  async function prepare(imeis){prepared.clear();for(let i=0;i<imeis.length;i+=500){const chunk=imeis.slice(i,i+500);const data=await rpc('get_qc_issuance_rows_v1',{p_imeis:chunk,p_limit:500});for(const r of data.rows)prepared.set(r.imei,r);}}
  async function loadRow(row,settings={}){
    const input=row.querySelector('.qc-issuance-imei'),imei=input.value.trim();if(!/^\d{15}$/.test(imei))return{loaded:false,message:'Enter an exact 15-digit IMEI.'};
    const ticket=row.dataset.ticket=String(Number(row.dataset.ticket||0)+1),current=()=>!stopped&&row.isConnected&&row.dataset.ticket===ticket&&input.value.trim()===imei&&(!settings.isCurrent||settings.isCurrent());
    if([...body.rows].some(other=>other!==row&&other.querySelector('.qc-issuance-imei').value===imei)){state(row,'This IMEI is already in this tray.',true);return{loaded:false,message:'Duplicate IMEI: already in this tray.'};}
    row.dataset.loading='yes';state(row,'Loading saved inspection…');
    try{
      const r=settings.bulk?prepared.get(imei):(await rpc('get_qc_issuance_rows_v1',{p_imeis:[imei],p_limit:1})).rows[0];
      if(!current())return{loaded:false,message:'Loading stopped.'};
      if(r){populate(row,r);return{loaded:true};}
      const record=await window.GREENLOOP_IMEI_STAGE_NOTICE.lookup(imei);if(!current())return{loaded:false,message:'Loading stopped.'};
      const text=record?.matched_type==='secondary'?`This is IMEI 2. Use IMEI 1 ${record.primary_imei||''}.`:record?.found?`Current stage: ${record.current_stage}. Save its Initial QC inspection before issuance.`:'IMEI not found in the software.';
      state(row,text,true);if(!settings.bulk)void window.GREENLOOP_IMEI_STAGE_NOTICE.show({imei,knownRecord:record,title:'Phone unavailable here',message:text,onlyIfFound:true,isCurrent:current});return{loaded:false,message:text,record};
    }catch(e){if(current())state(row,e.message||'Could not load. Press Enter to retry.',true);throw e;}
    finally{if(current()){row.dataset.loading='';sync(row);}}
  }
  async function refresh(){
    const data=await rpc('get_qc_issuance_options_v1');technicians=data.technicians||[];$('#issuance-count').textContent=String(data.awaiting_issuance||0);
    for(const select of app.querySelectorAll('[data-technician]')){const v=select.value;select.innerHTML=options(v);}
    if(body.firstElementChild)selectionTemplate.technician=body.firstElementChild.querySelector('[data-technician]').value;
    // A successful inspection save in another tab becomes available on Refresh.
    prepared.clear();syncAll();
  }
  function lock(value){busy=value;for(const e of app.querySelectorAll('input,select,button'))e.disabled=value||(!can()&&e.dataset.capability!=='view');window.GREENLOOP_QC_HANDOVER?.setBusy('issuance',value);syncAll();}
  async function transfer(row){
    const r=records.get(row);if(editing)return{ok:false,error:'Save or cancel the open Parts / Services editor first.'};
    if(!can()||!r||row.dataset.completed==='yes'||row.querySelector('.qc-issuance-imei').value.trim()!==r.imei)return{ok:false,error:'Load this saved inspection first.'};
    const dest=row.querySelector('[data-destination]').value,technician=dest==='lab_glass'?row.querySelector('[data-technician]').value:null;
    if(dest==='lab_glass'&&!technician){state(row,'Choose a Lab technician.',true);return{ok:false,error:'Choose a Lab technician.'};}
    if(dest==='b_dept'&&(r.parts.length||r.services.length||String(r.gl_grade).toUpperCase()==='D')){const error='B-DEPT direct transfer needs no parts or services and a non-D GL grade. Choose Lab & Glass for repair work.';state(row,error,true);return{ok:false,error};}
    row.dataset.issueRequest ||= crypto.randomUUID();row.dataset.saving='yes';state(row,'Transferring…');
    try{
      const result=await rpc('issue_initial_qc_inspection_v1',{p_job_id:r.job_id,p_revision:r.revision,p_destination:dest,p_technician_roster_id:technician||null,p_request_id:row.dataset.issueRequest});
      row.dataset.completed='yes';row.classList.add('is-completed');row.querySelector('[data-transfer]').textContent='Done';state(row,`Transferred to ${dest==='b_dept'?'B-DEPT':result.technician_name+' · Lab & Glass'}`);
      if(dest==='lab_glass')window.GREENLOOP_QC_HANDOVER?.record({jobId:r.job_id,imei:r.imei,model:r.model,storage:storage(r.storage_gb),color:r.color,technicianId:technician,technician:result.technician_name,parts:r.parts,services:r.services});
      window.dispatchEvent(new CustomEvent('greenloop:workflow-committed',{detail:{source:'qc-issuance',imeis:[r.imei]}}));return{ok:true};
    }catch(e){state(row,e.message||'Transfer failed. Your choices are preserved.',true);return{ok:false,error:e.message};}
    finally{row.dataset.saving='';sync(row);}
  }
  async function transferMany(rows){if(editing){message('Save or cancel the open Parts / Services editor first.');return;}if(busy||paste?.busy||!can())return;message();lock(true);let done=0;const errors=[];try{for(const row of rows){if(stopped||!can())break;const result=await transfer(row);if(result.ok)done++;else errors.push(`Line ${[...body.rows].indexOf(row)+1}: ${result.error}`);}await refresh();message(`${done} phone(s) transferred.${errors.length?' '+errors.length+' need checking. '+errors[0]:''}`,!errors.length);}catch(e){message(e.message);}finally{lock(false);}}
  async function loadAll(){if(editing||busy||paste?.busy||stopped||!window.GREENLOOP_CAN?.('view','initial_qc'))return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Replace this unfinished tray with all awaiting inspections?'))return;lock(true);message();try{const all=[];let offset=0,total=1;while(offset<total){const data=await rpc('get_qc_issuance_rows_v1',{p_offset:offset,p_limit:500});total=data.total;if(!data.rows.length&&offset<total)throw Error('The queue changed. Refresh and try again.');all.push(...data.rows);offset+=data.rows.length;}body.innerHTML='';records.clear();createRows(Math.max(10,all.length));all.forEach((r,i)=>{body.rows[i].querySelector('.qc-issuance-imei').value=r.imei;populate(body.rows[i],r);});message(`${all.length} saved inspections loaded.`,true);}catch(e){message(e.message);}finally{lock(false);}}
  function reset(){if(editing||busy||paste?.busy)return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Clear this unfinished handover tray? Saved inspections stay in the queue.'))return;body.innerHTML='';records.clear();prepared.clear();paste?.clear();createRows(10);message();}
  body.addEventListener('input',event=>{const input=event.target.closest('.qc-issuance-imei');if(!input||editing)return;const row=input.closest('tr');clearTimeout(timers.get(row));input.value=input.value.replace(/\D/g,'').slice(0,15);clearRow(row);if(input.value.length===15){timers.set(row,setTimeout(()=>loadRow(row).catch(e=>message(e.message)),120));const next=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>e!==input&&!e.disabled&&!e.value);if(document.activeElement===input)next?.focus();}});
  body.addEventListener('keydown',event=>{if(editing||event.key!=='Enter'||!event.target.matches('.qc-issuance-imei'))return;event.preventDefault();const row=event.target.closest('tr');clearTimeout(timers.get(row));void loadRow(row).catch(e=>message(e.message));});
  body.addEventListener('change',e=>{const row=e.target.closest('tr');if(!row||!can()||busy||paste?.busy||row.dataset.completed==='yes')return;if(e.target.matches('[data-work-choice]')){changeWorkChoice(e.target);return;}if(editing)return;if(e.target.matches('[data-destination],[data-technician]')){delete row.dataset.issueRequest;carrySelection(row,e.target.matches('[data-technician]')?'technician':'destination');sync(row);}});
  body.addEventListener('click',e=>{
    const row=e.target.closest('tr');if(!row||busy||paste?.busy||!can())return;
    if(editing){
      if(editing.row!==row)return;
      if(e.target.closest('[data-work-save]'))void saveWorkEditor();
      else if(e.target.closest('[data-work-cancel]'))closeWorkEditor();
      else if(e.target.closest('[data-work-add]'))changeWorkLines(e.target.closest('[data-work-add]').dataset.workAdd,true);
      else if(e.target.closest('[data-work-remove]'))changeWorkLines(e.target.closest('[data-work-remove]').dataset.workRemove,false);
      return;
    }
    if(e.target.closest('[data-edit-work]'))void openWorkEditor(row);
    if(e.target.closest('[data-transfer]'))void transferMany([row]);
    if(e.target.closest('[data-reload]')){clearRow(row);void loadRow(row).catch(e=>message(e.message));}
  });
  $('#issuance-transfer-all').addEventListener('click',()=>{const rows=[...body.rows].filter(r=>records.has(r)&&r.dataset.completed!=='yes');if(!rows.length){message('Scan or paste at least one saved inspection first.');return;}void transferMany(rows);});
  $('#issuance-load-all').addEventListener('click',()=>void loadAll());$('#issuance-clear').addEventListener('click',reset);$('#issuance-add').addEventListener('click',()=>{if(!editing&&!busy&&!paste?.busy&&can())createRows(10);});
  $('#issuance-refresh').addEventListener('click',()=>{if(editing||busy||paste?.busy)return;workCatalog=null;catalogAt=0;void refresh().catch(e=>message(e.message));});
  window.addEventListener('greenloop:imei-scan',event=>{if(editing||!can()||busy||paste?.busy)return;const imei=String(event.detail?.imei||'');if(!/^\d{15}$/.test(imei))return;const existing=[...body.rows].find(r=>r.querySelector('.qc-issuance-imei').value===imei);if(existing){event.preventDefault();existing.scrollIntoView({block:'center'});state(existing,'This IMEI is already in the tray.');return;}let blank=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>!e.disabled&&!e.value);if(!blank){createRows(1);blank=body.lastElementChild.querySelector('.qc-issuance-imei');}event.preventDefault();blank.value=imei;void loadRow(blank.closest('tr')).catch(e=>message(e.message));});
  function stop(){stopped=true;closeWorkEditor();records.clear();prepared.clear();body.innerHTML='';app.hidden=true;message('Access ended. Reload after signing in.');}
  window.addEventListener('greenloop:office-locked',stop);window.addEventListener('pagehide',stop);client.auth.onAuthStateChange?.(e=>{if(e==='SIGNED_OUT')stop();});
  window.addEventListener('greenloop:permissions-changed',()=>{if(!window.GREENLOOP_CAN?.('view','initial_qc'))stop();else{if(!can()&&editing)closeWorkEditor();syncAll();}});
  async function init(){await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();if(!window.GREENLOOP_CAN?.('view','initial_qc'))throw Error('Initial QC page access is required.');await refresh();createRows(10);app.hidden=false;paste=window.GREENLOOP_QC_EXCEL_PASTE.attach({app,tableBody:body,selector:'.qc-issuance-imei',page:'initial_qc',client,createRows,clearRow,loadRow,prepare,onUnlock:()=>setTimeout(syncAll,0)});window.GREENLOOP_QC_HANDOVER?.refresh();syncAll();}
  void init().catch(e=>{$('#permission-message').textContent=e.message||'Issuance could not load.';$('#permission-message').hidden=false;});
})();
