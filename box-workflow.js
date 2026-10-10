(() => {
  'use strict';
  const $=s=>document.querySelector(s),app=$('#box-queue-app'),page=app.dataset.boxPage;
  const filter=$('#box-queue-filter'),list=$('#box-queue-list'),detail=$('#box-queue-detail'),message=$('#box-queue-message');
  let client,offset=0,total=0,busy=false,generation=0,selected=null,printed=null,canEdit=false;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const dt=v=>v?new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'numeric',minute:'2-digit',hour12:true}):'Not recorded';
  const cell=v=>esc(v===null||v===undefined||v===''?'—':v);
  const state=v=>({accounts:'Awaiting verification',exported:'Verified',legacy:'Historical box · prior workflow',draft:'Box Entry'}[v]||v);
  async function rpc(name,args={}){const {data,error}=await client.rpc(name,args);if(error)throw error;return data;}
  function notice(text='',error=false){message.textContent=text;message.classList.toggle('is-visible',!!text);message.classList.toggle('is-success',!error);}
  function lock(value){busy=value;app.setAttribute('aria-busy',String(value));app.querySelectorAll('button').forEach(b=>b.disabled=value);$('#box-queue-prev').disabled=value||offset===0;$('#box-queue-next').disabled=value||offset+50>=total;detail.querySelectorAll('[data-entry-only]').forEach(b=>b.disabled=value||!canEdit);}
  async function load(){
    if(busy)return;const token=++generation;notice();lock(true);selected=null;printed=null;detail.hidden=true;
    try {
      const data=await rpc('get_box_queue_v1',{p_page:page,p_date_from:filter.elements.from.value||null,p_date_to:filter.elements.to.value||null,p_offset:offset,p_limit:50});if(token!==generation)return;
      total=data.total;list.innerHTML=data.rows.length?'<div class="box-table-wrap"><table class="box-table"><thead><tr><th>Box</th><th>Phones</th><th>Saved · UAE</th><th>Saved by</th><th>Status</th><th>Verified · UAE</th><th>Verified by</th><th>Customer</th></tr></thead><tbody>'+data.rows.map(b=>`<tr><td><button type="button" class="quiet-link" data-search-read-only data-open-box="${esc(b.id)}">${cell(b.box_number)}</button></td><td>${cell(b.quantity)}</td><td>${cell(dt(b.saved_at))}</td><td>${cell(b.saved_by_name)}</td><td>${cell(state(b.state))}</td><td>${cell(dt(b.verified_at))}</td><td>${cell(b.verified_by_name)}</td><td>${cell(b.customer_name||b.customer_code)}</td></tr>`).join('')+'</tbody></table></div>':'<p class="box-empty">No boxes found for these dates.</p>';
      $('#box-queue-count').textContent=total?`${offset+1}–${Math.min(offset+50,total)} of ${total} boxes`:'0 boxes';
    }catch(e){list.innerHTML='';total=0;notice(e.message||'Boxes could not be loaded.',true);}finally{if(token===generation)lock(false);}
  }
  function renderDetail(data,keepCustomer=false){
    const customerChoice=keepCustomer?detail.querySelector("#box-customer")?.value:null;
    selected=data;printed=null;const b=data.box;
    const columns=[['S.No','serial_no'],['IMEI','imei'],['Device','device_number'],['Model','model'],['GB','storage_gb'],['Grade','final_grade'],['Color','color'],['Supplier','supplier_name'],['Supplier code','supplier_code'],['Stock received · UAE','received_at'],['Invoice','invoice_number']];
    detail.innerHTML=`<div class="box-detail-heading"><div><span class="gl-wordmark gl-wordmark-small"><img src="assets/greenloop-fzc-logo.jpg" alt="Greenloop FZC"></span><h2>${cell(b.box_number)}</h2><p>${cell(state(b.state))} · ${data.lines.length} phones</p>${b.customer_code?`<p>Customer: ${cell(b.customer_name||b.customer_code)}</p>`:""}</div><div class="box-actions"><button class="secondary-button" type="button" data-print-box data-search-read-only>Print Box</button>${b.state==='accounts'&&page==='accounts'&&canEdit?'<button class="secondary-button" type="button" data-confirm-print data-entry-only hidden>Printing completed</button><button class="primary-button" type="button" data-verify-box data-entry-only>Verify Box</button>':''}<button class="secondary-button" type="button" data-close-box data-search-read-only>Close</button></div></div><p class="box-review-note">${b.state==='accounts'?'Review every phone and its source details. If data needs correction, use Reports → Export Boxes → Box Correction.':b.state==='legacy'?'Historical box from before Accounts verification was introduced.':'Verified by '+cell(b.verified_by_name)+' · '+cell(dt(b.verified_at))}</p>${page==='accounts'?window.GREENLOOP_ACCOUNTS?.picker(b)||'':''}<div class="box-table-wrap"><table class="box-table"><thead><tr>${columns.map(([label])=>'<th>'+esc(label)+'</th>').join('')}</tr></thead><tbody>${data.lines.map(row=>'<tr>'+columns.map(([,key])=>'<td>'+cell(key==='received_at'?dt(row[key]):row[key])+'</td>').join('')+'</tr>').join('')}</tbody></table></div>`;
    if(customerChoice && detail.querySelector("#box-customer"))detail.querySelector("#box-customer").value=customerChoice;
    detail.hidden=false;
  }
  async function open(id){if(busy)return;lock(true);notice();detail.hidden=true;selected=null;try{if(page==='accounts'&&canEdit)await window.GREENLOOP_ACCOUNTS.reloadCustomers();renderDetail(await rpc('get_box_workflow_v1',{p_box_id:id}));detail.scrollIntoView({behavior:'smooth',block:'start'});}catch(e){notice(e.message,true);}finally{lock(false);}}
  async function printBox(){if(busy||!selected)return;lock(true);notice();try{
    renderDetail(await rpc('get_box_workflow_v1',{p_box_id:selected.box.box_id}),true);
    printed={id:selected.box.box_id,revision:selected.box.revision};window.print();
    const confirm=detail.querySelector('[data-confirm-print]');if(confirm){confirm.hidden=false;notice('When the sheet has printed successfully, choose Printing completed.');}
  }catch(e){notice(e.message,true);}finally{lock(false);}}
  async function confirmPrint(){if(busy||!canEdit||!printed)return;lock(true);try{await rpc('mark_box_printed_v1',{p_box_id:printed.id,p_revision:printed.revision});renderDetail(await rpc('get_box_workflow_v1',{p_box_id:printed.id}),true);notice('Printing confirmed. Review the details, then Verify Box.');}catch(e){notice(e.message,true);}finally{lock(false);}}
  async function verify(){
    if(busy||!canEdit||!selected||page!=='accounts')return;
    const customer=detail.querySelector('#box-customer');
    if(!customer||!customer.value){notice('Select a customer before verifying this box.',true);customer?.reportValidity();return;}
    const customerId=customer.value;
    if(!window.confirm(`Verify ${selected.box.box_number} (${selected.lines.length} phones) for ${customer.selectedOptions[0].textContent} and move it to Stock Exported?`))return;
    lock(true);let done=false;try{await rpc('verify_box_v2',{p_box_id:selected.box.box_id,p_revision:selected.box.revision,p_customer_id:customerId});done=true;}catch(e){notice(e.message,true);}finally{lock(false);}
    if(done){offset=0;await load();notice('Box verified and moved to Stock Exported.');}
  }
  filter.addEventListener('submit',e=>{e.preventDefault();if(!busy){offset=0;load();}});
  $('#clear-box-dates').addEventListener('click',()=>{if(busy)return;filter.reset();offset=0;load();});
  $('#box-queue-prev').addEventListener('click',()=>{if(!busy&&offset>0){offset-=50;load();}});
  $('#box-queue-next').addEventListener('click',()=>{if(!busy&&offset+50<total){offset+=50;load();}});
  app.addEventListener('click',e=>{const b=e.target.closest('button');if(!b||busy)return;if(b.dataset.openBox)open(b.dataset.openBox);else if(b.hasAttribute('data-print-box'))printBox();else if(b.hasAttribute('data-confirm-print'))confirmPrint();else if(b.hasAttribute('data-verify-box'))verify();else if(b.hasAttribute('data-close-box')){detail.hidden=true;selected=null;printed=null;}});
  async function init(){client=window.GREENLOOP_GET_CLIENT();const {data,error}=await client.auth.getSession();if(error)throw error;if(!data.session){location.replace('index.html');return;}await window.GREENLOOP_ACCESS_READY;if(window.GREENLOOP_PAGE_ACCESS?.pageKey!==page)throw Error('You do not have permission to view this page.');canEdit=window.GREENLOOP_PAGE_ACCESS.canEdit===true;if(page==='accounts')await window.GREENLOOP_ACCOUNTS.init({client,canEdit,lock,notice,isBusy:()=>busy});app.hidden=false;await load();}
  init().catch(e=>{const n=$('#permission-message');n.textContent=e.message;n.hidden=false;});
})();
