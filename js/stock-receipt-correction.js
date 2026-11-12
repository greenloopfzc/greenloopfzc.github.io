(() => {
 'use strict';
 const can=c=>window.GREENLOOP_CAN?.(c,'reports')===true;
 const allowed=()=>can('view')&&can('report_receipt_correction');
 const cap='data-capability="report_receipt_correction" data-capability-page="reports" data-search-read-only';
 const writeCap='data-capability="receipt_quantity_correction" data-capability-page="reports"';
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const num=v=>Number(v||0).toLocaleString('en-GB');
 const date=v=>new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'});
 let root=null,epoch=0,busy=false,saving=false,receipt=null,list=null,offset=0,historyOffset=0,historyTotal=0,timer,requests=new Map();
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
 }
 function clearReceipt(){receipt=null;$('#src-detail').hidden=true;$('#src-quantity').value='';$('#src-reason').value='';$('#src-history').replaceChildren();historyOffset=historyTotal=0;controls();}
 function drawHistory(data){historyTotal=data.history_total;
  $('#src-history').innerHTML=data.history.length?data.history.map((h,i)=>`<tr><td>${historyOffset+i+1}</td><td>${esc(date(h.created_at))}</td><td>${esc(h.actor_name)}</td><td>${num(h.old_quantity)}</td><td>${num(h.new_quantity)}</td><td>${esc(h.reason)}</td></tr>`).join(''):'<tr><td colspan="6" class="src-empty">No quantity corrections recorded.</td></tr>';
  $('#src-history-range').textContent=historyTotal?`${historyOffset+1}–${Math.min(historyOffset+50,historyTotal)} of ${num(historyTotal)}`:'0 corrections';controls();
 }
 function drawDetail(data){receipt=data.receipt;$('#src-detail').hidden=false;
  $('#src-reference').textContent=[supplier(receipt),batch(receipt),receipt.invoice_number].filter(Boolean).join(' · ');
  const stats=[['Received quantity',receipt.quantity],['IMEIs entered',receipt.entered],['Returned',receipt.returned],['Replacements received',receipt.replacement_received],['Stock balance',receipt.balance],['Unentered balance',receipt.pending_imei]];
  $('#src-stats').innerHTML=stats.map(([label,n])=>`<div><span>${esc(label)}</span><strong>${num(n)}</strong></div>`).join('');
  $('#src-minimum').textContent=`Minimum allowed: ${num(receipt.minimum_quantity)} · Linked IMEIs, reserved returns and saved stock plans are preserved.`;
  $('#src-form').hidden=!can('receipt_quantity_correction');$('#src-quantity').value=receipt.quantity;$('#src-quantity').min=Math.max(1,receipt.minimum_quantity);$('#src-reason').value='';$('#src-change').textContent='';
  if(receipt.parent_batch_id){$('#src-form').hidden=true;$('#src-minimum').textContent='This is a replacement receipt. Its recorded replacement quantity stays unchanged; select the original stock receipt.';}
  drawHistory(data);
 }
 function validateDetail(data){if(!data?.receipt||typeof data.receipt.snapshot!=='string'||!Number.isInteger(data.receipt.quantity)||!Array.isArray(data.history)||!Number.isInteger(data.history_total))throw Error('Receipt details could not be verified. Refresh and retry.');return data;}
 async function loadList(){if(!root||busy||!allowed())return;const token=++epoch;busy=true;clearReceipt();controls();message('Loading stock receipts...');
  try{const data=await rpc('get_stock_receipt_correction_receipts_v1',{p_supplier_id:$('#src-supplier').value||null,p_query:$('#src-search').value.trim(),p_offset:offset,p_limit:50});if(token!==epoch||!root||!allowed())return;
   if(!Array.isArray(data?.receipts)||!Array.isArray(data.suppliers)||!Number.isInteger(data.total))throw Error('The receipt list could not be verified.');list=data;
   const chosen=$('#src-supplier').value;$('#src-supplier').replaceChildren(new Option('All Suppliers',''));for(const s of data.suppliers)$('#src-supplier').add(new Option([s.supplier_code,s.supplier_name].filter(Boolean).join(' '),s.supplier_id));$('#src-supplier').value=chosen;
   $('#src-receipt').replaceChildren(new Option(data.total?'Choose Stock / Batch / Invoice':'No matching stock receipts',''));for(const r of data.receipts)$('#src-receipt').add(new Option([batch(r),r.invoice_number,supplier(r)].filter(Boolean).join(' · '),r.batch_id));
   $('#src-list-range').textContent=data.total?`${offset+1}–${Math.min(offset+50,data.total)} of ${num(data.total)} receipts`:'0 receipts';message();
  }catch(e){if(token===epoch&&root){list=null;$('#src-receipt').replaceChildren(new Option('Receipt list unavailable',''));message(e.message||'Stock receipts could not be loaded.',true);}}
  finally{if(token===epoch&&root){busy=false;controls();}}
 }
 async function loadDetail(nextOffset=0,historyOnly=false){if(!root||busy||!allowed())return;const id=$('#src-receipt').value;if(!id){clearReceipt();return;}const token=++epoch;busy=true;controls();message('Loading receipt and correction history...');
  try{const data=validateDetail(await rpc('get_stock_receipt_correction_detail_v1',{p_batch_id:id,p_offset:nextOffset}));if(token!==epoch||!root||!allowed())return;historyOffset=nextOffset;if(historyOnly)drawHistory(data);else drawDetail(data);message();}
  catch(e){if(token===epoch&&root){if(!historyOnly)clearReceipt();message(e.message||'Receipt details could not be loaded.',true);}}
  finally{if(token===epoch&&root){busy=false;controls();}}
 }
 async function save(event){event.preventDefault();if(busy||!receipt||!allowed()||!can('receipt_quantity_correction'))return;
  const quantity=Number($('#src-quantity').value),reason=$('#src-reason').value.trim();
  if(!Number.isInteger(quantity)||quantity<1||quantity>2147483647)return message('Enter a positive whole received quantity.',true);
  if(quantity<receipt.minimum_quantity)return message(`Quantity cannot be below ${num(receipt.minimum_quantity)}. Linked IMEIs, reserved returns and saved stock plans are preserved.`,true);
  if(quantity===receipt.quantity)return message('Enter a quantity different from the current received quantity.',true);
  if(reason.length<5||reason.length>2000)return message('Enter a correction reason from 5 to 2000 characters.',true);
  const args={p_batch_id:receipt.batch_id,p_snapshot:receipt.snapshot,p_quantity:quantity,p_reason:reason},signature=JSON.stringify(args),id=requests.get(signature)||crypto.randomUUID();requests.set(signature,id);args.p_request_id=id;
  const token=++epoch;busy=saving=true;controls();message('Saving received quantity and permanent correction history...');
  try{const result=await rpc('correct_stock_receipt_quantity_v1',args);if(token!==epoch||!root||!allowed())return;
   if(!result?.saved||result.request_id!==id||result.applied_quantity!==quantity)throw Error('The save result could not be verified. Retry this same correction to confirm it.');
   const data=validateDetail(result.detail);requests.delete(signature);historyOffset=0;drawDetail(data);
   const option=[...$('#src-receipt').options].find(o=>o.value===receipt.batch_id);if(option)option.textContent=[batch(receipt),receipt.invoice_number,supplier(receipt)].filter(Boolean).join(' · ');
   message(`Received quantity corrected to ${num(quantity)}. IMEIs, returns, replacements and workflow records are preserved.`);
   window.GREENLOOP_STOCK?.clear();
  }catch(e){if(token===epoch&&root)message((e.message||'Save was not confirmed.')+' Your entered correction is still here. Retry the same save to confirm it, or reload to review current stock.',true);}
  finally{saving=false;if(token===epoch&&root){busy=false;controls();}}
 }
 function unmount(){clearTimeout(timer);epoch++;root?.remove();root=null;receipt=list=null;offset=historyOffset=historyTotal=0;busy=false;}
 function mount(host){unmount();if(!allowed()){host.textContent='Stock Receipt Correction permission is required.';return;}root=document.createElement('section');root.className='src-report';
  root.innerHTML=`<div class="src-controls"><label>Supplier<select id="src-supplier" ${cap}><option value="">All Suppliers</option></select></label><label>Find Stock / Batch / Invoice<input id="src-search" type="search" maxlength="160" placeholder="Batch number, invoice or supplier code" ${cap}></label><label class="src-receipt-picker">Stock / Batch / Invoice<select id="src-receipt" ${cap}><option value="">Choose a stock receipt</option></select></label><div class="src-paging"><button type="button" id="src-list-prev" class="secondary-button" ${cap}>Previous</button><span id="src-list-range"></span><button type="button" id="src-list-next" class="secondary-button" ${cap}>Next</button></div></div>
  <p id="src-message" role="status" hidden></p><section id="src-detail" hidden><div class="src-heading"><div><h3>Received quantity</h3><p id="src-reference"></p></div><button id="src-refresh" class="secondary-button" type="button" ${cap}>Reload receipt</button></div><div id="src-stats" class="src-stats"></div>
  <form id="src-form" class="src-form"><label>Correct received quantity<input id="src-quantity" type="number" min="1" max="2147483647" step="1" required ${writeCap}></label><label class="src-reason">Reason for correction<textarea id="src-reason" minlength="5" maxlength="2000" required placeholder="Example: 1500 was entered by mistake; 1200 units were received." ${writeCap}></textarea></label><button id="src-save" class="primary-button" ${writeCap}>Save quantity correction</button><p id="src-change"></p></form><p id="src-minimum" class="src-note"></p>
  <div class="src-history"><h3>Correction history</h3><div class="src-table-scroll"><table><thead><tr><th>S.No</th><th>Corrected · UAE</th><th>Corrected by</th><th>Before</th><th>After</th><th>Reason</th></tr></thead><tbody id="src-history"></tbody></table></div><div class="src-paging"><button id="src-history-prev" class="secondary-button" type="button" ${cap}>Previous</button><span id="src-history-range"></span><button id="src-history-next" class="secondary-button" type="button" ${cap}>Next</button></div></div></section>`;
  host.replaceChildren(root);$('#src-form').addEventListener('submit',save);
  $('#src-supplier').addEventListener('change',()=>{offset=0;loadList();});$('#src-receipt').addEventListener('change',()=>loadDetail());
  $('#src-search').addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(()=>{offset=0;loadList();},250);});
  $('#src-list-prev').onclick=()=>{offset=Math.max(0,offset-50);loadList();};$('#src-list-next').onclick=()=>{offset+=50;loadList();};
  $('#src-history-prev').onclick=()=>loadDetail(Math.max(0,historyOffset-50),true);$('#src-history-next').onclick=()=>loadDetail(historyOffset+50,true);$('#src-refresh').onclick=()=>loadDetail();
  $('#src-quantity').oninput=()=>{const q=Number($('#src-quantity').value),delta=q-receipt.quantity;$('#src-change').textContent=Number.isInteger(q)&&q>0?`${num(receipt.quantity)} → ${num(q)} (${delta>0?'+':''}${num(delta)}) · This corrects received quantity; it does not record a Return.`:'';};
  loadList();
 }
 window.addEventListener('greenloop:office-locked',unmount);window.addEventListener('greenloop:signed-out',unmount);
 window.addEventListener('beforeunload',event=>{if(saving){event.preventDefault();event.returnValue='';}});
 window.GREENLOOP_STOCK_RECEIPT_CORRECTION={mount,unmount,isSaving:()=>saving,refresh:()=>receipt?loadDetail():loadList()};
})();
