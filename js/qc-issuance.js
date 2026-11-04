/* Saved Initial QC inspections are assigned and transferred from this full page. */
(() => {
  'use strict';
  const $=s=>document.querySelector(s),app=$('#issuance-app'),body=$('#issuance-body');
  const client=window.GREENLOOP_GET_CLIENT(),records=new Map(),timers=new WeakMap(),prepared=new Map();
  let technicians=[],sequence=0,busy=false,stopped=false,paste;
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
    row.querySelectorAll('input,select,button').forEach(e=>e.disabled=busy||paste?.busy||!can());
    const tech=row.querySelector('[data-technician]');tech.disabled=busy||paste?.busy||!can()||destination.value==='b_dept';
    row.querySelector('[data-transfer]').disabled=busy||paste?.busy||!can()||!r;
    row.querySelector('[data-reload]').disabled=busy||paste?.busy||!can()||!row.querySelector('.qc-issuance-imei').value;
  }
  function syncAll(){for(const row of body.rows)sync(row);$('#issuance-technician').disabled=busy||!can()||$('#issuance-destination').value==='b_dept';window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(app);}
  function createRows(n){for(let i=0;i<n;i++)body.insertAdjacentHTML('beforeend',`<tr data-row-id="issue-${++sequence}"><td><input class="qc-issuance-imei" placeholder="Scan 15-digit IMEI" maxlength="15" inputmode="numeric" autocomplete="off" data-capability="entry"><strong data-phone></strong><small data-device></small><small data-row-state role="status" hidden></small></td><td data-stock>—</td><td data-inspection>—</td><td data-work>—</td><td><label>Technician<select data-technician data-capability="entry">${options($('#issuance-technician').value)}</select></label><label>Destination<select data-destination data-capability="entry"><option value="lab_glass">Lab &amp; Glass</option><option value="b_dept">B-DEPT</option></select></label></td><td><button type="button" class="primary-button" data-transfer data-capability="entry" disabled>Transfer →</button><button type="button" class="secondary-button" data-reload data-capability="entry">Reload details</button></td></tr>`);
    for(const row of [...body.rows].slice(-n))row.querySelector('[data-destination]').value=$('#issuance-destination').value;
    $('#issuance-lines').textContent=`${body.rows.length} lines`;if(!paste?.busy)syncAll();
  }
  function clearRow(row){records.delete(row);row.dataset.ticket=String(Number(row.dataset.ticket||0)+1);delete row.dataset.issueRequest;row.dataset.loading='';for(const s of ['[data-stock]','[data-inspection]','[data-work]'])row.querySelector(s).textContent='—';row.querySelector('[data-phone]').textContent='';row.querySelector('[data-device]').textContent='';state(row);sync(row);}
  async function rpc(name,args={}){const{data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function populate(row,r){
    records.set(row,r);delete row.dataset.issueRequest;
    row.querySelector('[data-phone]').textContent=r.model||'—';row.querySelector('[data-device]').textContent=`${storage(r.storage_gb)} · ${r.color||'—'} · BH ${r.battery_health==null?'Not available':r.battery_health+'%'}`;
    const supplier=window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(r.supplier_code,r.stock_quantity,r.supplier_name,'—')||r.supplier_code||'—';
    row.querySelector('[data-stock]').innerHTML=`<strong>${esc(supplier)}</strong><small>${esc(r.batch_number||'—')}</small><small>${esc(r.invoice_number||'—')}</small>`;
    row.querySelector('[data-inspection]').innerHTML=`<span>Supplier grade <b>${esc(r.supplier_grade||'—')}</b></span><span>GL grade <b>${esc(r.gl_grade||'—')}</b></span><small>${esc(date(r.saved_at))}</small>`;
    row.querySelector('[data-work]').innerHTML=`<span class="issuance-work-label">Parts</span><span>${r.parts.length?r.parts.map(p=>`${esc(p.name)} × ${esc(p.quantity)}`).join('<br>'):'None'}</span><span class="issuance-work-label">Services</span><span>${r.services.length?r.services.map(esc).join('<br>'):'None'}</span>`;
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
    for(const select of app.querySelectorAll('#issuance-technician,[data-technician]')){const v=select.value;select.innerHTML=options(v);}
    // A successful inspection save in another tab becomes available on Refresh.
    prepared.clear();syncAll();
  }
  function lock(value){busy=value;for(const e of app.querySelectorAll('input,select,button'))e.disabled=value||(!can()&&e.dataset.capability!=='view');window.GREENLOOP_QC_HANDOVER?.setBusy('issuance',value);syncAll();}
  async function transfer(row){
    const r=records.get(row);if(!can()||!r||row.dataset.completed==='yes'||row.querySelector('.qc-issuance-imei').value.trim()!==r.imei)return{ok:false,error:'Load this saved inspection first.'};
    const dest=row.querySelector('[data-destination]').value,technician=dest==='lab_glass'?row.querySelector('[data-technician]').value:null;
    if(dest==='lab_glass'&&!technician){state(row,'Choose a Lab technician.',true);return{ok:false,error:'Choose a Lab technician.'};}
    if(dest==='b_dept'&&(r.parts.length||r.services.length||String(r.gl_grade).toUpperCase()==='D')){const error='B-DEPT direct transfer needs no parts or services and a non-D GL grade. Choose Lab & Glass for repair work.';state(row,error,true);return{ok:false,error};}
    row.dataset.issueRequest ||= crypto.randomUUID();row.dataset.saving='yes';state(row,'Transferring…');
    try{
      const result=await rpc('issue_initial_qc_inspection_v1',{p_job_id:r.job_id,p_revision:r.revision,p_destination:dest,p_technician_roster_id:technician||null,p_request_id:row.dataset.issueRequest});
      row.dataset.completed='yes';row.classList.add('is-completed');row.querySelector('[data-transfer]').textContent='Transferred';state(row,`Transferred to ${dest==='b_dept'?'B-DEPT':result.technician_name+' · Lab & Glass'}`);
      if(dest==='lab_glass')window.GREENLOOP_QC_HANDOVER?.record({jobId:r.job_id,imei:r.imei,model:r.model,storage:storage(r.storage_gb),color:r.color,technicianId:technician,technician:result.technician_name,parts:r.parts,services:r.services});
      window.dispatchEvent(new CustomEvent('greenloop:workflow-committed',{detail:{source:'qc-issuance',imeis:[r.imei]}}));return{ok:true};
    }catch(e){state(row,e.message||'Transfer failed. Your choices are preserved.',true);return{ok:false,error:e.message};}
    finally{row.dataset.saving='';sync(row);}
  }
  async function transferMany(rows){if(busy||paste?.busy||!can())return;message();lock(true);let done=0;const errors=[];try{for(const row of rows){if(stopped||!can())break;const result=await transfer(row);if(result.ok)done++;else errors.push(`Line ${[...body.rows].indexOf(row)+1}: ${result.error}`);}await refresh();message(`${done} phone(s) transferred.${errors.length?' '+errors.length+' need checking. '+errors[0]:''}`,!errors.length);}catch(e){message(e.message);}finally{lock(false);}}
  async function loadAll(){if(busy||paste?.busy||stopped||!window.GREENLOOP_CAN?.('view','initial_qc'))return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Replace this unfinished tray with all awaiting inspections?'))return;lock(true);message();try{const all=[];let offset=0,total=1;while(offset<total){const data=await rpc('get_qc_issuance_rows_v1',{p_offset:offset,p_limit:500});total=data.total;if(!data.rows.length&&offset<total)throw Error('The queue changed. Refresh and try again.');all.push(...data.rows);offset+=data.rows.length;}body.innerHTML='';records.clear();createRows(Math.max(10,all.length));all.forEach((r,i)=>{body.rows[i].querySelector('.qc-issuance-imei').value=r.imei;populate(body.rows[i],r);});message(`${all.length} saved inspections loaded.`,true);}catch(e){message(e.message);}finally{lock(false);}}
  function reset(){if(busy||paste?.busy)return;if([...body.rows].some(r=>records.has(r)&&r.dataset.completed!=='yes')&&!window.confirm('Clear this unfinished handover tray? Saved inspections stay in the queue.'))return;body.innerHTML='';records.clear();prepared.clear();paste?.clear();createRows(10);message();}
  body.addEventListener('input',event=>{const input=event.target.closest('.qc-issuance-imei');if(!input)return;const row=input.closest('tr');clearTimeout(timers.get(row));input.value=input.value.replace(/\D/g,'').slice(0,15);clearRow(row);if(input.value.length===15){timers.set(row,setTimeout(()=>loadRow(row).catch(e=>message(e.message)),120));const next=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>e!==input&&!e.disabled&&!e.value);if(document.activeElement===input)next?.focus();}});
  body.addEventListener('keydown',event=>{if(event.key!=='Enter'||!event.target.matches('.qc-issuance-imei'))return;event.preventDefault();const row=event.target.closest('tr');clearTimeout(timers.get(row));void loadRow(row).catch(e=>message(e.message));});
  body.addEventListener('change',e=>{const row=e.target.closest('tr');if(!row)return;if(e.target.matches('[data-destination],[data-technician]')){delete row.dataset.issueRequest;sync(row);}});
  body.addEventListener('click',e=>{const row=e.target.closest('tr');if(!row)return;if(e.target.closest('[data-transfer]'))void transferMany([row]);if(e.target.closest('[data-reload]')){clearRow(row);void loadRow(row).catch(e=>message(e.message));}});
  $('#issuance-transfer-all').addEventListener('click',()=>{const rows=[...body.rows].filter(r=>records.has(r)&&r.dataset.completed!=='yes');if(!rows.length){message('Scan or paste at least one saved inspection first.');return;}void transferMany(rows);});
  $('#issuance-load-all').addEventListener('click',()=>void loadAll());$('#issuance-clear').addEventListener('click',reset);$('#issuance-add').addEventListener('click',()=>createRows(10));
  $('#issuance-refresh').addEventListener('click',()=>{if(busy||paste?.busy)return;void refresh().catch(e=>message(e.message));});
  $('#issuance-destination').addEventListener('change',syncAll);
  $('#issuance-apply').addEventListener('click',()=>{if(!can()||busy||paste?.busy)return;for(const row of body.rows){if(row.dataset.completed==='yes')continue;row.querySelector('[data-technician]').value=$('#issuance-technician').value;row.querySelector('[data-destination]').value=$('#issuance-destination').value;delete row.dataset.issueRequest;sync(row);}});
  window.addEventListener('greenloop:imei-scan',event=>{if(!can()||busy||paste?.busy)return;const imei=String(event.detail?.imei||'');if(!/^\d{15}$/.test(imei))return;const existing=[...body.rows].find(r=>r.querySelector('.qc-issuance-imei').value===imei);if(existing){event.preventDefault();existing.scrollIntoView({block:'center'});state(existing,'This IMEI is already in the tray.');return;}let blank=[...body.querySelectorAll('.qc-issuance-imei')].find(e=>!e.disabled&&!e.value);if(!blank){createRows(1);blank=body.lastElementChild.querySelector('.qc-issuance-imei');}event.preventDefault();blank.value=imei;void loadRow(blank.closest('tr')).catch(e=>message(e.message));});
  function stop(){stopped=true;records.clear();prepared.clear();body.innerHTML='';app.hidden=true;message('Access ended. Reload after signing in.');}
  window.addEventListener('greenloop:office-locked',stop);window.addEventListener('pagehide',stop);client.auth.onAuthStateChange?.(e=>{if(e==='SIGNED_OUT')stop();});
  window.addEventListener('greenloop:permissions-changed',()=>{if(!window.GREENLOOP_CAN?.('view','initial_qc'))stop();else syncAll();});
  async function init(){await window.GREENLOOP_ACCESS_READY;if(!window.GREENLOOP_CAN?.('view','initial_qc'))throw Error('Initial QC page access is required.');await refresh();createRows(10);app.hidden=false;paste=window.GREENLOOP_QC_EXCEL_PASTE.attach({app,tableBody:body,selector:'.qc-issuance-imei',page:'initial_qc',client,createRows,clearRow,loadRow,prepare,onUnlock:()=>setTimeout(syncAll,0)});window.GREENLOOP_QC_HANDOVER?.refresh();syncAll();}
  void init().catch(e=>{$('#permission-message').textContent=e.message||'Issuance could not load.';$('#permission-message').hidden=false;});
})();
