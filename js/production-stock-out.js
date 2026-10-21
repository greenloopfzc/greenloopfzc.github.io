(() => {
 'use strict';
 const host=document.getElementById('dp-entry-section');if(!host)return;
 const can=k=>window.GREENLOOP_CAN?.(k,'daily_production')===true;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const date=d=>new Intl.DateTimeFormat('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',year:'numeric'}).format(new Date(d+'T12:00:00Z'));
 host.insertAdjacentHTML('afterend',`<section id="dpo-section" class="dp-entry-section dpo-section" hidden><button id="dpo-toggle" class="dp-entry-tile" type="button" data-capability="stock_out_entry" aria-expanded="false" aria-controls="dpo-panel"><span class="dp-card-icon">↗</span><span><strong>Stock Out Entry</strong><small>Record phones taken out · Model / GB / Grade</small></span><span aria-hidden="true">→</span></button><div id="dpo-panel" class="dp-panel dp-entry-panel" hidden><div class="dp-caption"><strong id="dpo-day">Stock Out</strong><span>Out is added to the production calculation. Your counted closing stock stays unchanged.</span></div><form id="dpo-form" class="dpo-entry-line" data-capability="stock_out_entry"><label>Model<select name="model" required aria-label="Stock Out model"></select></label><label>GB<select name="gb" required aria-label="Stock Out GB"></select></label><label>Grade<select name="grade" required aria-label="Stock Out grade"></select></label><label>Out Qty<input name="quantity" type="number" min="1" max="1000000" step="1" required inputmode="numeric" placeholder="Out qty"></label><label>Production date<input name="day" type="date" min="2000-01-01" required></label><button id="dpo-save" class="primary-button" type="submit">Save Out</button></form><p id="dpo-message" class="dp-message" role="status" hidden></p></div></section>`);
 const $=id=>document.getElementById(id),form=$('dpo-form');let current=null,busy=false,pending=null,seq=0;
 function message(text='',ok=false){const el=$('dpo-message');el.textContent=text;el.hidden=!text;el.dataset.state=ok?'success':'error';}
 const rpc=async(name,args={})=>{const r=await window.GREENLOOP_GET_CLIENT().rpc(name,args);if(r.error)throw Object.assign(new Error(r.error.message||'Stock Out could not be loaded.'),{code:r.error.code});return r.data;};
 function lock(){form.querySelectorAll('input,select,button').forEach(e=>e.disabled=busy||!can('stock_out_entry'));form.elements.day.disabled=busy||!can('search');window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.();}
 async function refresh(){if(!can('stock_out_entry')){$('dpo-section').hidden=true;return;}if(busy)return;$('dpo-section').hidden=false;const request=++seq;try{
  const r=await rpc('get_production_stock_out_context_v1');if(request!==seq)return;
  const selected=form.elements.day.value;if(!pending)for(const kind of ['model','gb','grade']){const field=form.elements[kind],id=field.value;field.innerHTML=`<option value="">Choose ${kind==='gb'?'GB':kind}</option>`+r.options.filter(o=>o.kind===kind&&o.active).map(o=>`<option value="${esc(o.id)}">${esc(o.name)}</option>`).join('');field.value=id;}
  if(!pending&&(!selected||selected===current||!can('search')))form.elements.day.value=r.current_day;current=r.current_day;form.elements.day.max=current;$('dpo-day').textContent='Current production date · '+date(current);lock();
 }catch(e){message(e.message);}}
 $('dpo-toggle').addEventListener('click',()=>{if(!can('stock_out_entry'))return;const open=$('dpo-panel').hidden;$('dpo-panel').hidden=!open;$('dpo-toggle').setAttribute('aria-expanded',String(open));if(open)refresh();});
 form.addEventListener('submit',async e=>{e.preventDefault();if(busy||!can('stock_out_entry')||!form.reportValidity())return;const qty=Number(form.elements.quantity.value);if(!Number.isSafeInteger(qty)||qty<1||qty>1000000)return message('Enter a whole Out quantity from 1 to 1,000,000.');
  const args={p_model:form.elements.model.value,p_gb:form.elements.gb.value,p_grade:form.elements.grade.value,p_quantity:qty,p_day:form.elements.day.value};const sig=JSON.stringify(args);if(pending?.sig!==sig)pending={sig,id:crypto.randomUUID()};args.p_request=pending.id;++seq;busy=true;lock();message();let saved=false,rejected=false;
  try{const r=await rpc('save_production_stock_out_v1',args);if(r?.saved!==true)throw new Error('The database did not confirm the Stock Out save.');saved=true;pending=null;form.reset();message(`${qty.toLocaleString('en-GB')} pcs Stock Out saved. Closing stock was not reduced.`,true);}
  catch(err){if(['22023','42501','23503','40001'].includes(err.code)){pending=null;rejected=true;}message(err.message);}finally{busy=false;lock();if(saved||rejected)await refresh();if(saved){window.GREENLOOP_PRODUCTION_PERIOD?.refresh();form.elements.model.focus();}}
 });
 window.GREENLOOP_PRODUCTION_STOCK_OUT={refresh};
 window.addEventListener('focus',()=>refresh());document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
 const poll=setInterval(()=>{if(!document.hidden)refresh();},60000);window.addEventListener('pagehide',()=>clearInterval(poll));
 (async()=>{await window.GREENLOOP_ACCESS_READY;await refresh();})();
})();
