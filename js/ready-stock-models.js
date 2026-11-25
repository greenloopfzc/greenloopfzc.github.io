/* Whole models -> GB x grade -> exact phones, within the originating card scope. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),dialog=$('ready-model-dialog');if(!dialog)return;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const can=()=>window.GREENLOOP_CAN?.('view','ready_stock')===true;
 const gb=v=>v==null?'Not recorded':window.GREENLOOP_STORAGE.label(v);
 const allowEsim=scope=>scope.mode==='current'&&scope.totalEsim===true;
 const within=(qty,total)=>Number.isSafeInteger(qty)&&qty>=0&&qty<=total;
 const sameCell=(server,requested)=>server&&Object.keys(server).length===Object.keys(requested).length&&
  Object.entries(requested).every(([key,value])=>server[key]===value);
 let context=null,cell=null,offset=0,matrixOffset=0,generation=0,result=null;
 function valid(d,view,scope,page,token=null){
  if(!d||d.version!=='20261113-ready-stock-models-1'||d.view!==view||d.mode!==scope.mode||d.date!==(scope.mode==='current'?null:scope.date)||d.offset!==page||d.limit!==50||!Number.isSafeInteger(d.total)||d.total<0||!Number.isSafeInteger(d.phone_total)||d.phone_total<0||!Array.isArray(d.rows)||d.rows.length!==Math.min(50,Math.max(0,d.total-page))||!/^[a-f0-9]{32}$/.test(d.snapshot)||token&&token!==d.snapshot)return false;
  if(view==='models')return new Set(d.rows.map(r=>r.key)).size===d.rows.length&&d.rows.every(r=>typeof r.key==='string'&&r.key&&typeof r.model==='string'&&r.model&&Number.isSafeInteger(r.quantity)&&r.quantity>0)&&d.rows.reduce((n,r)=>n+r.quantity,0)<=d.phone_total;
  if(!Number.isSafeInteger(d.model_total)||d.model_total<0||!Array.isArray(d.grades)||new Set(d.grades.map(g=>g.key)).size!==d.grades.length||d.grades.some(g=>typeof g.key!=='string'||!g.key||typeof g.label!=='string'||!Number.isSafeInteger(g.quantity)||g.quantity<1)||d.grades.reduce((n,g)=>n+g.quantity,0)!==d.model_total)return false;
  if(allowEsim(scope)&&!within(d.model_esim_total,d.model_total))return false;
  if(view==='phones'){
   if(!d.cell||typeof d.cell!=='object')return false;
   if(d.cell.esim===true)return allowEsim(scope)&&d.total<=d.model_esim_total&&d.rows.every(r=>
    /^\d{15}$/.test(r.imei)&&r.model_key===d.model_key&&r.esim_only===true&&
    (!Object.hasOwn(d.cell,'storage_gb')||r.storage_gb===d.cell.storage_gb));
   return d.rows.every(r=>/^\d{15}$/.test(r.imei)&&r.model_key===d.model_key&&
    r.storage_gb===d.cell.storage_gb&&r.grade_key===d.cell.grade_key);
  }
  if(allowEsim(scope)){
   const pageEsim=d.rows.reduce((sum,r)=>sum+r.esim_quantity,0);
   if(d.rows.some(r=>!within(r.esim_quantity,r.quantity))||pageEsim>d.model_esim_total||
    (page===0&&d.rows.length===d.total&&pageEsim!==d.model_esim_total))return false;
  }
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
 function esimQty(quantity,key,label){
  if(!quantity)return '<span class="rsm-zero">0</span>';
  return '<button type="button" class="rsm-quantity" data-model-esim-row="'+key+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-label="'+
    esc('View '+quantity+' e-Sim IMEIs · '+label)+'">'+quantity.toLocaleString('en-GB')+'</button>';
 }
 function draw(){
  const d=result;$('ready-model-title').textContent=d.model+' · '+d.model_total.toLocaleString('en-GB')+' phones';
  const showEsim=allowEsim(context.scope)&&d.model_esim_total>0;
  const storage=cell?.esim===true&&!Object.hasOwn(cell,'storage_gb')?'All GB':gb(cell?.storage_gb);
  const selection=cell?.esim===true?'e-Sim':'Grade '+d.grades.find(g=>g.key===cell?.grade_key)?.label;
  $('ready-model-scope').textContent=context.scope.label+' · '+context.period+(cell?' · '+storage+' · '+selection:'');
  if(!cell){
   $('ready-model-head').innerHTML='<tr><th>S.No</th><th>GB</th>'+d.grades.map(g=>'<th>Grade '+esc(g.label)+'</th>').join('')+'<th>Total</th>'+(showEsim?'<th scope="col">e-Sim</th>':'')+'</tr>';
   $('ready-model-rows').innerHTML=d.rows.map((r,i)=>'<tr><td>'+(offset+i+1)+'</td><th scope="row">'+esc(gb(r.storage_gb))+'</th>'+d.grades.map(g=>'<td>'+qty(r.grades.find(x=>x.grade_key===g.key)?.quantity||0,i,g.key)+'</td>').join('')+'<td class="rsm-row-total">'+r.quantity.toLocaleString('en-GB')+'</td>'+
    (showEsim?'<td>'+esimQty(r.esim_quantity,i,gb(r.storage_gb))+'</td>':'')+'</tr>').join('')+(d.model_total?'<tr class="rsm-total"><th colspan="2" scope="row">Model Total · All GB</th>'+d.grades.map(g=>'<td>'+g.quantity.toLocaleString('en-GB')+'</td>').join('')+'<td>'+d.model_total.toLocaleString('en-GB')+'</td>'+
    (showEsim?'<td>'+esimQty(d.model_esim_total,'all','All GB')+'</td>':'')+'</tr>':'<tr><td colspan="3" class="rsd-empty">This model is no longer in the selected stock.</td></tr>');
   $('ready-model-status').textContent='GB × Grade · Select a quantity to view its exact phones.';$('ready-model-total').textContent='All quantities belong to this card and its selected filters.';
  }else{
   const labels=['S.No','IMEI','Model','GB','Color','Grade','Supplier','Stock / Batch','Invoice','Date'];if(context.scope.mode==='export')labels.push('Box');
   $('ready-model-head').innerHTML='<tr>'+labels.map(x=>'<th>'+x+'</th>').join('')+'</tr>';
   $('ready-model-rows').innerHTML=d.rows.map((r,i)=>{const supplier=window.GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,window.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true?r.supplier_name:null),batch=window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{receipt_quantity:r.planned_quantity})||r.batch_number||'Not recorded';const values=[offset+i+1,r.imei,r.model,gb(r.storage_gb),r.color||'Not recorded',r.final_grade,supplier,batch,r.invoice_number||'Not recorded',r.occurred_at?new Date(r.occurred_at).toLocaleDateString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'Not recorded'];if(context.scope.mode==='export')values.push(r.box_number||'Recorded dispatch');return '<tr>'+values.map((v,j)=>'<td'+(j===1||j===7?' data-gl-copy-identifier':'')+'>'+esc(v)+'</td>').join('')+'</tr>';}).join('');
   $('ready-model-status').textContent=d.total.toLocaleString('en-GB')+' matching phones';$('ready-model-total').textContent=context.scope.activity?'One activity entry per phone per day · Original stock references are preserved.':'One line per IMEI · Original stock references are preserved.';
  }
  $('ready-model-page').textContent=d.total?(offset+1)+'–'+Math.min(offset+d.rows.length,d.total)+' of '+d.total+(cell?' phones':' GB rows'):'0 records';controls();
 }
 async function load(){
  if(!context||!dialog.open||!can())return;const selected=context,chosen=cell,page=offset,id=++generation;result=null;controls(true);$('ready-model-rows').replaceChildren();$('ready-model-head').replaceChildren();$('ready-model-status').textContent='Loading '+(chosen?'phones':'GB / Grade breakdown')+'…';$('ready-model-total').textContent='';$('ready-model-page').textContent='';
  try{
   const s=selected.scope,{data,error}=await(s.activity?GREENLOOP_STOCK_ACTIVITY.request(s.activity,{p_view:chosen?'phones':'breakdown',p_model:selected.row.key,p_cell:chosen,p_offset:page,p_model_snapshot:selected.snapshot}):window.GREENLOOP_GET_CLIENT().rpc('get_ready_stock_models_v1',{p_mode:s.mode,p_date:s.date||null,p_groups:s.groups||null,p_date_from:s.from||null,p_date_to:s.to||null,p_view:chosen?'phones':'breakdown',p_model:selected.row.key,p_cell:chosen,p_offset:page,p_limit:50,p_expected_snapshot:selected.snapshot}));if(error)throw error;
   if(id!==generation||selected!==context||chosen!==cell||!dialog.open||!can())return;
   if(!valid(data,chosen?'phones':'breakdown',s,page,selected.snapshot)||data.model_key!==selected.row.key||data.model_total!==selected.row.quantity||chosen&&(!sameCell(data.cell,chosen)||data.total!==selected.cellQuantity))throw Error('Model quantities could not be verified. Refresh Model Summary.');
   result=data;draw();
  }catch(e){if(id===generation&&context&&dialog.open&&can()){$('ready-model-status').textContent=e.message||'Model details could not load. Refresh Model Summary.';$('ready-model-rows').replaceChildren();}}
  finally{if(id===generation)controls(false);}
 }
 function open(scope,row,snapshot,period){if(!can())return;close();context={scope,row,snapshot,period};offset=matrixOffset=0;cell=null;$('ready-model-title').textContent=row.model+' · '+row.quantity+' phones';$('ready-model-scope').textContent=scope.label+' · '+period;dialog.showModal();void load();}
 $('ready-model-rows').addEventListener('click',e=>{
  const button=e.target.closest('[data-model-cell-row],[data-model-esim-row]');
  if(!button||!result||cell||!context||!can()||dialog.getAttribute('aria-busy')==='true')return;
  let chosen,quantity;
  if(button.hasAttribute('data-model-esim-row')){
   if(!allowEsim(context.scope))return;
   const key=button.dataset.modelEsimRow;
   if(key==='all'){chosen={esim:true};quantity=result.model_esim_total;}
   else{const row=result.rows[Number(key)];if(!row)return;chosen={esim:true,storage_gb:row.storage_gb};quantity=row.esim_quantity;}
  }else{
   const row=result.rows[Number(button.dataset.modelCellRow)],key=button.dataset.modelCellGrade;
   if(!row)return;
   chosen={storage_gb:row.storage_gb,grade_key:key};quantity=row.grades.find(g=>g.grade_key===key)?.quantity;
  }
  if(!quantity)return;
  context.cellQuantity=quantity;matrixOffset=offset;cell=chosen;offset=0;void load();
 });
 $('ready-model-prev').onclick=()=>{if(offset){offset=Math.max(0,offset-50);void load();}};$('ready-model-next').onclick=()=>{if(result&&offset+result.rows.length<result.total){offset+=50;void load();}};$('ready-model-back').onclick=()=>{cell=null;offset=matrixOffset;void load();};$('ready-model-close').onclick=close;
 $('ready-model-refresh').onclick=()=>{close();window.dispatchEvent(new Event('greenloop:ready-models-refresh'));};dialog.addEventListener('cancel',e=>{e.preventDefault();close();});dialog.addEventListener('close',()=>{if(context&&!dialog.open)close();});
 for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,close);
 window.GREENLOOP_READY_MODELS={valid,renderList,open,close};
})();
