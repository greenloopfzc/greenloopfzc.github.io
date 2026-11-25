/* Card -> stock groups -> exact group's phones. Each server page is bounded. */
(() => {
  'use strict';
  const $=id=>document.getElementById(id),dialog=$('ready-groups-dialog');if(!dialog)return;
  let scope=null,group=null,groupRow=null,esimDrill=null,offset=0,summaryOffset=0,ticket=0,rows=[],live=true,source=null,showColor=false,groupColor=false,lastData=null,modelView=false;
  const allowed=()=>live&&window.GREENLOOP_CAN?.('view','ready_stock'),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const storage=v=>v==null?'—':GREENLOOP_STORAGE.label(v),batch=r=>window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{batch_number:r.batch_number,receipt_quantity:r.planned_quantity})||r.batch_number||'—';
  const supplier=r=>GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,r.supplier_name),identifier=v=>'<span data-gl-copy-identifier>'+esc(v)+'</span>';
  const inPhones=()=>Boolean(group||esimDrill),validSnapshot=v=>typeof v==='string'&&/^[a-f0-9]{32}$/.test(v);
  const totalRow=$('ready-groups-table-total');
  function clearTotalRow(){totalRow.hidden=true;totalRow.replaceChildren();}
  function esimButton(quantity,label,key){
    return quantity?'<button type="button" class="rsg-model" data-esim-group="'+key+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-label="'+esc('View '+quantity+' e-Sim IMEIs · '+label)+'">'+quantity.toLocaleString('en-GB')+'</button>':'0';
  }
  function close(){window.GREENLOOP_READY_MODELS?.close();++ticket;scope=null;group=null;esimDrill=null;rows=[];lastData=null;clearTotalRow();if(dialog.open)dialog.close();$('ready-groups-rows').replaceChildren();if(source){source.classList.remove('is-selected');source.setAttribute('aria-expanded','false');source=null;}}
  function colorControl(){$('ready-groups-models').textContent=modelView?'Detailed View':'Model Summary';$('ready-groups-models').setAttribute('aria-pressed',String(modelView));const b=$('ready-groups-color');b.textContent=showColor?'Hide Color':'Show Color';b.setAttribute('aria-pressed',String(showColor));b.disabled=modelView;}
  function render(data){
    lastData=data;rows=data.rows;colorControl();if(modelView){window.GREENLOOP_READY_MODELS.renderList(data,offset);return;}
    const phoneView=inPhones(),withEsim=scope.totalEsim&&!phoneView;
    const labels=phoneView?['S.No','IMEI','Model','GB']:['S.No','Model','GB'];if(showColor)labels.push('Color');labels.push('Grade','Stock / Batch','Supplier',phoneView?'Date':'Qty');if(withEsim)labels.push('e-Sim');if(group&&scope.mode==='export')labels.push('Box');
    $('ready-groups-head').innerHTML='<tr>'+labels.map(x=>'<th scope="col">'+esc(x)+'</th>').join('')+'</tr>';
    rows=data.rows;
    $('ready-groups-rows').innerHTML=rows.length?rows.map((r,i)=>{
      const groupButton=text=>'<button class="rsg-model" type="button" data-stock-group="'+i+'" data-capability="view" data-capability-page="ready_stock" data-search-read-only aria-label="'+esc(['View phones: '+r.model,storage(r.storage_gb),showColor?(r.color||'Not recorded'):null,r.final_grade,batch(r)].filter(Boolean).join(', '))+'">'+esc(text)+'</button>';
      const model=phoneView||scope.esim?esc(r.model):groupButton(r.model);
      const values=[String(offset+i+1)];if(phoneView)values.push(identifier(r.imei));values.push(model,esc(storage(r.storage_gb)));if(showColor)values.push(esc(r.color||'—'));values.push(esc(r.final_grade),identifier(batch(r)),esc(supplier(r)));
      if(phoneView){values.push(esc(r.occurred_at?new Date(r.occurred_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'—'));if(scope.mode==='export')values.push(esc(r.box_number||'Recorded dispatch'));}
      else values.push(scope.esim?groupButton(r.quantity):esc(r.quantity));
      if(withEsim)values.push(esimButton(r.esim_quantity,[r.model,storage(r.storage_gb),
        showColor?(r.color||'Not recorded'):null,r.final_grade,batch(r)].filter(Boolean).join(', '),i));
      return '<tr>'+values.map((v,j)=>'<td data-label="'+esc(labels[j])+'">'+v+'</td>').join('')+'</tr>';
    }).join(''):'<tr><td colspan="'+labels.length+'" class="rsd-empty">No '+(phoneView?'phones':'stock groups')+' match this selection.</td></tr>';
    if(withEsim){
      totalRow.innerHTML='<tr><th scope="row" colspan="'+(labels.length-2)+'">Total</th><td data-label="Qty">'+data.phone_total.toLocaleString('en-GB')+'</td><td data-label="e-Sim">'+esimButton(data.esim_total,'All Ready Stock','all')+'</td></tr>';
      totalRow.hidden=false;
    }
    $('ready-groups-total').textContent=withEsim?'':phoneView
      ?(esimDrill?'e-Sim total: ':'Group total: ')+data.total+' phones'
      :'Total Qty: '+data.phone_total+' phones';
    $('ready-groups-status').textContent=phoneView?(!groupRow?'All e-Sim phones in Ready Stock':[groupRow.model,storage(groupRow.storage_gb),showColor?(groupColor?(groupRow.color||'Not recorded'):'All colors'):null,'Grade '+groupRow.final_grade,batch(groupRow),esimDrill?'e-Sim only':null].filter(Boolean).join(' · ')):data.total+' stock groups · '+(showColor?'Colors shown':'Colors combined')+' · '+(scope.esim?'Select a quantity to view IMEIs':withEsim?'Select a model or e-Sim quantity to view IMEIs':'Select a model to view its phones');
    $('ready-groups-page').textContent=data.total?`${offset+1}–${Math.min(offset+rows.length,data.total)} of ${data.total}`:'0 '+(phoneView?'phones':'groups');
    $('ready-groups-previous').disabled=offset===0;$('ready-groups-next').disabled=offset+rows.length>=data.total;
    $('ready-groups-back').hidden=!phoneView;
  }
  async function load(){
    if(!scope||!allowed()||!dialog.open)return;const id=++ticket,selected=scope,key=group,page=offset,phoneView=inPhones(),color=phoneView?groupColor:showColor;
    lastData=null;clearTotalRow();$('ready-groups-color').disabled=true;$('ready-groups-models').disabled=true;
    dialog.setAttribute('aria-busy','true');$('ready-groups-previous').disabled=$('ready-groups-next').disabled=true;$('ready-groups-status').textContent='Loading '+(phoneView?'phones':'stock summary')+'…';$('ready-groups-rows').replaceChildren();$('ready-groups-total').textContent='';$('ready-groups-page').textContent='';
    try{
      // An empty grade card still opens a useful empty popup, without sending invalid empty groups.
      if(selected.mode==='current'&&!selected.totalEsim&&Array.isArray(selected.groups)&&!selected.groups.length){render({rows:[],total:0,phone_total:0});return;}
      const totalEsimRead=selected.totalEsim&&!modelView&&(!phoneView||esimDrill);
      const{data,error}=await(totalEsimRead
        ? GREENLOOP_GET_CLIENT().rpc('get_ready_stock_total_esim_v1',{
          p_view:esimDrill?'esim_phones':'summary',p_group:key,p_offset:page,p_show_color:color,
          p_expected_snapshot:esimDrill?.snapshot??null
        })
        : selected.esim
        ? GREENLOOP_GET_CLIENT().rpc('get_ready_stock_esim_v1',{p_view:'groups',p_group:key,p_offset:page,p_show_color:color})
        : selected.activity?GREENLOOP_STOCK_ACTIVITY.request(selected.activity,{p_view:modelView?'models':'groups',p_group:modelView?null:key,p_offset:page,p_show_color:color}):GREENLOOP_GET_CLIENT().rpc(modelView?'get_ready_stock_models_v1':'get_ready_stock_color_groups_v1',modelView?{p_mode:selected.mode,p_date:selected.date||null,p_groups:selected.groups||null,p_date_from:selected.from||null,p_date_to:selected.to||null,p_view:'models',p_offset:page,p_limit:50}:{p_mode:selected.mode,p_date:selected.date||null,p_groups:selected.groups||null,p_date_from:selected.from||null,p_date_to:selected.to||null,p_group:key,p_offset:page,p_limit:50,p_show_color:color}));if(error)throw error;
      if(id!==ticket||!allowed()||!dialog.open||selected!==scope)return;
      if(selected.activity&&data.phone_total!==selected.activity.total)throw Error('Activity quantities changed. Refresh the reports.');if(modelView){if(!window.GREENLOOP_READY_MODELS.valid(data,'models',selected,page))throw Error('Model summary could not be verified. Refresh and try again.');render(data);return;}
      if(!data||data.show_color!==color||data.mode!==selected.mode||data.view!==(phoneView?'phones':'groups')||data.offset!==page||data.limit!==50||![data.total,data.phone_total].every(n=>Number.isSafeInteger(n)&&n>=0)||!Array.isArray(data.rows)||data.rows.length!==Math.min(50,Math.max(0,data.total-page))||selected.mode!=='current'&&data.date!==selected.date)throw Error('Stock summary could not be verified. Refresh and try again.');
      if(data.rows.some(r=>!r.model||typeof r.final_grade!=='string'||(phoneView?!/^\d{15}$/.test(r.imei):!Array.isArray(r.group_key)||r.group_key.length!==6||!Number.isSafeInteger(r.quantity)||r.quantity<1)))throw Error('Stock details could not be verified.');
      if(totalEsimRead&&(!Number.isSafeInteger(data.esim_total)||data.esim_total<0||data.esim_total>data.phone_total||
        !validSnapshot(data.esim_snapshot)||(esimDrill
          ?data.esim_snapshot!==esimDrill.snapshot||data.total!==esimDrill.quantity||data.esim_total!==data.total
          :data.rows.some(r=>!Number.isSafeInteger(r.esim_quantity)||r.esim_quantity<0||r.esim_quantity>r.quantity||!validSnapshot(r.esim_snapshot)))))
        throw Error('Ready Stock e-Sim quantities could not be verified. Refresh the summary.');
      if(page&&page>=data.total){offset=Math.max(0,Math.floor((data.total-1)/50)*50);return await load();}render(data);
    }catch(e){if(id===ticket&&allowed()&&dialog.open){$('ready-groups-status').textContent=e.message||'Stock details could not load. Refresh to retry.';$('ready-groups-rows').replaceChildren();$('ready-groups-total').textContent='';}}
    finally{if(id===ticket){dialog.removeAttribute('aria-busy');$('ready-groups-color').disabled=modelView;$('ready-groups-models').disabled=false;}}
  }
  function open(next){
    if(!allowed()||!next||!['current','ready','export'].includes(next.mode))return;close();modelView=false;showColor=groupColor=next.esim===true;colorControl();source=next.source||null;scope={mode:next.mode,date:next.date||null,groups:next.groups||null,from:next.from||null,to:next.to||null,label:next.label||'Ready Stock',activity:next.activity?{...next.activity}:null,esim:next.esim===true,totalEsim:next.totalEsim===true};offset=summaryOffset=0;group=groupRow=null;
    $('ready-groups-models').hidden=scope.esim;
    $('ready-groups-title').textContent=scope.label;$('ready-groups-period').textContent=scope.activity?GREENLOOP_STOCK_ACTIVITY.period(scope.activity)+' · '+GREENLOOP_STOCK_ACTIVITY.hours[scope.mode]+' UAE':scope.mode==='current'?(scope.from?'Ready Stock dates: '+scope.from+' – '+scope.to:'All current Ready Stock'):(new Date(scope.date+'T00:00:00Z').toLocaleDateString('en-GB',{day:'2-digit',month:'short',year:'numeric',timeZone:'UTC'})+' · '+GREENLOOP_STOCK_ACTIVITY.hours[scope.mode]+' UAE');$('ready-groups-back').hidden=true;
    if(source){source.classList.add('is-selected');source.setAttribute('aria-expanded','true');}dialog.showModal();void load();
  }
  $('ready-groups-rows').addEventListener('click',e=>{const m=e.target.closest('[data-ready-model]');if(m&&modelView&&lastData&&scope){const row=rows[Number(m.dataset.readyModel)];if(row)window.GREENLOOP_READY_MODELS.open(scope,row,lastData.snapshot,$('ready-groups-period').textContent);return;}const button=e.target.closest('[data-stock-group]');if(!button||inPhones()||!scope)return;const row=rows[Number(button.dataset.stockGroup)];if(!row)return;summaryOffset=offset;offset=0;group=row.group_key;groupRow=row;groupColor=showColor;$('ready-groups-back').hidden=false;void load();});
  function openEsimPhones(event){
    const button=event.target.closest('[data-esim-group]');
    if(!button||!lastData||!scope?.totalEsim||inPhones()||modelView||!allowed())return;
    const all=button.dataset.esimGroup==='all',row=all?null:rows[Number(button.dataset.esimGroup)];
    const quantity=all?lastData.esim_total:row?.esim_quantity;
    if(!quantity)return;
    esimDrill={quantity,snapshot:all?lastData.esim_snapshot:row.esim_snapshot};
    group=row?.group_key??null;groupRow=row;groupColor=showColor;
    summaryOffset=offset;offset=0;$('ready-groups-back').hidden=false;void load();
  }
  $('ready-groups-rows').addEventListener('click',openEsimPhones);
  totalRow.addEventListener('click',openEsimPhones);
  $('ready-groups-back').addEventListener('click',()=>{offset=showColor===groupColor?summaryOffset:0;group=groupRow=esimDrill=null;$('ready-groups-back').hidden=true;void load();});
  $('ready-groups-models').addEventListener('click',()=>{if(!scope||scope.esim||!allowed()||dialog.hasAttribute('aria-busy'))return;window.GREENLOOP_READY_MODELS.close();modelView=!modelView;group=groupRow=esimDrill=null;offset=summaryOffset=0;void load();});
  async function refreshReviewed(){const selected=scope;if(!selected)return;try{if(selected.activity)await GREENLOOP_STOCK_ACTIVITY.refreshScope(selected.activity);if(scope===selected&&dialog.open&&allowed())void load();}catch(e){if(scope===selected&&dialog.open)$('ready-groups-status').textContent=e.message;}}
  window.addEventListener('greenloop:ready-models-refresh',()=>{if(scope&&modelView&&dialog.open)void refreshReviewed();});
  $('ready-groups-color').addEventListener('click',()=>{if(!scope||!allowed()||dialog.hasAttribute('aria-busy'))return;showColor=!showColor;colorControl();if(inPhones()&&lastData)render(lastData);else{offset=summaryOffset=0;void load();}});
  $('ready-groups-previous').addEventListener('click',()=>{offset=Math.max(0,offset-50);void load();});$('ready-groups-next').addEventListener('click',()=>{offset+=50;void load();});$('ready-groups-refresh').addEventListener('click',()=>void refreshReviewed());$('ready-groups-close').addEventListener('click',close);dialog.addEventListener('cancel',close);dialog.addEventListener('close',()=>{if(!dialog.open&&scope)close();});
  for(const event of ['greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,()=>{close();live=false;});window.addEventListener('hashchange',close);window.addEventListener('pagehide',()=>{close();live=false;});window.addEventListener('greenloop:office-locked',()=>{close();live=false;});
  (async()=>{await window.GREENLOOP_ACCESS_READY;const c=GREENLOOP_GET_CLIENT(),{data,error}=await c.auth.getSession();if(error||!data.session)return;const user=data.session.user.id;c.auth.onAuthStateChange?.((event,s)=>{if(event==='SIGNED_OUT'||s?.user?.id&&s.user.id!==user){close();live=false;}});})().catch(close);
  window.GREENLOOP_READY_GROUPS={open,close};
})();
