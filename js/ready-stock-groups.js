/* Card -> stock groups -> exact group's phones. Each server page is bounded. */
(() => {
  'use strict';
  const $=id=>document.getElementById(id),dialog=$('ready-groups-dialog');if(!dialog)return;
  let scope=null,group=null,groupRow=null,offset=0,summaryOffset=0,ticket=0,rows=[],live=true,source=null,showColor=false,groupColor=false,lastData=null;
  const allowed=()=>live&&window.GREENLOOP_CAN?.('view','ready_stock'),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const storage=v=>v==null?'—':GREENLOOP_STORAGE.label(v),batch=r=>window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{batch_number:r.batch_number,receipt_quantity:r.planned_quantity})||r.batch_number||'—';
  const supplier=r=>GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,r.supplier_name),identifier=v=>'<span data-gl-copy-identifier>'+esc(v)+'</span>';
  function close(){++ticket;scope=null;group=null;rows=[];lastData=null;if(dialog.open)dialog.close();$('ready-groups-rows').replaceChildren();if(source){source.classList.remove('is-selected');source.setAttribute('aria-expanded','false');source=null;}}
  function colorControl(){const b=$('ready-groups-color');b.textContent=showColor?'Hide Color':'Show Color';b.setAttribute('aria-pressed',String(showColor));}
  function render(data){
    lastData=data;colorControl();
    const labels=group?['S.No','IMEI','Model','GB']:['S.No','Model','GB'];if(showColor)labels.push('Color');labels.push('Grade','Stock / Batch','Supplier',group?'Time':'Qty');if(group&&scope.mode==='export')labels.push('Box');
    $('ready-groups-head').innerHTML='<tr>'+labels.map(x=>'<th scope="col">'+esc(x)+'</th>').join('')+'</tr>';
    rows=data.rows;
    $('ready-groups-rows').innerHTML=rows.length?rows.map((r,i)=>{
      const model=group?esc(r.model):'<button class="rsg-model" type="button" data-stock-group="'+i+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-label="'+esc(['View phones: '+r.model,storage(r.storage_gb),showColor?(r.color||'Not recorded'):null,r.final_grade,batch(r)].filter(Boolean).join(', '))+'">'+esc(r.model)+'</button>';
      const values=[String(offset+i+1)];if(group)values.push(identifier(r.imei));values.push(model,esc(storage(r.storage_gb)));if(showColor)values.push(esc(r.color||'—'));values.push(esc(r.final_grade),identifier(batch(r)),esc(supplier(r)));
      if(group){values.push(esc(r.occurred_at?new Date(r.occurred_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',hour:'2-digit',minute:'2-digit',hour12:true}):'—'));if(scope.mode==='export')values.push(esc(r.box_number||'Recorded dispatch'));}else values.push(esc(r.quantity));
      return '<tr>'+values.map((v,j)=>'<td data-label="'+esc(labels[j])+'">'+v+'</td>').join('')+'</tr>';
    }).join(''):'<tr><td colspan="'+labels.length+'" class="rsd-empty">No '+(group?'phones':'stock groups')+' match this selection.</td></tr>';
    $('ready-groups-total').textContent=group?'Group total: '+data.total+' phones':'Total Qty: '+data.phone_total+' phones';
    $('ready-groups-status').textContent=group?[groupRow.model,storage(groupRow.storage_gb),showColor?(groupColor?(groupRow.color||'Not recorded'):'All colors'):null,'Grade '+groupRow.final_grade,batch(groupRow)].filter(Boolean).join(' · '):data.total+' stock groups · '+(showColor?'Colors shown':'Colors combined')+' · Select a model to view its phones';
    $('ready-groups-page').textContent=data.total?`${offset+1}–${Math.min(offset+rows.length,data.total)} of ${data.total}`:'0 '+(group?'phones':'groups');
    $('ready-groups-previous').disabled=offset===0;$('ready-groups-next').disabled=offset+rows.length>=data.total;
    $('ready-groups-back').hidden=!group;
  }
  async function load(){
    if(!scope||!allowed()||!dialog.open)return;const id=++ticket,selected=scope,key=group,page=offset,color=key?groupColor:showColor;
    lastData=null;$('ready-groups-color').disabled=true;
    dialog.setAttribute('aria-busy','true');$('ready-groups-previous').disabled=$('ready-groups-next').disabled=true;$('ready-groups-status').textContent='Loading '+(group?'phones':'stock summary')+'…';$('ready-groups-rows').replaceChildren();$('ready-groups-total').textContent='';$('ready-groups-page').textContent='';
    try{
      // An empty grade card still opens a useful empty popup, without sending invalid empty groups.
      if(selected.mode==='current'&&Array.isArray(selected.groups)&&!selected.groups.length){render({rows:[],total:0,phone_total:0});return;}
      const{data,error}=await GREENLOOP_GET_CLIENT().rpc('get_ready_stock_color_groups_v1',{p_mode:selected.mode,p_date:selected.date||null,p_groups:selected.groups||null,p_date_from:selected.from||null,p_date_to:selected.to||null,p_group:key,p_offset:page,p_limit:50,p_show_color:color});if(error)throw error;
      if(id!==ticket||!allowed()||!dialog.open||selected!==scope)return;
      if(!data||data.show_color!==color||data.mode!==selected.mode||data.view!==(key?'phones':'groups')||data.offset!==page||data.limit!==50||![data.total,data.phone_total].every(n=>Number.isSafeInteger(n)&&n>=0)||!Array.isArray(data.rows)||data.rows.length!==Math.min(50,Math.max(0,data.total-page))||selected.mode!=='current'&&data.date!==selected.date)throw Error('Stock summary could not be verified. Refresh and try again.');
      if(data.rows.some(r=>!r.model||typeof r.final_grade!=='string'||(key?!/^\d{15}$/.test(r.imei):!Array.isArray(r.group_key)||r.group_key.length!==6||!Number.isSafeInteger(r.quantity)||r.quantity<1)))throw Error('Stock details could not be verified.');
      if(page&&page>=data.total){offset=Math.max(0,Math.floor((data.total-1)/50)*50);return await load();}render(data);
    }catch(e){if(id===ticket&&allowed()&&dialog.open){$('ready-groups-status').textContent=e.message||'Stock details could not load. Refresh to retry.';$('ready-groups-rows').replaceChildren();$('ready-groups-total').textContent='';}}
    finally{if(id===ticket){dialog.removeAttribute('aria-busy');$('ready-groups-color').disabled=false;}}
  }
  function open(next){
    if(!allowed()||!next||!['current','ready','export'].includes(next.mode))return;close();showColor=groupColor=false;colorControl();source=next.source||null;scope={mode:next.mode,date:next.date||null,groups:next.groups||null,from:next.from||null,to:next.to||null,label:next.label||'Ready Stock'};offset=summaryOffset=0;group=groupRow=null;
    $('ready-groups-title').textContent=scope.label;$('ready-groups-period').textContent=scope.mode==='current'?(scope.from?'Ready Stock dates: '+scope.from+' – '+scope.to:'All current Ready Stock'):(new Date(scope.date+'T00:00:00Z').toLocaleDateString('en-GB',{day:'2-digit',month:'short',year:'numeric',timeZone:'UTC'})+' · 10 AM – 9 PM UAE');$('ready-groups-back').hidden=true;
    if(source){source.classList.add('is-selected');source.setAttribute('aria-expanded','true');}dialog.showModal();void load();
  }
  $('ready-groups-rows').addEventListener('click',e=>{const button=e.target.closest('[data-stock-group]');if(!button||group||!scope)return;const row=rows[Number(button.dataset.stockGroup)];if(!row)return;summaryOffset=offset;offset=0;group=row.group_key;groupRow=row;groupColor=showColor;$('ready-groups-back').hidden=false;void load();});
  $('ready-groups-back').addEventListener('click',()=>{offset=showColor===groupColor?summaryOffset:0;group=groupRow=null;$('ready-groups-back').hidden=true;void load();});
  $('ready-groups-color').addEventListener('click',()=>{if(!scope||!allowed()||dialog.hasAttribute('aria-busy'))return;showColor=!showColor;colorControl();if(group&&lastData)render(lastData);else{offset=summaryOffset=0;void load();}});
  $('ready-groups-previous').addEventListener('click',()=>{offset=Math.max(0,offset-50);void load();});$('ready-groups-next').addEventListener('click',()=>{offset+=50;void load();});$('ready-groups-refresh').addEventListener('click',()=>void load());$('ready-groups-close').addEventListener('click',close);dialog.addEventListener('cancel',close);dialog.addEventListener('close',()=>{if(!dialog.open&&scope)close();});
  window.addEventListener('hashchange',close);window.addEventListener('pagehide',()=>{close();live=false;});window.addEventListener('greenloop:office-locked',()=>{close();live=false;});
  (async()=>{await window.GREENLOOP_ACCESS_READY;const c=GREENLOOP_GET_CLIENT(),{data,error}=await c.auth.getSession();if(error||!data.session)return;const user=data.session.user.id;c.auth.onAuthStateChange?.((event,s)=>{if(event==='SIGNED_OUT'||s?.user?.id&&s.user.id!==user){close();live=false;}});})().catch(close);
  window.GREENLOOP_READY_GROUPS={open,close};
})();
