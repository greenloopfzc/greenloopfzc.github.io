(() => {
  'use strict';
  const CAP='data-capability="workflow_correction" data-capability-page="reports"';
  const sections=['IMEI Entry','Receiving / Ready Stock','Initial QC','Lab & Glass','Parts','Final QC / Frame','Correction History'];
  let host=null,root=null,dialog=null,options={},data=null,drafts=new Map(),section=sections[0],epoch=0,saving=false,loading=false,locked=false;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const label=k=>({imei_1:'Primary IMEI',storage_gb:'Storage (GB)',gc_grade:'GL grade',names:'Services (one per line)',assigned_technician_roster_id:'Assigned technician',technician_roster_id:'Technician',inspected_by:'Inspected by',reviewed_by:'Reviewed by',receiving_batch_id:'Stock / Batch',supplier_id:'Supplier code',battery_health:'Battery health (%)',final_battery_health:'Final battery health (%)'}[k]||k.replace(/_/g,' ').replace(/^./,c=>c.toUpperCase()));
  const allowed=()=>!locked&&window.GREENLOOP_PAGE_ACCESS?.pageKey==='reports'&&window.GREENLOOP_CAN?.('view','reports')&&window.GREENLOOP_CAN?.('workflow_correction','reports');
  const key=e=>e.kind+'|'+e.row_key;
  const eq=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
  const date=v=>{if(!v)return '—';const d=new Date(v);return Number.isNaN(+d)?String(v):new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',dateStyle:'medium',timeStyle:'short'}).format(d)+' UAE';};
  const display=v=>v===null||v===undefined||v===''?'—':Array.isArray(v)?v.join(', '):typeof v==='boolean'?(v?'Yes':'No'):String(v);
  function message(text,error=false){const el=root?.querySelector('#wf-message');if(el){el.textContent=text;el.classList.toggle('wf-error',error);}}
  async function rpc(name,args){if(!allowed())throw Error('Full IMEI Workflow Correction permission is required.');const r=await window.GREENLOOP_GET_CLIENT().rpc(name,args);if(r.error)throw Error(r.error.message||'The request could not be completed.');return r.data;}
  function closeEditor(){if(dialog){dialog.close();dialog.remove();dialog=null;}}
  function lock(){locked=true;++epoch;closeEditor();data=null;drafts.clear();saving=false;loading=false;if(root)root.replaceChildren();}
  window.addEventListener('greenloop:office-locked',lock);
  window.addEventListener('greenloop:signed-out',lock);
  function mount(container,opts={}){
    if(host===container&&root?.isConnected){options=opts;return;}
    unmount();host=container;options=opts;locked=false;
    if(!allowed()){container.textContent='Full IMEI Workflow Correction access is required.';return;}
    root=document.createElement('div');root.className='wf-workspace';root.innerHTML=`<form id="wf-search" class="wf-search"><label for="wf-identifier">Find IMEI / device number</label><div><input id="wf-identifier" maxlength="120" autocomplete="off" placeholder="Enter or scan IMEI" ${CAP} required><button class="primary-button" ${CAP}>Open workflow</button></div></form><p id="wf-message" role="status" aria-live="polite"></p><div id="wf-content"></div>`;container.replaceChildren(root);
    root.querySelector('#wf-search').addEventListener('submit',e=>{e.preventDefault();load(root.querySelector('#wf-identifier').value);});
    if(data){root.querySelector('#wf-identifier').value=data.imei;render();}
  }
  function unmount(){++epoch;closeEditor();root?.remove();root=null;host=null;loading=false;}
  async function load(identifier,force=false){
    identifier=String(identifier||'').trim();if(!identifier||saving||!allowed())return;
    if(drafts.size&&!force&&!window.confirm('Discard the unsaved corrections and open this IMEI again?'))return;
    const token=++epoch;loading=true;closeEditor();data=null;drafts.clear();root?.querySelector('#wf-content').replaceChildren();message('Loading recorded entries…');
    try{const result=await rpc('get_full_imei_workflow_v1',{p_identifier:identifier});if(token!==epoch||!root||!allowed())return;data=result;section=sections[0];root.querySelector('#wf-identifier').value=data.imei;render();message('Choose a department and edit a recorded entry. Add changes, then save them together.');}
    catch(e){if(token===epoch&&root)message(e.message,true);}finally{if(token===epoch)loading=false;}
  }
  function render(){if(!root||!data)return;const content=root.querySelector('#wf-content');content.innerHTML=`<div class="wf-device"><div><span class="panel-kicker">Recorded workflow</span><h3>${esc(data.imei)}</h3><span>${esc(data.device_number)} · ${esc(String(data.status||'').replace(/_/g,' '))}</span></div><button type="button" class="secondary-button" id="wf-refresh" ${CAP}>Reload</button></div><nav class="wf-sections" aria-label="Workflow departments">${sections.map(s=>`<button type="button" data-wf-section="${esc(s)}" aria-pressed="${section===s}" ${CAP}>${esc(s)}${s==='Correction History'?'':` <small>${(data.entries||[]).filter(e=>e.section===s&&e.fields?.length).length}</small>`}</button>`).join('')}</nav><div id="wf-entries"></div><form id="wf-save" class="wf-save"><div class="wf-draft-heading"><strong id="wf-draft-count">${drafts.size} entries changed</strong><button class="secondary-button" type="button" id="wf-discard" ${CAP}>Discard changes</button></div><div id="wf-drafts"></div><div class="wf-save-fields"><label>Reason for correction<textarea id="wf-reason" minlength="5" maxlength="2000" required ${CAP}></textarea></label><label>Correction code<input id="wf-code" type="password" autocomplete="off" required ${CAP}></label><button class="primary-button" id="wf-save-button" ${CAP}>Save audited correction</button></div><p class="wf-help">All listed changes save together. Linked stock and workflow checks must pass. Times use UAE (UTC+4).</p></form>`;
    content.querySelector('#wf-refresh').onclick=()=>load(data.imei);
    content.querySelectorAll('[data-wf-section]').forEach(b=>b.onclick=()=>{section=b.dataset.wfSection;content.querySelectorAll('[data-wf-section]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));renderEntries();});
    content.querySelector('#wf-discard').onclick=()=>{drafts.clear();renderDrafts();renderEntries();};
    content.querySelector('#wf-save').onsubmit=save;
    renderEntries();renderDrafts();
  }
  function renderEntries(){const target=root?.querySelector('#wf-entries');if(!target||!data)return;
    if(section==='Correction History'){
      target.innerHTML=`<h3>Audited corrections</h3>${data.history?.length?data.history.map(h=>`<details class="wf-history"><summary><strong>${esc(date(h.changed_at))}</strong> · ${esc(h.actor)}<span>${esc(h.reason)}</span></summary>${(h.changes||[]).map(c=>`<h4>${esc(data.entries.find(e=>e.kind===c.kind)?.label||label(c.kind))}</h4><div class="wf-table-wrap"><table><thead><tr><th>Field</th><th>Previous value</th><th>Corrected value</th></tr></thead><tbody>${[...new Set([...Object.keys(c.before||{}),...Object.keys(c.after||{})])].filter(k=>!eq(c.before?.[k],c.after?.[k])).map(k=>`<tr><th>${esc(label(k))}</th><td>${esc(display(c.before?.[k]))}</td><td>${esc(display(c.after?.[k]))}</td></tr>`).join('')}</tbody></table></div>`).join('')}</details>`).join(''):'<p class="wf-empty">No full workflow corrections have been saved for this IMEI.</p>'}<details class="wf-history"><summary>Recorded activity timeline</summary>${(data.timeline||[]).map(t=>`<p><strong>${esc(t.title)}</strong><br><small>${esc(date(t.at))} · ${esc(t.actor)}</small></p>`).join('')||'<p>No recorded events.</p>'}</details>`;return;
    }
    const entries=(data.entries||[]).filter(e=>e.section===section&&e.fields?.length);
    target.innerHTML=entries.length?`<div class="wf-table-wrap"><table><thead><tr><th>Recorded entry</th><th>Job</th><th>Details</th><th>State</th><th>Correction</th></tr></thead><tbody>${entries.map(e=>{const draft=drafts.get(key(e));const dt=Object.entries({...e.values,...draft?.patch}).find(([k,v])=>v&&/(_at)$/.test(k));return `<tr><td><strong>${esc(e.label)}</strong>${dt?`<small>${esc(date(dt[1]))}</small>`:''}</td><td>${esc(e.job_number||'—')}</td><td>${esc(e.context||e.values.part_name||e.values.service_name||'—')}</td><td>${esc(String(e.state||'Recorded').replace(/_/g,' '))}</td><td><button class="secondary-button" type="button" data-wf-edit="${esc(key(e))}" ${CAP}>${draft?'Edit changes':'Edit entry'}</button>${draft?'<span class="wf-changed">Changed</span>':''}</td></tr>`;}).join('')}</tbody></table></div>`:'<p class="wf-empty">No recorded entries in this department for this IMEI.</p>';
    target.querySelectorAll('[data-wf-edit]').forEach(b=>b.onclick=()=>openEditor(data.entries.find(e=>key(e)===b.dataset.wfEdit)));
  }
  function renderDrafts(){if(!root)return;root.querySelector('#wf-draft-count').textContent=`${drafts.size} ${drafts.size===1?'entry':'entries'} changed`;root.querySelector('#wf-save-button').disabled=!drafts.size||saving;root.querySelector('#wf-discard').disabled=!drafts.size||saving;const target=root.querySelector('#wf-drafts');target.innerHTML=[...drafts.entries()].map(([k,d])=>{const e=data.entries.find(e=>key(e)===k);return `<div class="wf-draft"><strong>${esc(e.label)}${e.context?' · '+esc(e.context):''}</strong><span>${Object.keys(d.patch).map(f=>`${esc(label(f))}: ${esc(display(d.patch[f]))}`).join(' · ')}</span><button type="button" class="secondary-button" data-wf-remove="${esc(k)}" ${CAP}>Remove change</button></div>`;}).join('');target.querySelectorAll('[data-wf-remove]').forEach(b=>b.onclick=()=>{drafts.delete(b.dataset.wfRemove);renderDrafts();renderEntries();});}
  function choiceOptions(field,entry){const k=field.key,opts=data.options||{};
    if(k==='supplier_id')return opts.suppliers||[];if(k==='receiving_batch_id')return opts.batches||[];
    if(k.includes('technician')&&k.endsWith('_id'))return opts.employees||[];
    if(['inspected_by','reviewed_by'].includes(k))return opts.profiles||[];
    if(k==='classification'||k==='return_reason')return ['damaged','faulty','not_needed','other'].map(id=>({id,label:label(id)}));
    return (field.choices||[]).map(id=>({id,label:label(id)}));
  }
  function initialValue(field,value){if(value==null)return '';if(field.type==='date'){const t=new Date(value);if(Number.isNaN(+t))return String(value);return new Date(+t+4*3600000).toISOString().slice(0,16);}if(field.type==='list')return Array.isArray(value)?value.join('\n'):String(value);return String(value);}
  function openEditor(entry){if(!entry||saving||!allowed())return;closeEditor();const current={...entry.values,...drafts.get(key(entry))?.patch};dialog=document.createElement('dialog');dialog.className='wf-editor';dialog.innerHTML=`<form id="wf-edit-form"><div class="wf-editor-heading"><div><span class="panel-kicker">${esc(entry.section)} · ${esc(data.imei)}</span><h3>${esc(entry.label)}</h3><p>${esc(entry.context||entry.job_number||'')}</p></div><button class="secondary-button" type="button" id="wf-edit-close" ${CAP}>Close</button></div><div class="wf-edit-fields"></div>${entry.stock_source_required?`<label id="wf-stock-label">Original supply source<select id="wf-stock" ${CAP}><option value="">Choose if changing issued quantity</option><option value="direct">Direct supplied (no inventory deduction)</option><option value="inventory">Taken from inventory (update balance)</option></select></label>`:''}<p id="wf-edit-message" role="status"></p><div class="wf-editor-footer"><button class="primary-button" ${CAP}>Add to changes</button></div></form>`;
    document.body.append(dialog);const fields=dialog.querySelector('.wf-edit-fields');
    for(const f of entry.fields){const wrap=document.createElement('label');wrap.textContent=label(f.key);let input;const choices=choiceOptions(f,entry);if(f.type==='enum'||f.type==='choice'||choices.length||f.type==='boolean'){
        input=document.createElement('select');const vals=f.type==='boolean'?[{id:'true',label:'Yes'},{id:'false',label:'No'}]:choices;
        if(f.nullable)input.add(new Option('— Not set —',''));
        for(const v of vals)input.add(new Option(v.label||v.id,v.id));
        const val=initialValue(f,current[f.key]);if(val&&!Array.from(input.options).some(o=>o.value===val))input.add(new Option('Recorded reference: '+val,val));input.value=val;
      }else{input=document.createElement(f.type==='list'||/(notes|work_done|failure_reason)$/.test(f.key)?'textarea':'input');input.value=initialValue(f,current[f.key]);if(input.tagName==='INPUT'){input.type=f.type==='number'?'number':f.type==='date'?'datetime-local':'text';if(f.type==='number')input.step='any';} }
      input.dataset.wfField=f.key;input.dataset.initial=input.value;input.setAttribute('data-capability','workflow_correction');input.setAttribute('data-capability-page','reports');if(!f.nullable)input.required=true;wrap.append(input);fields.append(wrap);
    }
    if(dialog.querySelector('#wf-stock'))dialog.querySelector('#wf-stock').value=drafts.get(key(entry))?.stock_handling||'';
    dialog.querySelector('#wf-edit-close').onclick=closeEditor;
    dialog.addEventListener('cancel',e=>{e.preventDefault();closeEditor();});
    dialog.querySelector('#wf-edit-form').onsubmit=e=>{e.preventDefault();if(!allowed())return;try{
      const patch={...drafts.get(key(entry))?.patch};for(const f of entry.fields){const input=dialog.querySelector(`[data-wf-field="${f.key}"]`);if(input.value===input.dataset.initial)continue;let v=input.value;if(v===''&&f.nullable)v=null;else if(f.type==='number'){v=Number(v);if(!Number.isFinite(v))throw Error('Enter a valid '+label(f.key)+'.');}else if(f.type==='boolean')v=v==='true';else if(f.type==='date'){const t=new Date(v+(v.length===16?':00':'')+'+04:00');if(Number.isNaN(+t))throw Error('Enter a valid date.');v=t.toISOString();}else if(f.type==='list')v=v.split(/\r?\n/).map(s=>s.trim()).filter(Boolean);if(eq(v,entry.values[f.key]))delete patch[f.key];else patch[f.key]=v;}
      const stock=dialog.querySelector('#wf-stock')?.value;if(entry.stock_source_required&&patch.quantity_issued!==undefined&&!stock)throw Error('Select the original supply source for this issued quantity correction.');
      if(Object.keys(patch).length)drafts.set(key(entry),{kind:entry.kind,row_key:entry.row_key,revision:entry.revision,patch,...(stock?{stock_handling:stock}:{})});else drafts.delete(key(entry));closeEditor();renderDrafts();renderEntries();message('Changes prepared. Enter a reason and correction code, then save.');
    }catch(err){dialog.querySelector('#wf-edit-message').textContent=err.message;}};
    dialog.showModal();
  }
  async function save(e){e.preventDefault();if(saving||loading||!data||!drafts.size||!allowed())return;const reason=root.querySelector('#wf-reason').value.trim(),code=root.querySelector('#wf-code').value;if(reason.length<5){message('Enter a correction reason of at least 5 characters.',true);return;}
    const canonical=data.imei,payload={p_device_id:data.device_id,p_snapshot:data.snapshot,p_changes:[...drafts.values()],p_reason:reason,p_code:code},token=epoch;saving=true;root.querySelectorAll('input,select,textarea,button').forEach(el=>el.disabled=true);message('Saving and checking linked records…');let result;
    try{result=await rpc('save_full_imei_workflow_v1',payload);if(token!==epoch||!root||!allowed())return;drafts.clear();root.querySelector('#wf-code').value='';message('Correction saved. Reloading recorded entries…');}
    catch(err){if(token===epoch&&root)message(err.message+' Your prepared changes are still here. Reload the workflow if its records have changed.',true);}
    finally{saving=false;if(token===epoch&&root){root.querySelectorAll('input,select,textarea,button').forEach(el=>el.disabled=false);renderDrafts();}}
    if(result&&token===epoch&&root){await load(result.imei||canonical,true);if(data)message('Correction saved with permanent history.');try{options.onSaved?.();}catch(_){}}
  }
  window.addEventListener('beforeunload',e=>{if(drafts.size||saving){e.preventDefault();e.returnValue='';}});
  window.GREENLOOP_FULL_IMEI_CORRECTION={mount,unmount,isBusy:()=>saving||loading||drafts.size>0||!!dialog,isSaving:()=>saving};
})();
