(() => {
 'use strict';
 const $=s=>document.querySelector(s),panel=$('#box-status-panel'),list=$('#box-status-list'),detail=$('#box-status-detail'),message=$('#box-status-message');
 const can=c=>window.GREENLOOP_CAN?.(c,'export_boxes')===true,esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const dt=v=>v?new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'—';
 const status=s=>({accounts:'Pending Verification',recheck:'Recheck',exported:'Verified',legacy:'Historical'}[s]||s);
 const deleteDialog=$('#box-delete-dialog'),deleteForm=$('#box-delete-form'),deleteError=$('#box-delete-error');
 let client,offset=0,total=0,busy=false,selected=null,printed=null,accessVersion=0,deleteTarget=null,listedBoxes=[];
 const canDelete=box=>can('delete')&&!box.previously_verified&&['accounts','recheck'].includes(box.raw_state??box.state);
 const filters=window.GREENLOOP_FILTERS.get('box-status-filters',{before:list,sortTarget:list,dateKey:'saved_at',dateLabel:'Saved',fields:[['state','Status']],sortFields:[['box_number','Box'],['quantity','Phones','number'],['saved_at','Saved','date'],['state','Status']],onChange:()=>{offset=0;selected=null;printed=null;detail.hidden=true;return load();}});
 function notice(text='',error=false){message.textContent=text;message.classList.toggle('is-visible',!!text);message.classList.toggle('is-success',!error);}
 async function rpc(name,args={}){const r=await client.rpc(name,args);if(r.error)throw r.error;return r.data;}
 function lock(value){busy=value;filters.setBusy(value);panel.setAttribute('aria-busy',String(value));detail.querySelectorAll('button,input').forEach(el=>{if(value){if(!el.hasAttribute('data-br-disabled'))el.dataset.brDisabled=String(el.disabled);el.disabled=true;}else if(el.hasAttribute('data-br-disabled')){el.disabled=el.dataset.brDisabled==='true';delete el.dataset.brDisabled;}});$('#box-status-prev').disabled=value||offset===0;$('#box-status-next').disabled=value||offset+50>=total;window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(panel);}
 async function load(){if(busy||panel.hidden)return;lock(true);try{await loadRows();}catch(e){notice(e.message||'Box status could not be loaded.',true);}finally{lock(false);}}
 async function loadRows(){const token=accessVersion,sort=filters.sortArgs();const data=await rpc('get_box_status_v1',{p_filters:filters.query(),p_offset:offset,p_limit:50,p_sort_key:sort.p_sort_by||'saved_at',p_sort_direction:sort.p_sort_by?sort.p_sort_direction:'desc'});if(token!==accessVersion||!can("view"))return;total=Number(data.total||0);filters.result(data);listedBoxes=data.rows;
 list.innerHTML=data.rows.length?'<div class="br-table-wrap"><table class="br-table"><thead><tr><th>Box</th><th>Phones</th><th>Saved</th><th>Status</th><th>Verified</th>'+(can('delete')?'<th>Actions</th>':'')+'</tr></thead><tbody>'+data.rows.map(b=>`<tr><td><button type="button" class="br-open-box" data-br-open="${esc(b.id)}" data-capability="view" data-capability-page="export_boxes" data-search-read-only>${esc(b.box_number)}</button><span class="br-mobile-state br-state br-${esc(b.raw_state)}">${esc(b.state)}</span></td><td>${esc(b.quantity)}</td><td>${esc(dt(b.saved_at))}</td><td><span class="br-state br-${esc(b.raw_state)}">${esc(b.state)}</span></td><td>${esc(dt(b.verified_at))}</td>${can('delete')?'<td>'+deleteButton(b.id,b)+'</td>':''}</tr>`).join('')+'</tbody></table></div>':'<p class="br-empty">No saved boxes match these dates or filters.</p>';
 if(selected&&!detail.hidden){const changed=data.rows.find(r=>r.id===selected.box.box_id&&(r.raw_state!==selected.box.state||r.revision!==selected.box.revision));if(changed){const data=await rpc('get_box_entry_review_v1',{p_box_id:selected.box.box_id});if(token===accessVersion&&can('view'))renderDetail(data);}}
 $('#box-status-count').textContent=total?`${offset+1}–${Math.min(offset+50,total)} of ${total} boxes`:'0 boxes';}
 function deleteButton(id,box){
   return canDelete(box)?'<button type="button" class="danger-button" data-br-delete="'+esc(id)+'" data-capability="delete" data-capability-page="export_boxes">Delete Box</button>':'';
 }
 const imeiDigits=value=>String(value??'').replace(/\D/g,'');
 const boxFull=()=>Number.isSafeInteger(selected?.box.capacity)&&selected.lines.length>=selected.box.capacity;
 function detailNotice(text='',error=false){
   const status=detail.querySelector('#br-action-message');
   if(!status)return;
   status.textContent=text;status.classList.toggle('is-visible',!!text);status.classList.toggle('is-success',!error);
 }
 function filterBoxPhones(){
   if(!selected)return;
   const query=imeiDigits(detail.querySelector('#br-imei-search')?.value);
   let shown=0;
   detail.querySelectorAll('[data-br-phone-row]').forEach((element,index)=>{
     const phone=selected.lines[index];
     element.hidden=Boolean(query)&&![phone.imei,phone.imei_2].some(imei=>String(imei??'').includes(query));
     if(!element.hidden)shown++;
   });
   const count=detail.querySelector('#br-imei-search-count');
   if(count)count.textContent=shown+' of '+selected.lines.length+' phones';
   detail.querySelector('#br-no-imei').hidden=shown>0;
   detail.querySelector('#br-no-imei td').textContent=query?'No IMEI in this box matches your search.':'This box is empty.';
 }
 const columns=[['IMEI','imei'],['Model','model'],['GB','storage_gb'],['Grade','final_grade'],['Color','color'],['Supplier code','supplier_code'],['Invoice','invoice_number']];
 function renderDetail(data){
 const sameBox=selected?.box.box_id===data.box.box_id;
 const search=sameBox?detail.querySelector('#br-imei-search')?.value??'':'';
 const draft=sameBox?detail.querySelector('#br-imei')?.value??'':'';
 selected=data;printed=null;
 const b=data.box,recheck=b.state==='recheck',canCorrect=recheck&&can('scan'),full=boxFull();
 detail.innerHTML=`<div class="br-heading"><div><h2>${esc(b.box_number)}</h2><span class="br-state br-${esc(b.state)}">${esc(status(b.state))}</span><p>${data.lines.length} phone${data.lines.length===1?"":"s"} · Saved ${esc(dt(b.saved_at))}</p></div><div class="br-actions">${can('print')?'<button type="button" class="secondary-button" data-br-print data-capability="print" data-capability-page="export_boxes">Print Box</button>':''}${recheck&&can('print')?'<button type="button" class="secondary-button" data-br-confirm data-capability="print" data-capability-page="export_boxes" hidden>Printing completed</button>':''}${recheck&&can('save')?`<button type="button" class="primary-button" data-br-resend data-capability="save" data-capability-page="export_boxes" ${!data.lines.length||b.printed_revision!==b.revision||!b.printed_at?'disabled':''}>Resend to Accounts</button>`:''}${window.GREENLOOP_REPORT_DOWNLOADS.buttons('data-br-export','export_boxes','print')}${deleteButton(b.box_id,b)}<button type="button" class="secondary-button" data-br-close data-search-read-only>Close</button></div></div>
 ${b.recheck_reason?`<div class="br-reason"><strong>${recheck?'Box returned for Recheck':'Previous Recheck'}</strong><p>${esc(b.recheck_reason)}</p><small>${esc(b.recheck_by_name||'Not recorded')} · ${esc(dt(b.recheck_at))}</small></div>`:''}
 ${recheck?'<p>Remove an incorrect IMEI, then scan the correct Ready Stock phone. Print the updated box, confirm printing and resend to Accounts.</p>':''}
 <p id="br-action-message" class="form-message" role="status" aria-live="polite"></p>
 ${canCorrect?`
   <form id="br-rescan" class="br-rescan" data-scan-history data-capability="scan" data-capability-page="export_boxes">
     <label for="br-imei">Scan the correct IMEI<input id="br-imei" type="text" inputmode="numeric" pattern="[0-9]{15}"
       placeholder="15-digit IMEI" autocomplete="off" value="${esc(draft)}" required ${full?'disabled aria-describedby="br-box-full"':''}></label>
     <button type="submit" class="primary-button" ${full?'disabled':''}>Add IMEI</button>
   </form>
   ${full?'<p id="br-box-full">Box is full. Remove an IMEI first, then add the replacement.</p>':''}
 `:''}
 ${can('search')?`<div class="br-imei-search" data-scan-history>
   <label for="br-imei-search">Search IMEI in this box<input id="br-imei-search" type="search" inputmode="numeric"
     placeholder="IMEI 1 or IMEI 2" value="${esc(search)}" autocomplete="off" data-capability="search" data-capability-page="export_boxes" data-search-read-only></label>
   <span id="br-imei-search-count" role="status"></span>
 </div>`:''}
 <div class="br-table-wrap"><table class="br-table"><thead><tr><th>S.No</th>${columns.map(([h])=>'<th>'+h+'</th>').join('')}${canCorrect?'<th class="br-phone-correction">Correction</th>':''}</tr></thead><tbody>${data.lines.map((row,n)=>'<tr data-br-phone-row><td>'+(row.serial_no??n+1)+'</td>'+columns.map(([,k])=>'<td>'+esc(row[k]??'—')+(k==='imei'&&canCorrect?`<button type="button" class="danger-button br-mobile-remove" data-br-remove="${esc(row.id)}" data-imei="${esc(row.imei)}" data-capability="scan" data-capability-page="export_boxes">Remove IMEI</button>`:'')+'</td>').join('')+(canCorrect?`<td class="br-phone-correction"><button type="button" class="danger-button" data-br-remove="${esc(row.id)}" data-imei="${esc(row.imei)}" data-capability="scan" data-capability-page="export_boxes">Remove IMEI</button></td>`:'')+'</tr>').join('')}<tr id="br-no-imei" hidden><td colspan="${columns.length+(canCorrect?2:1)}"></td></tr></tbody></table></div>
 ${recheck&&window.GREENLOOP_CAN?.('box_correction','reports')?'<p>For model, GB, grade or other device details, use the authorised <a href="reports.html?report=export_boxes">Reports → Export Boxes → Box Correction</a>. Then reload and print the corrected box.</p>':''}`;
 filterBoxPhones();detail.hidden=false;window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(detail);if(busy)lock(true);}
 async function openBox(id){
   if(busy)return;
   const token=accessVersion;
   lock(true);notice();
   try{
     const data=await rpc('get_box_entry_review_v1',{p_box_id:id});
     if(token!==accessVersion||!can('view'))return;
     renderDetail(data);
     detail.scrollIntoView({behavior:'smooth',block:'start'});
   }catch(e){if(token===accessVersion)notice(e.message,true);}finally{lock(false);}
 }
 async function change(name,extra={}){
   if(busy||!selected||selected.box.state!=='recheck')return;
   const b=selected.box,token=accessVersion;
   const adding=name==='add_box_recheck_imei_v1',removing=name==='remove_box_recheck_imei_v1';
   const current=()=>token===accessVersion&&can('view')&&selected?.box.box_id===b.box_id;
   let saved=false;
   lock(true);notice();detailNotice();
   try{
     await rpc(name,{p_box_id:b.box_id,p_revision:b.revision,...extra});
     saved=true;
     if(!current())return;
     if(adding){const input=detail.querySelector('#br-imei');if(input)input.value='';const search=detail.querySelector('#br-imei-search');if(search)search.value='';}
     const updated=await rpc('get_box_entry_review_v1',{p_box_id:b.box_id});
     if(!current())return;
     renderDetail(updated);
     const text=adding?'IMEI '+extra.p_imei+' added. Print the updated box before resending.'
       :removing?'IMEI removed and available in Ready Stock. You can add the replacement now.'
       :name==='resend_box_to_accounts_v1'?'Box sent back to Accounts for verification.'
       :'Printing confirmed. Resend the box to Accounts.';
     detailNotice(text);
     await loadRows();
   }catch(error){
     if(!current())return;
     if(saved){
       selected=null;printed=null;detail.hidden=true;detail.replaceChildren();
       notice('Change saved. Reopen the box to refresh its details.',true);
       try{await loadRows();}catch(_){}
     }else{
       if(['22023','40001'].includes(error.code)){
         try{const updated=await rpc('get_box_entry_review_v1',{p_box_id:b.box_id});if(current())renderDetail(updated);}catch(_){}
       }
       if(current())detailNotice(error.message||'The box could not be updated. Try again.',true);
     }
   }finally{
     lock(false);
     if((adding||removing)&&current()&&!panel.hidden&&can('scan'))detail.querySelector('#br-imei')?.focus({preventScroll:true});
   }
 }

 function showDeleteBox(id){
   const b=selected?.box.box_id===id?selected.box:listedBoxes.find(row=>row.id===id);
   if(!b||!canDelete(b))return;
   deleteTarget={id,number:b.box_number,revision:b.revision,state:b.raw_state??b.state};
   const count=b.quantity??selected?.lines.length;
   $('#box-delete-copy').textContent='Delete '+b.box_number+'? '+count+' phone'+(count===1?' will':'s will')+' become available in Ready Stock.';
   deleteForm.reset();
   deleteError.textContent='';
   deleteDialog.showModal();
 }
 deleteDialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
 deleteDialog.addEventListener('close',()=>{deleteTarget=null;deleteForm.reset();});
 $('#cancel-box-delete').addEventListener('click',()=>deleteDialog.close());
 deleteForm.addEventListener('submit',async event=>{
   event.preventDefault();
   if(busy||!deleteTarget||!canDelete(deleteTarget))return;
   const requested=deleteTarget,token=accessVersion;
   const code=$('#box-delete-code').value;
   deleteForm.reset();
   deleteError.textContent='';
   deleteForm.querySelectorAll('input,button').forEach(el=>el.disabled=true);
   lock(true);notice();
   let result;
   try{
     const deleted=await rpc('delete_unverified_box_v1',{
       p_box_id:requested.id,p_revision:requested.revision,p_state:requested.state,p_delete_code:code
     });
     if(token!==accessVersion||!can('view'))return;
     if(!Number.isSafeInteger(deleted?.restored_items)||deleted.restored_items<0)
       throw Error('Deletion result could not be confirmed. Retry to check.');
     result=deleted;
     deleteDialog.close();
     if(selected?.box.box_id===requested.id){selected=null;printed=null;detail.hidden=true;detail.replaceChildren();}
     await loadRows();
     if(offset>0&&offset>=total){offset=Math.max(0,Math.floor((total-1)/50)*50);await loadRows();}
     if(token===accessVersion&&can('view'))
       notice(requested.number+' deleted. '+result.restored_items+' phone(s) available in Ready Stock.');
   }catch(error){
     if(token!==accessVersion||!can('view'))return;
     if(result||['22023','40001'].includes(error.code)){
       deleteDialog.close();
       selected=null;printed=null;detail.hidden=true;detail.replaceChildren();
       try{await loadRows();}catch(_){}
       if(token===accessVersion)notice(result?requested.number+' deleted. Refresh Box Status to update the list.':error.message,true);
     }else if(deleteDialog.open){
       deleteError.textContent=error.message||'Box could not be deleted. Try again.';
     }
   }finally{
     deleteForm.querySelectorAll('input,button').forEach(el=>el.disabled=false);
     if(deleteDialog.open)$('#box-delete-code').focus();
     lock(false);
   }
 });

 async function downloadBox(kind){if(busy||!selected||!can('view')||!can('print'))return;const id=selected.box.box_id;lock(true);try{const data=await rpc('get_box_entry_review_v1',{p_box_id:id});await window.GREENLOOP_REPORT_DOWNLOADS.output(kind,window.GREENLOOP_REPORT_DOWNLOADS.boxReport(data),()=>can('view')&&can('print')&&selected?.box.box_id===id,'export_boxes','print');}catch(e){notice(e.message,true);}finally{lock(false);}}
 async function printBox(){if(busy||!selected||!can('print'))return;lock(true);try{renderDetail(await rpc('get_box_entry_review_v1',{p_box_id:selected.box.box_id}));if(!selected.lines.length)throw new Error('Print a non-empty box.');const snapshot={id:selected.box.box_id,revision:selected.box.revision};await window.GREENLOOP_BOX_PRINT.open(selected,{allowed:()=>can('print')});printed=snapshot;const confirm=detail.querySelector('[data-br-confirm]');if(confirm){confirm.hidden=false;notice('After printing succeeds, choose Printing completed.');}}catch(e){notice(e.message,true);}finally{lock(false);}}
 panel.addEventListener('click',e=>{const b=e.target.closest('button');if(!b||busy)return;if(b.hasAttribute('data-br-export')){downloadBox(b.dataset.brExport);return;}if(b.dataset.brDelete){showDeleteBox(b.dataset.brDelete);return;}if(b.dataset.brOpen){openBox(b.dataset.brOpen);return;}if(b.hasAttribute('data-br-close')){detail.hidden=true;selected=null;printed=null;return;}if(b.hasAttribute('data-br-print')){printBox();return;}
 if(b.hasAttribute('data-br-confirm')&&can('print')&&printed&&selected?.box.box_id===printed.id){if(selected.box.revision!==printed.revision){notice('Box changed. Reload and print again.',true);return;}change('confirm_box_recheck_print_v1');return;}
 if(b.hasAttribute('data-br-resend')&&can('save')){change('resend_box_to_accounts_v1');return;}
 if(b.dataset.brRemove&&selected?.box.state==='recheck'&&can('scan')&&confirm(`Remove IMEI ${b.dataset.imei} from ${selected.box.box_number} and return that phone to Ready Stock?`))change('remove_box_recheck_imei_v1',{p_item_id:b.dataset.brRemove});});
 function submitRecheckImei(input){
   if(busy||!input||!can('scan')||selected?.box.state!=='recheck')return;
   if(boxFull()){detailNotice('Box is full. Remove an IMEI first, then add the replacement.',true);return;}
   const imei=input.value.trim();
   if(!/^\d{15}$/.test(imei)){detailNotice('Enter a valid 15-digit IMEI.',true);return;}
   void change('add_box_recheck_imei_v1',{p_imei:imei});
 }
 panel.addEventListener('submit',event=>{
   if(event.target.id!=='br-rescan')return;
   event.preventDefault();submitRecheckImei(event.target.querySelector('#br-imei'));
 });
 panel.addEventListener('greenloop:imei-input-scan',event=>{
   if(event.target.id==='br-imei')submitRecheckImei(event.target);
 });
 panel.addEventListener('input',event=>{if(event.target.id==='br-imei-search')filterBoxPhones();});
 $('#box-status-prev').onclick=()=>{if(!busy&&offset>0){offset-=50;load();}};$('#box-status-next').onclick=()=>{if(!busy&&offset+50<total){offset+=50;load();}};
 document.querySelectorAll('[data-box-entry-view]').forEach(button=>button.addEventListener('click',()=>{if(busy)return;const review=button.dataset.boxEntryView==='status';panel.hidden=!review;$('#box-entry-workspace').hidden=review;document.querySelectorAll('[data-box-entry-view]').forEach(b=>{const active=b===button;b.classList.toggle('is-active',active);b.setAttribute('aria-selected',String(active));});if(review)load();}));
 for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,()=>{accessVersion++;selected=null;printed=null;listedBoxes=[];detail.hidden=true;detail.replaceChildren();if(deleteDialog.open)deleteDialog.close();});
 async function init(){await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();if(window.GREENLOOP_PAGE_ACCESS?.pageKey!=='export_boxes')return;client=window.GREENLOOP_GET_CLIENT();window.addEventListener('focus',()=>{if(!panel.hidden&&!busy)load();});setInterval(()=>{if(!panel.hidden&&!busy&&!document.hidden&&!detail.querySelector('input:focus'))load();},15000);}
 init().catch(e=>notice(e.message,true));
})();
