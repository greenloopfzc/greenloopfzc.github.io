/* Whole models -> GB x grade -> exact phones, within the originating card scope. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),dialog=$('ready-model-dialog');if(!dialog)return;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const can=()=>window.GREENLOOP_CAN?.('view','ready_stock')===true;
 const gb=v=>v==null?'Not recorded':window.GREENLOOP_STORAGE.label(v);
 let context=null,cell=null,offset=0,matrixOffset=0,generation=0,result=null;
 function valid(d,view,scope,page,token=null){
  if(!d||d.version!=='20261113-ready-stock-models-1'||d.view!==view||d.mode!==scope.mode||d.date!==(scope.mode==='current'?null:scope.date)||d.offset!==page||d.limit!==50||!Number.isSafeInteger(d.total)||d.total<0||!Number.isSafeInteger(d.phone_total)||d.phone_total<0||!Array.isArray(d.rows)||d.rows.length!==Math.min(50,Math.max(0,d.total-page))||!/^[a-f0-9]{32}$/.test(d.snapshot)||token&&token!==d.snapshot)return false;
  if(view==='models')return new Set(d.rows.map(r=>r.key)).size===d.rows.length&&d.rows.every(r=>typeof r.key==='string'&&r.key&&typeof r.model==='string'&&r.model&&Number.isSafeInteger(r.quantity)&&r.quantity>0)&&d.rows.reduce((n,r)=>n+r.quantity,0)<=d.phone_total;
  if(!Number.isSafeInteger(d.model_total)||d.model_total<0||!Array.isArray(d.grades)||new Set(d.grades.map(g=>g.key)).size!==d.grades.length||d.grades.some(g=>typeof g.key!=='string'||!g.key||typeof g.label!=='string'||!Number.isSafeInteger(g.quantity)||g.quantity<1)||d.grades.reduce((n,g)=>n+g.quantity,0)!==d.model_total)return false;
  if(view==='phones')return d.rows.every(r=>/^\d{15}$/.test(r.imei)&&r.model_key===d.model_key&&r.storage_gb===d.cell.storage_gb&&r.grade_key===d.cell.grade_key);
  return new Set(d.rows.map(r=>r.storage_gb)).size===d.rows.length&&d.rows.every(r=>(r.storage_gb===null||Number.isSafeInteger(r.storage_gb))&&Number.isSafeInteger(r.quantity)&&r.quantity>0&&Array.isArray(r.grades)&&new Set(r.grades.map(g=>g.grade_key)).size===r.grades.length&&r.grades.every(g=>d.grades.some(x=>x.key===g.grade_key)&&Number.isSafeInteger(g.quantity)&&g.quantity>0)&&r.grades.reduce((n,g)=>n+g.quantity,0)===r.quantity);
 }
 function modelButton(r,i){return '<button type="button" class="rsg-model" data-ready-model="'+i+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-haspopup="dialog">'+esc(r.model)+'</button>';}
 function renderList(data,page){
  $('ready-groups-head').innerHTML='<tr><th>S.No</th><th>Model</th><th>Total Phones</th></tr>';
  $('ready-groups-rows').innerHTML=data.rows.length?data.rows.map((r,i)=>'<tr><td>'+(page+i+1)+'</td><td>'+modelButton(r,i)+'</td><td>'+r.quantity.toLocaleString('en-GB')+'</td></tr>').join(''):'<tr><td colspan="3" class="rsd-empty">No models match this card and filters.</td></tr>';
  $('ready-groups-total').textContent='Total Qty: '+data.phone_total.toLocaleString('en-GB')+' phones';
  $('ready-groups-status').textContent=data.total+' models · Select a model for its GB / Grade breakdown';
  $('ready-groups-page').textContent=data.total?(page+1)+'–'+Math.min(page+data.rows.length,data.total)+' of '+data.total+' models':'0 models';
  $('ready-groups-previous').disabled=page===0;$('ready-groups-next').disabled=page+data.rows.length>=data.total;$('ready-groups-back').hidden=true;
 }
 function close(){generation++;context=null;cell=null;result=null;if(dialog.open)dialog.close();$('ready-model-head').replaceChildren();$('ready-model-rows').replaceChildren();$('ready-model-title').textContent='Model breakdown';$('ready-model-scope').textContent='';$('ready-model-status').textContent='';$('ready-model-total').textContent='';$('ready-model-page').textContent='';}
 function controls(loading=false){dialog.setAttribute('aria-busy',String(loading));$('ready-model-prev').disabled=loading||!result||offset===0;$('ready-model-next').disabled=loading||!result||offset+result.rows.length>=result.total;$('ready-model-back').hidden=!cell;$('ready-model-back').disabled=loading;$('ready-model-refresh').disabled=loading;}
 const qty=(n,row,grade)=>n?'<button type="button" class="rsm-quantity" data-model-cell-row="'+row+'" data-model-cell-grade="'+esc(grade)+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-label="'+n+' phones, '+esc(gb(result.rows[row].storage_gb))+', Grade '+esc(result.grades.find(g=>g.key===grade)?.label)+'">'+n.toLocaleString('en-GB')+'</button>':'<span class="rsm-zero">0</span>';
 function draw(){
  const d=result;$('ready-model-title').textContent=d.model+' · '+d.model_total.toLocaleString('en-GB')+' phones';
  $('ready-model-scope').textContent=context.scope.label+' · '+context.period+(cell?' · '+gb(cell.storage_gb)+' · Grade '+d.grades.find(g=>g.key===cell.grade_key)?.label:'');
  if(!cell){
   $('ready-model-head').innerHTML='<tr><th>S.No</th><th>GB</th>'+d.grades.map(g=>'<th>Grade '+esc(g.label)+'</th>').join('')+'<th>Total</th></tr>';
   $('ready-model-rows').innerHTML=d.rows.map((r,i)=>'<tr><td>'+(offset+i+1)+'</td><th scope="row">'+esc(gb(r.storage_gb))+'</th>'+d.grades.map(g=>'<td>'+qty(r.grades.find(x=>x.grade_key===g.key)?.quantity||0,i,g.key)+'</td>').join('')+'<td class="rsm-row-total">'+r.quantity.toLocaleString('en-GB')+'</td></tr>').join('')+(d.model_total?'<tr class="rsm-total"><th colspan="2" scope="row">Model Total · All GB</th>'+d.grades.map(g=>'<td>'+g.quantity.toLocaleString('en-GB')+'</td>').join('')+'<td>'+d.model_total.toLocaleString('en-GB')+'</td></tr>':'<tr><td colspan="3" class="rsd-empty">This model is no longer in the selected stock.</td></tr>');
   $('ready-model-status').textContent='GB × Grade · Select a quantity to view its exact phones.';$('ready-model-total').textContent='All quantities belong to this card and its selected filters.';
  }else{
   const labels=['S.No','IMEI','Model','GB','Color','Grade','Supplier','Stock / Batch','Invoice','Date'];if(context.scope.mode==='export')labels.push('Box');
   $('ready-model-head').innerHTML='<tr>'+labels.map(x=>'<th>'+x+'</th>').join('')+'</tr>';
   $('ready-model-rows').innerHTML=d.rows.map((r,i)=>{const supplier=window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true?r.supplier_name:null),batch=window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{receipt_quantity:r.planned_quantity})||r.batch_number||'Not recorded';const values=[offset+i+1,r.imei,r.model,gb(r.storage_gb),r.color||'Not recorded',r.final_grade,supplier,batch,r.invoice_number||'Not recorded',r.occurred_at?new Date(r.occurred_at).toLocaleDateString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'Not recorded'];if(context.scope.mode==='export')values.push(r.box_number||'Recorded dispatch');return '<tr>'+values.map((v,j)=>'<td'+(j===1||j===7?' data-gl-copy-identifier':'')+'>'+esc(v)+'</td>').join('')+'</tr>';}).join('');
   $('ready-model-status').textContent=d.total.toLocaleString('en-GB')+' matching phones';$('ready-model-total').textContent='One line per IMEI · Original stock references are preserved.';
  }
  $('ready-model-page').textContent=d.total?(offset+1)+'–'+Math.min(offset+d.rows.length,d.total)+' of '+d.total+(cell?' phones':' GB rows'):'0 records';controls();
 }
 async function load(){
  if(!context||!dialog.open||!can())return;const selected=context,chosen=cell,page=offset,id=++generation;result=null;controls(true);$('ready-model-rows').replaceChildren();$('ready-model-head').replaceChildren();$('ready-model-status').textContent='Loading '+(chosen?'phones':'GB / Grade breakdown')+'…';$('ready-model-total').textContent='';$('ready-model-page').textContent='';
  try{
   const s=selected.scope,{data,error}=await window.GREENLOOP_GET_CLIENT().rpc('get_ready_stock_models_v1',{p_mode:s.mode,p_date:s.date||null,p_groups:s.groups||null,p_date_from:s.from||null,p_date_to:s.to||null,p_view:chosen?'phones':'breakdown',p_model:selected.row.key,p_cell:chosen,p_offset:page,p_limit:50,p_expected_snapshot:selected.snapshot});if(error)throw error;
   if(id!==generation||selected!==context||chosen!==cell||!dialog.open||!can())return;
   if(!valid(data,chosen?'phones':'breakdown',s,page,selected.snapshot)||data.model_key!==selected.row.key||data.model_total!==selected.row.quantity||chosen&&(JSON.stringify(data.cell)!==JSON.stringify(chosen)&&!(data.cell.storage_gb===chosen.storage_gb&&data.cell.grade_key===chosen.grade_key)||data.total!==selected.cellQuantity))throw Error('Model quantities could not be verified. Refresh Model Summary.');
   result=data;draw();
  }catch(e){if(id===generation&&context&&dialog.open&&can()){$('ready-model-status').textContent=e.message||'Model details could not load. Refresh Model Summary.';$('ready-model-rows').replaceChildren();}}
  finally{if(id===generation)controls(false);}
 }
 function open(scope,row,snapshot,period){if(!can())return;close();context={scope,row,snapshot,period};offset=matrixOffset=0;cell=null;$('ready-model-title').textContent=row.model+' · '+row.quantity+' phones';$('ready-model-scope').textContent=scope.label+' · '+period;dialog.showModal();void load();}
 $('ready-model-rows').addEventListener('click',e=>{const b=e.target.closest('[data-model-cell-row]');if(!b||!result||cell||dialog.getAttribute('aria-busy')==='true')return;const row=result.rows[Number(b.dataset.modelCellRow)],key=b.dataset.modelCellGrade,quantity=row?.grades.find(g=>g.grade_key===key)?.quantity;if(!quantity)return;context.cellQuantity=quantity;matrixOffset=offset;cell={storage_gb:row.storage_gb,grade_key:key};offset=0;void load();});
 $('ready-model-prev').onclick=()=>{if(offset){offset=Math.max(0,offset-50);void load();}};$('ready-model-next').onclick=()=>{if(result&&offset+result.rows.length<result.total){offset+=50;void load();}};$('ready-model-back').onclick=()=>{cell=null;offset=matrixOffset;void load();};$('ready-model-close').onclick=close;
 $('ready-model-refresh').onclick=()=>{close();window.dispatchEvent(new Event('greenloop:ready-models-refresh'));};dialog.addEventListener('cancel',e=>{e.preventDefault();close();});dialog.addEventListener('close',()=>{if(context&&!dialog.open)close();});
 for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,close);
 window.GREENLOOP_READY_MODELS={valid,renderList,open,close};
})();
