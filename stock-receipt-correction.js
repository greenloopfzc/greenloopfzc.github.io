(() => {
 'use strict';
 const can=c=>window.GREENLOOP_CAN?.(c,'reports')===true;
 const allowed=()=>can('view')&&can('report_receipt_correction');
 const cap='data-capability="report_receipt_correction" data-capability-page="reports" data-search-read-only';
 const writeCap='data-capability="receipt_quantity_correction" data-capability-page="reports"';
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const num=v=>Number(v||0).toLocaleString('en-GB');
 const date=v=>new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:true});
 let root=null,epoch=0,busy=false,saving=false,receipt=null,list=null,offset=0,historyOffset=0,historyTotal=0,timer,requests=new Map();

 const supplierWriteCap='data-capability="receipt_supplier_correction" data-capability-page="reports"';
 const nameWriteCap='data-capability="receipt_supplier_name_correction" data-capability-page="reports"';
 let supplierState=null,supplierPreview=null,supplierOffset=0;
 let nameState=null,namePreview=null;
 function validSupplier(d,expected=receipt){const count=n=>Number.isSafeInteger(n)&&n>=0;return d?.version==='20261119-receipt-supplier-correction-1'&&d.batch_id===expected?.batch_id&&d.supplier_id===expected.supplier_id&&d.quantity===expected.quantity&&count(d.quantity)&&d.quantity>0&&['batch_count','job_count','phone_count','return_count','replacement_count'].every(k=>count(d[k]))&&typeof d.supplier_code==='string'&&/^[a-f0-9]{32}$/.test(d.snapshot)&&/^[a-f0-9]{32}$/.test(d.history_snapshot)&&Array.isArray(d.suppliers)&&d.suppliers.every(s=>typeof s.supplier_id==='string'&&typeof s.supplier_code==='string'&&(s.supplier_name==null||typeof s.supplier_name==='string'))&&Array.isArray(d.history)&&d.history.every(h=>typeof h.request_id==='string'&&typeof h.old_code==='string'&&typeof h.new_code==='string'&&count(h.quantity)&&typeof h.reason==='string')&&d.limit===50&&count(d.offset)&&d.offset%50===0&&count(d.history_total)&&d.history.length===Math.min(50,Math.max(0,d.history_total-d.offset));}
 function clearSupplierPreview(){supplierPreview=null;if(!root)return;$('#src-supplier-preview').replaceChildren();$('#src-supplier-confirm').hidden=true;controls();}
 function clearSupplier(){supplierState=null;supplierOffset=0;clearSupplierPreview();if(!root)return;$('#src-new-supplier').replaceChildren(new Option('Choose correct supplier',''));$('#src-supplier-reason').value='';$('#src-supplier-history').replaceChildren();$('#src-supplier-panel').hidden=true;}
 function drawSupplierHistory(d){supplierOffset=d.offset;$('#src-supplier-history').innerHTML=d.history.length?d.history.map((h,i)=>'<tr><td>'+(d.offset+i+1)+'</td><td>'+esc(date(h.created_at))+'</td><td>'+esc(h.actor_name||'Not recorded')+'</td><td>'+esc(supplier({supplier_code:h.old_code,supplier_name:h.old_name,quantity:h.quantity}))+'</td><td>'+esc(supplier({supplier_code:h.new_code,supplier_name:h.new_name,quantity:h.quantity}))+'</td><td>'+esc(h.reason)+'</td></tr>').join(''):'<tr><td colspan="6">No supplier corrections recorded.</td></tr>';$('#src-supplier-range').textContent=d.history_total?(d.offset+1)+'–'+Math.min(d.offset+50,d.history_total)+' of '+num(d.history_total):'0 corrections';}
 function drawSupplier(d){clearSupplier();if(!validSupplier(d)){ $('#src-supplier-panel').hidden=false;$('#src-supplier-status').textContent=d?.version==='20261119-receipt-supplier-correction-1'?'Stock details changed or could not be verified. Reload this receipt.':'Supplier correction is unavailable. Install the Receipt Supplier Correction database update, then reload this receipt.';$('#src-supplier-form').hidden=true;return;}
  supplierState=d;$('#src-supplier-panel').hidden=false;$('#src-supplier-status').textContent='';$('#src-supplier-form').hidden=!can('receipt_supplier_correction');
  $('#src-current-supplier').textContent=supplier({supplier_code:d.supplier_code,supplier_name:d.supplier_name,quantity:d.quantity});
  for(const s of d.suppliers.filter(s=>s.supplier_id!==d.supplier_id))$('#src-new-supplier').add(new Option([s.supplier_code,s.supplier_name].filter(Boolean).join(' '),s.supplier_id));drawSupplierHistory(d);controls();
 }
 async function reviewSupplier(event){event.preventDefault();if(busy||!receipt||!supplierState||!can('receipt_supplier_correction'))return;
  if(nameHasDraft())return message('Complete or clear the supplier name correction first.',true);
  if(Number($('#src-quantity').value)!==receipt.quantity||$('#src-reason').value.trim())return message('Save or reload the quantity correction before reviewing a supplier change.',true);
  const chosen=$('#src-new-supplier').value,reason=$('#src-supplier-reason').value.trim();if(!chosen||reason.length<5||reason.length>2000)return message('Choose the correct supplier and enter a reason from 5 to 2000 characters.',true);
  clearSupplierPreview();const token=++epoch;busy=true;controls();message('Reviewing stock supplier and linked records…');
  try{const d=await rpc('get_stock_receipt_supplier_v1',{p_batch_id:receipt.batch_id,p_supplier_id:chosen,p_offset:0});if(token!==epoch||!root||!allowed())return;
   if(!validSupplier(d)||d.target_id!==chosen||d.offset!==0)throw Error('Supplier change could not be verified. Reload the receipt.');
   supplierPreview={...d,reason};$('#src-supplier-preview').innerHTML='<h4>Review supplier change</h4><p><strong>'+esc(supplier({supplier_code:d.supplier_code,supplier_name:d.supplier_name,quantity:d.quantity}))+'</strong> → <strong>'+esc(supplier({supplier_code:d.target_code,supplier_name:d.target_name,quantity:d.quantity}))+'</strong></p><p>'+esc([batch(d),d.invoice_number].filter(Boolean).join(' · '))+'</p><div class="src-supplier-impact">'+[['Original received',d.quantity],['Linked phones',d.phone_count],['Linked jobs',d.job_count],['Return records',d.return_count],['Replacement receipts',d.replacement_count]].map(([label,n])=>'<div><span>'+label+'</span><strong>'+num(n)+'</strong></div>').join('')+'</div><p><strong>Reason:</strong> '+esc(reason)+'</p>';
   $('#src-supplier-confirm').hidden=false;message('Review the batch and supplier above, then confirm the save.');
  }catch(e){if(token===epoch&&root)message(e.message||'Supplier change could not be reviewed.',true);}finally{if(token===epoch&&root){busy=false;controls();}}
 }
 async function saveSupplier(){if(busy||!supplierPreview||!receipt||!can('receipt_supplier_correction'))return;
  if(nameHasDraft())return message('Complete or clear the supplier name correction first.',true);
  const reviewed=supplierPreview;if($('#src-new-supplier').value!==reviewed.target_id||$('#src-supplier-reason').value.trim()!==reviewed.reason){clearSupplierPreview();return message('Review the changed supplier or reason again.',true);}
  const args={p_batch_id:receipt.batch_id,p_supplier_id:reviewed.target_id,p_snapshot:reviewed.snapshot,p_reason:reviewed.reason},signature=JSON.stringify(args),id=requests.get(signature)||crypto.randomUUID();requests.set(signature,id);args.p_request_id=id;
  const token=++epoch;let saved=false;busy=saving=true;controls();message('Saving supplier correction and permanent history…');
  try{const result=await rpc('correct_stock_receipt_supplier_v1',args);if(token!==epoch||!root||!allowed())return;
   if(!result?.saved||result.request_id!==id||result.applied_supplier_id!==reviewed.target_id)throw Error('The supplier save result could not be verified. Retry this same save.');
   validateDetail(result.detail);if(!validSupplier(result.supplier_detail,result.detail.receipt)||result.supplier_detail.supplier_id!==reviewed.target_id||result.detail.receipt.quantity!==reviewed.quantity)throw Error('The corrected receipt could not be verified. Retry this same save.');
   requests.delete(signature);historyOffset=0;drawDetail(result.detail);drawSupplier(result.supplier_detail);
   const selected=new Option([result.supplier_detail.target_code||result.supplier_detail.supplier_code,result.supplier_detail.supplier_name].filter(Boolean).join(' '),result.applied_supplier_id);if(![...$('#src-supplier').options].some(o=>o.value===selected.value))$('#src-supplier').add(selected);$('#src-supplier').value=result.applied_supplier_id;$('#src-search').value='';offset=0;
   window.GREENLOOP_STOCK?.clear();window.dispatchEvent(new CustomEvent('greenloop:workflow-changed',{detail:{source:'receipt_supplier_correction'}}));saved=true;message('Stock supplier corrected. Original quantity, IMEIs and workflow history are preserved.');
  }catch(e){if(token===epoch&&root)message((e.message||'Supplier save was not confirmed.')+' Your reviewed change is retained. Retry the same save to confirm it, or reload to review current stock.',true);}
  finally{saving=false;if(token===epoch&&root){busy=false;controls();}}
  if(saved&&root)await loadList(true);
 }
 async function pageSupplierHistory(next){if(busy||!supplierState||!receipt)return;const token=++epoch;busy=true;controls();message('Loading supplier correction history…');
  try{const d=await rpc('get_stock_receipt_supplier_v1',{p_batch_id:receipt.batch_id,p_supplier_id:null,p_offset:next,p_expected_history_snapshot:supplierState.history_snapshot});if(token!==epoch||!root||!allowed())return;if(!validSupplier(d)||d.offset!==next||d.history_snapshot!==supplierState.history_snapshot)throw Error('Supplier correction history changed. Reload this receipt.');drawSupplierHistory(d);message();}
  catch(e){if(token===epoch&&root){$('#src-supplier-history').replaceChildren();message(e.message||'Supplier history could not load. Reload the receipt.',true);}}finally{if(token===epoch&&root){busy=false;controls();}}
 }

 function nameStatus(text=''){$('#src-name-status').textContent=text;}
 function nameHasDraft(){return !!($('#src-name-panel')?.open&&($('#src-supplier-name').value.trim()||$('#src-name-reason').value.trim()));}
 function clearNameReview(){
  namePreview=null;
  $('#src-name-preview').replaceChildren();
  $('#src-name-confirm').hidden=true;
 }
 function clearName(){
  nameState=null;
  clearNameReview();
  $('#src-supplier-name').value='';
  $('#src-name-reason').value='';
  $('#src-name-current').textContent='';
  $('#src-name-form').hidden=true;
  $('#src-name-history').hidden=true;
  $('#src-name-history-rows').replaceChildren();
  nameStatus();
 }
 function validName(data,expectedOffset){
  const count=n=>Number.isSafeInteger(n)&&n>=0;
  return data?.batch_id===receipt?.batch_id&&data?.supplier_id===receipt?.supplier_id&&
   typeof data.supplier_code==='string'&&(data.supplier_name===null||typeof data.supplier_name==='string')&&
   typeof data.can_rename==='boolean'&&typeof data.may_edit==='boolean'&&count(data.receipt_count)&&data.receipt_count>0&&
   /^[a-f0-9]{32}$/.test(data.snapshot)&&/^[a-f0-9]{32}$/.test(data.history_snapshot)&&data.offset===expectedOffset&&
   count(data.history_total)&&Array.isArray(data.history)&&data.history.length===Math.min(50,Math.max(0,data.history_total-expectedOffset))&&
   data.history.every(h=>typeof h.new_name==='string'&&typeof h.actor_name==='string'&&typeof h.reason==='string'&&Number.isFinite(Date.parse(h.changed_at)));
 }
 function drawName(data){
  nameState=data;
  $('#src-name-current').textContent=[data.supplier_code,data.supplier_name].filter(Boolean).join(' · ');
  $('#src-name-form').hidden=!(data.can_rename&&data.may_edit&&can('receipt_supplier_name_correction'));
  $('#src-name-history').hidden=false;
  $('#src-name-history-rows').innerHTML=data.history.length?data.history.map((h,i)=>
   `<tr><td>${data.offset+i+1}</td><td>${esc(date(h.changed_at))}</td><td>${esc(h.actor_name)}</td><td>${esc(h.old_name||'Not recorded')}</td><td>${esc(h.new_name)}</td><td>${esc(h.reason)}</td></tr>`
  ).join(''):'<tr><td colspan="6">No supplier name corrections recorded.</td></tr>';
  $('#src-name-history-range').textContent=data.history_total?`${data.offset+1}–${Math.min(data.offset+50,data.history_total)} of ${num(data.history_total)}`:'0 corrections';
  if(!data.can_rename)nameStatus('This supplier is archived.');
  else if(!data.may_edit&&can('receipt_supplier_name_correction'))
   nameStatus('Supplier & Customer Names needs Edit access. Ask an authorized admin to enable Edit names in User Access.');
  else nameStatus();
 }
 async function readName(next=0,review=null){
  if(busy||!receipt||!window.GREENLOOP_CAN_VIEW_PARTNER_NAMES)return;
  const token=++epoch;
  busy=true;controls();
  nameStatus(review?'Reviewing supplier name…':'Loading supplier name…');
  try{
   const data=await rpc('get_stock_receipt_supplier_name_v1',{
    p_batch_id:receipt.batch_id,p_new_name:review?.input??null,p_offset:next,
    p_history_snapshot:review||!next?null:nameState?.history_snapshot
   });
   if(token!==epoch||!root||!allowed())return;
   if(!validName(data,next))throw Error('Supplier details changed. Reload this receipt.');
   drawName(data);
   if(review){
    if(!data.can_rename||!data.may_edit||typeof data.new_name!=='string')throw Error('Supplier name review could not be verified.');
    namePreview={...review,snapshot:data.snapshot,supplier:data.supplier_id,newName:data.new_name};
    $('#src-name-preview').innerHTML=`<h4>Review supplier name</h4><p><strong>${esc(data.supplier_name||'Not recorded')}</strong> → <strong>${esc(data.new_name)}</strong></p><p>${num(data.receipt_count)} linked receipt${data.receipt_count===1?'':'s'} will show this name.</p><p><strong>Reason</strong> ${esc(review.reason)}</p>`;
    $('#src-name-confirm').hidden=false;
   }
  }catch(error){
   if(token===epoch&&root){if(!review)clearName();nameStatus(error.message||'Supplier name details could not load.');}
  }finally{if(token===epoch&&root){busy=false;controls();}}
 }
 function reviewName(event){
  event.preventDefault();
  if(busy||!nameState?.may_edit||!can('receipt_supplier_name_correction'))return;
  if(Number($('#src-quantity').value)!==receipt.quantity||$('#src-reason').value.trim()||$('#src-new-supplier').value||$('#src-supplier-reason').value.trim()){
   nameStatus('Complete or clear the other receipt correction before reviewing the supplier name.');
   return;
  }
  const input=$('#src-supplier-name').value.trim(),reason=$('#src-name-reason').value.trim();
  if(!input||reason.length<5){nameStatus('Enter the corrected name and a reason of at least 5 characters.');return;}
  clearNameReview();
  void readName(0,{input,reason});
 }
 async function saveName(){
  if(busy||!namePreview||!nameState?.may_edit||!can('receipt_supplier_name_correction'))return;
  const preview=namePreview;
  if($('#src-supplier-name').value.trim()!==preview.input||$('#src-name-reason').value.trim()!==preview.reason){
   clearNameReview();controls();return;
  }
  if(Number($('#src-quantity').value)!==receipt.quantity||$('#src-reason').value.trim()||$('#src-new-supplier').value||$('#src-supplier-reason').value.trim()){
   nameStatus('Complete or clear the other receipt correction before saving the supplier name.');
   return;
  }
  const batchId=receipt.batch_id;
  const args={p_batch_id:batchId,p_supplier_id:preview.supplier,p_snapshot:preview.snapshot,p_new_name:preview.newName,p_reason:preview.reason};
  const signature=JSON.stringify(args),request=requests.get(signature)||crypto.randomUUID();
  requests.set(signature,request);args.p_request_id=request;
  const token=++epoch;
  let saved=false;
  busy=saving=true;controls();nameStatus('Saving supplier name and correction history…');
  try{
   const result=await rpc('correct_stock_receipt_supplier_name_v1',args);
   if(token!==epoch||!root||!allowed())return;
   if(!result?.saved||result.request_id!==request||result.supplier_id!==preview.supplier||result.applied_name!==preview.newName)
    throw Error('The supplier name save could not be verified.');
   requests.delete(signature);
   clearName();
   window.GREENLOOP_STOCK?.clear();
   window.dispatchEvent(new CustomEvent('greenloop:workflow-changed',{detail:{source:'supplier_name_correction'}}));
   saved=true;
  }catch(error){
   if(token===epoch&&root)nameStatus((error.message||'The save could not be verified.')+' Retry the same save or reload the receipt.');
  }finally{saving=false;if(token===epoch&&root){busy=false;controls();}}
  if(saved&&root){
   const confirmation='Supplier name corrected and recorded in history.';
   await loadList(true,confirmation);
   if(root&&$('#src-receipt').value===batchId){
    await loadDetail(0,false,confirmation);
    if(root&&receipt?.batch_id===batchId)$('#src-name-panel').open=true;
   }
  }
 }

 const $=s=>root?.querySelector(s);
 const batch=r=>window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{batch_number:r.batch_number,receipt_quantity:r.quantity},'Not recorded')||`${r.batch_number}-(${r.quantity})`;
 const supplier=r=>window.GREENLOOP_SUPPLIER_RECEIPT_LABEL?.(r.supplier_code,r.quantity,r.supplier_name)||[`${r.supplier_code||'Not recorded'}-(${r.quantity})`,r.supplier_name].filter(Boolean).join(' ');
 async function rpc(name,args){const r=await window.GREENLOOP_GET_CLIENT().rpc(name,args);if(r.error)throw r.error;return r.data;}
 function message(text='',error=false){if(!root)return;$('#src-message').textContent=text;$('#src-message').hidden=!text;$('#src-message').classList.toggle('is-error',error);}
 function controls(){if(!root)return;root.querySelectorAll('input,select,textarea,button').forEach(e=>e.disabled=busy);
  $('#src-list-prev').disabled=busy||offset===0;$('#src-list-next').disabled=busy||!list||offset+50>=list.total;
  $('#src-history-prev').disabled=busy||historyOffset===0;$('#src-history-next').disabled=busy||historyOffset+50>=historyTotal;
  $('#src-refresh').disabled=busy||!receipt;
  $('#src-save').disabled=busy||!receipt||!can('receipt_quantity_correction');
  $('#src-supplier-review').disabled=busy||!supplierState||!can('receipt_supplier_correction');$('#src-supplier-confirm').disabled=busy||!supplierPreview||!can('receipt_supplier_correction');$('#src-supplier-prev').disabled=busy||supplierOffset===0;$('#src-supplier-next').disabled=busy||!supplierState||supplierOffset+50>=supplierState.history_total;
  $('#src-name-review').disabled=busy||!nameState?.may_edit||!can('receipt_supplier_name_correction');
  $('#src-name-confirm').disabled=busy||!namePreview||!can('receipt_supplier_name_correction');
  $('#src-name-prev').disabled=busy||!nameState?.offset;
  $('#src-name-next').disabled=busy||!nameState||nameState.offset+50>=nameState.history_total;
 }
 function clearReceipt(){clearSupplier();clearName();$('#src-name-panel').open=false;receipt=null;$('#src-detail').hidden=true;$('#src-quantity').value='';$('#src-reason').value='';$('#src-history').replaceChildren();historyOffset=historyTotal=0;controls();}
 function drawHistory(data){historyTotal=data.history_total;
  $('#src-history').innerHTML=data.history.length?data.history.map((h,i)=>`<tr><td>${historyOffset+i+1}</td><td>${esc(date(h.created_at))}</td><td>${esc(h.actor_name)}</td><td>${num(h.old_quantity)}</td><td>${num(h.new_quantity)}</td><td>${esc(h.reason)}</td></tr>`).join(''):'<tr><td colspan="6" class="src-empty">No quantity corrections recorded.</td></tr>';
  $('#src-history-range').textContent=historyTotal?`${historyOffset+1}–${Math.min(historyOffset+50,historyTotal)} of ${num(historyTotal)}`:'0 corrections';controls();
 }
 function drawDetail(data){receipt=data.receipt;$('#src-detail').hidden=false;
  clearName();$('#src-name-panel').open=false;
  $('#src-name-panel').hidden=!window.GREENLOOP_CAN_VIEW_PARTNER_NAMES||!receipt.supplier_id;
  $('#src-name-panel').querySelector('summary').textContent=can('receipt_supplier_name_correction')?'Edit Supplier Name':'Supplier Name History';
  $('#src-reference').textContent=[supplier(receipt),batch(receipt),receipt.invoice_number].filter(Boolean).join(' · ');
  const stats=[['Received quantity',receipt.quantity],['IMEIs entered',receipt.entered],['Returned',receipt.returned],['Replacements received',receipt.replacement_received],['Stock balance',receipt.balance],['Unentered balance',receipt.pending_imei]];
  $('#src-stats').innerHTML=stats.map(([label,n])=>`<div><span>${esc(label)}</span><strong>${num(n)}</strong></div>`).join('');
  $('#src-minimum').textContent=`Minimum allowed: ${num(receipt.minimum_quantity)} · Linked IMEIs, reserved returns and saved stock plans are preserved.`;
  $('#src-form').hidden=!can('receipt_quantity_correction');$('#src-quantity').value=receipt.quantity;$('#src-quantity').min=Math.max(1,receipt.minimum_quantity);$('#src-reason').value='';$('#src-change').textContent='';
  if(receipt.parent_batch_id){$('#src-form').hidden=true;$('#src-minimum').textContent='This is a replacement receipt. Its recorded replacement quantity stays unchanged; select the original stock receipt.';}
  drawHistory(data);
 }
 function validateDetail(data){if(!data?.receipt||typeof data.receipt.snapshot!=='string'||!Number.isInteger(data.receipt.quantity)||!Array.isArray(data.history)||!Number.isInteger(data.history_total))throw Error('Receipt details could not be verified. Refresh and retry.');return data;}
 async function loadList(retain=false,confirmation='Stock supplier corrected. Original quantity, IMEIs and workflow history are preserved.'){if(!root||busy||!allowed())return;const token=++epoch;busy=true;if(!retain)clearReceipt();controls();message('Loading stock receipts...');
  try{const data=await rpc('get_stock_receipt_correction_receipts_v1',{p_supplier_id:$('#src-supplier').value||null,p_query:$('#src-search').value.trim(),p_offset:offset,p_limit:50});if(token!==epoch||!root||!allowed())return;
   if(!Array.isArray(data?.receipts)||!Array.isArray(data.suppliers)||!Number.isInteger(data.total))throw Error('The receipt list could not be verified.');list=data;
   const chosen=$('#src-supplier').value;$('#src-supplier').replaceChildren(new Option('All Suppliers',''));for(const s of data.suppliers)$('#src-supplier').add(new Option([s.supplier_code,s.supplier_name].filter(Boolean).join(' '),s.supplier_id));$('#src-supplier').value=chosen;
   $('#src-receipt').replaceChildren(new Option(data.total?'Choose Stock / Batch / Invoice':'No matching stock receipts',''));for(const r of data.receipts)$('#src-receipt').add(new Option([batch(r),r.invoice_number,supplier(r)].filter(Boolean).join(' · '),r.batch_id));
   if(retain&&receipt){if(![...$('#src-receipt').options].some(o=>o.value===receipt.batch_id))$('#src-receipt').add(new Option([batch(receipt),receipt.invoice_number,supplier(receipt)].filter(Boolean).join(' · '),receipt.batch_id));$('#src-receipt').value=receipt.batch_id;}
   $('#src-list-range').textContent=data.total?`${offset+1}–${Math.min(offset+50,data.total)} of ${num(data.total)} receipts`:'0 receipts';message(retain?confirmation:'');
  }catch(e){if(token===epoch&&root){list=null;$('#src-receipt').replaceChildren(new Option('Receipt list unavailable',''));message(e.message||'Stock receipts could not be loaded.',true);}}
  finally{if(token===epoch&&root){busy=false;controls();}}
 }
 async function loadDetail(nextOffset=0,historyOnly=false,confirmation=''){if(!root||busy||!allowed())return;const id=$('#src-receipt').value;if(!id){clearReceipt();return;}const token=++epoch;busy=true;controls();message('Loading receipt and correction history...');
  try{const results=await Promise.allSettled([rpc('get_stock_receipt_correction_detail_v1',{p_batch_id:id,p_offset:nextOffset}),...(historyOnly?[]:[rpc('get_stock_receipt_supplier_v1',{p_batch_id:id,p_supplier_id:null,p_offset:0})])]);if(token!==epoch||!root||!allowed())return;if(results[0].status==='rejected')throw results[0].reason;const data=validateDetail(results[0].value);historyOffset=nextOffset;if(historyOnly)drawHistory(data);else{drawDetail(data);if(data.receipt.parent_batch_id){clearSupplier();}else drawSupplier(results[1]?.status==='fulfilled'?results[1].value:null);}message(confirmation);}
  catch(e){if(token===epoch&&root){if(!historyOnly)clearReceipt();message(e.message||'Receipt details could not be loaded.',true);}}
  finally{if(token===epoch&&root){busy=false;controls();}}
 }
 async function save(event){event.preventDefault();if(busy||!receipt||!allowed()||!can('receipt_quantity_correction'))return;
  if(nameHasDraft())return message('Complete or clear the supplier name correction before saving a quantity change.',true);
  if(supplierPreview||$('#src-new-supplier').value||$('#src-supplier-reason').value.trim())return message('Complete or clear the supplier correction before saving a quantity change.',true);
  const quantity=Number($('#src-quantity').value),reason=$('#src-reason').value.trim();
  if(!Number.isInteger(quantity)||quantity<1||quantity>2147483647)return message('Enter a positive whole received quantity.',true);
  if(quantity<receipt.minimum_quantity)return message(`Quantity cannot be below ${num(receipt.minimum_quantity)}. Linked IMEIs, reserved returns and saved stock plans are preserved.`,true);
  if(quantity===receipt.quantity)return message('Enter a quantity different from the current received quantity.',true);
  if(reason.length<5||reason.length>2000)return message('Enter a correction reason from 5 to 2000 characters.',true);
  const args={p_batch_id:receipt.batch_id,p_snapshot:receipt.snapshot,p_quantity:quantity,p_reason:reason},signature=JSON.stringify(args),id=requests.get(signature)||crypto.randomUUID();requests.set(signature,id);args.p_request_id=id;
  const token=++epoch;busy=saving=true;controls();message('Saving received quantity and permanent correction history...');
  try{const result=await rpc('correct_stock_receipt_quantity_v1',args);if(token!==epoch||!root||!allowed())return;
   if(!result?.saved||result.request_id!==id||result.applied_quantity!==quantity)throw Error('The save result could not be verified. Retry this same correction to confirm it.');
   const data=validateDetail(result.detail);requests.delete(signature);historyOffset=0;drawDetail(data);const supplierData=await rpc('get_stock_receipt_supplier_v1',{p_batch_id:receipt.batch_id,p_supplier_id:null,p_offset:0}).catch(()=>null);if(token!==epoch||!root||!allowed())return;drawSupplier(supplierData);
   const option=[...$('#src-receipt').options].find(o=>o.value===receipt.batch_id);if(option)option.textContent=[batch(receipt),receipt.invoice_number,supplier(receipt)].filter(Boolean).join(' · ');
   message(`Received quantity corrected to ${num(quantity)}. IMEIs, returns, replacements and workflow records are preserved.`);
   window.GREENLOOP_STOCK?.clear();
  }catch(e){if(token===epoch&&root)message((e.message||'Save was not confirmed.')+' Your entered correction is still here. Retry the same save to confirm it, or reload to review current stock.',true);}
  finally{saving=false;if(token===epoch&&root){busy=false;controls();}}
 }
 function unmount(){clearTimeout(timer);supplierState=supplierPreview=nameState=namePreview=null;supplierOffset=0;epoch++;root?.remove();root=null;receipt=list=null;offset=historyOffset=historyTotal=0;busy=false;}
 function mount(host){unmount();if(!allowed()){host.textContent='Stock Receipt Correction permission is required.';return;}root=document.createElement('section');root.className='src-report';
  root.innerHTML=`<div class="src-controls"><label>Supplier<select id="src-supplier" ${cap}><option value="">All Suppliers</option></select></label><label>Find Stock / Batch / Invoice<input id="src-search" type="search" maxlength="160" placeholder="Batch number, invoice or supplier code" ${cap}></label><label class="src-receipt-picker">Stock / Batch / Invoice<select id="src-receipt" ${cap}><option value="">Choose a stock receipt</option></select></label><div class="src-paging"><button type="button" id="src-list-prev" class="secondary-button" ${cap}>Previous</button><span id="src-list-range"></span><button type="button" id="src-list-next" class="secondary-button" ${cap}>Next</button></div></div>
  <p id="src-message" role="status" hidden></p><section id="src-detail" hidden><div class="src-heading"><div><h3>Received quantity</h3><p id="src-reference"></p></div><button id="src-refresh" class="secondary-button" type="button" ${cap}>Reload receipt</button></div><div id="src-stats" class="src-stats"></div>
  <form id="src-form" class="src-form"><label>Correct received quantity<input id="src-quantity" type="number" min="1" max="2147483647" step="1" required ${writeCap}></label><label class="src-reason">Reason for correction<textarea id="src-reason" minlength="5" maxlength="2000" required placeholder="Example: 1500 was entered by mistake; 1200 units were received." ${writeCap}></textarea></label><button id="src-save" class="primary-button" ${writeCap}>Save quantity correction</button><p id="src-change"></p></form><p id="src-minimum" class="src-note"></p>
  <section id="src-supplier-panel" class="src-supplier-panel" hidden><h3>Change Stock Supplier</h3><p id="src-supplier-status" role="status"></p><form id="src-supplier-form" class="src-form"><label>Current supplier<span id="src-current-supplier"></span></label><label>Correct supplier<select id="src-new-supplier" ${supplierWriteCap}><option value="">Choose correct supplier</option></select></label><label class="src-reason">Reason for supplier correction<textarea id="src-supplier-reason" minlength="5" maxlength="2000" required ${supplierWriteCap}></textarea></label><div class="src-supplier-buttons"><button type="submit" id="src-supplier-review" class="secondary-button" ${supplierWriteCap}>Review supplier change</button><button type="button" id="src-supplier-clear" class="secondary-button" ${supplierWriteCap}>Clear change</button></div><div id="src-supplier-preview"></div><button type="button" id="src-supplier-confirm" class="primary-button" hidden ${supplierWriteCap}>Confirm supplier correction</button></form><h4>Supplier correction history</h4><div class="src-table-scroll"><table data-no-serial><thead><tr><th>S.No</th><th>Date &amp; Time · UAE</th><th>Changed by</th><th>Previous supplier</th><th>Correct supplier</th><th>Reason</th></tr></thead><tbody id="src-supplier-history"></tbody></table></div><div class="src-paging"><button type="button" id="src-supplier-prev" class="secondary-button" ${cap}>Previous</button><span id="src-supplier-range"></span><button type="button" id="src-supplier-next" class="secondary-button" ${cap}>Next</button></div></section>
  <div class="src-history"><h3>Quantity correction history</h3><div class="src-table-scroll"><table><thead><tr><th>S.No</th><th>Corrected · UAE</th><th>Corrected by</th><th>Before</th><th>After</th><th>Reason</th></tr></thead><tbody id="src-history"></tbody></table></div><div class="src-paging"><button id="src-history-prev" class="secondary-button" type="button" ${cap}>Previous</button><span id="src-history-range"></span><button id="src-history-next" class="secondary-button" type="button" ${cap}>Next</button></div></div></section>`;
  host.replaceChildren(root);$('#src-form').addEventListener('submit',save);$('#src-supplier-form').addEventListener('submit',reviewSupplier);$('#src-supplier-confirm').addEventListener('click',saveSupplier);$('#src-supplier-clear').onclick=()=>{clearSupplierPreview();$('#src-new-supplier').value='';$('#src-supplier-reason').value='';message();};$('#src-new-supplier').onchange=clearSupplierPreview;$('#src-supplier-reason').oninput=clearSupplierPreview;$('#src-supplier-prev').onclick=()=>pageSupplierHistory(Math.max(0,supplierOffset-50));$('#src-supplier-next').onclick=()=>pageSupplierHistory(supplierOffset+50);
  $('.src-history').insertAdjacentHTML('beforebegin',`
   <details id="src-name-panel" class="src-supplier-panel src-name-panel" hidden>
    <summary>Edit Supplier Name</summary>
    <p id="src-name-current"></p>
    <p id="src-name-status" role="status"></p>
    <form id="src-name-form" class="src-form" hidden>
     <p>Changes the supplier name on all linked receipts.</p>
     <label>Corrected supplier name<input id="src-supplier-name" required maxlength="200" ${nameWriteCap}></label>
     <label>Reason for name correction<textarea id="src-name-reason" required minlength="5" maxlength="2000" ${nameWriteCap}></textarea></label>
     <div class="src-supplier-buttons">
      <button type="submit" id="src-name-review" class="secondary-button" ${nameWriteCap}>Review name change</button>
      <button type="button" id="src-name-clear" class="secondary-button" ${nameWriteCap}>Clear change</button>
     </div>
     <div id="src-name-preview"></div>
     <button type="button" id="src-name-confirm" class="primary-button" hidden ${nameWriteCap}>Confirm name correction</button>
    </form>
    <div id="src-name-history" hidden>
     <h4>Supplier name correction history</h4>
     <div class="src-table-scroll"><table data-no-serial>
      <thead><tr><th>S.No</th><th>Date &amp; Time · UAE</th><th>Changed by</th><th>Previous name</th><th>Corrected name</th><th>Reason</th></tr></thead>
      <tbody id="src-name-history-rows"></tbody>
     </table></div>
     <div class="src-paging">
      <button type="button" id="src-name-prev" class="secondary-button" ${cap}>Previous</button>
      <span id="src-name-history-range"></span>
      <button type="button" id="src-name-next" class="secondary-button" ${cap}>Next</button>
     </div>
    </div>
   </details>`);
  $('#src-name-panel').addEventListener('toggle',event=>{
   if(busy||!receipt||!root)return;
   if(event.currentTarget.open){void readName();}
   else {clearName();controls();}
  });
  $('#src-name-panel summary').addEventListener('click',event=>{if(busy)event.preventDefault();});
  $('#src-name-form').addEventListener('submit',reviewName);
  $('#src-name-confirm').onclick=saveName;
  $('#src-name-clear').onclick=()=>{
   $('#src-supplier-name').value='';$('#src-name-reason').value='';
   clearNameReview();nameStatus();controls();
  };
  for(const field of [$('#src-supplier-name'),$('#src-name-reason')]){
   field.addEventListener('input',()=>{clearNameReview();nameStatus();controls();});
  }
  $('#src-name-prev').onclick=()=>readName((nameState?.offset??50)-50);
  $('#src-name-next').onclick=()=>readName((nameState?.offset??0)+50);
  $('#src-supplier').addEventListener('change',()=>{offset=0;loadList();});$('#src-receipt').addEventListener('change',()=>loadDetail());
  $('#src-search').addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(()=>{offset=0;loadList();},250);});
  $('#src-list-prev').onclick=()=>{offset=Math.max(0,offset-50);loadList();};$('#src-list-next').onclick=()=>{offset+=50;loadList();};
  $('#src-history-prev').onclick=()=>loadDetail(Math.max(0,historyOffset-50),true);$('#src-history-next').onclick=()=>loadDetail(historyOffset+50,true);$('#src-refresh').onclick=()=>loadDetail();
  $('#src-quantity').oninput=()=>{const q=Number($('#src-quantity').value),delta=q-receipt.quantity;$('#src-change').textContent=Number.isInteger(q)&&q>0?`${num(receipt.quantity)} → ${num(q)} (${delta>0?'+':''}${num(delta)}) · This corrects received quantity; it does not record a Return.`:'';};
  loadList();
 }
 window.addEventListener('greenloop:permissions-changed',unmount);window.addEventListener('greenloop:office-locked',unmount);window.addEventListener('greenloop:signed-out',unmount);
 window.addEventListener('beforeunload',event=>{if(saving){event.preventDefault();event.returnValue='';}});
 window.GREENLOOP_STOCK_RECEIPT_CORRECTION={mount,unmount,isSaving:()=>saving,refresh:()=>receipt?loadDetail():loadList()};
})();
