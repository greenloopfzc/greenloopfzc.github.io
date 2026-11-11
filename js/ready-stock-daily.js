/* Daily movement totals are independent of the current physical stock table. */
(() => {
  'use strict';
  const panel=document.querySelector('#ready-daily'),dialog=document.querySelector('#ready-daily-dialog');if(!panel||!dialog)return;
  const $=id=>document.getElementById(id),allowed=()=>live&&window.GREENLOOP_PAGE_ACCESS?.pageKey==='ready_stock'&&window.GREENLOOP_CAN?.('view','ready_stock');
  let live=true,activeDate=null,reportedDate=null,selectedKind=null,offset=0,total=0,request=0,summaryRequest=0,timer=null,pending=null,initialized=false,userId=null;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const dateText=value=>new Date(value+'T00:00:00Z').toLocaleDateString('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',year:'numeric'});
  const timeText=value=>new Date(value).toLocaleTimeString('en-GB',{timeZone:'Asia/Dubai',hour:'2-digit',minute:'2-digit',hour12:true});
  const canSearch=()=>GREENLOOP_CAN?.('search','ready_stock')===true;
  function validate(data,kind){
    if(!data||!/^\d{4}-\d{2}-\d{2}$/.test(data.date)||data.timezone!=='Asia/Dubai'||![data.ready_count,data.export_count,data.total,data.offset].every(n=>Number.isSafeInteger(n)&&n>=0)||!Array.isArray(data.rows)||data.rows.length>50||data.kind!==kind)throw Error('Daily activity could not be verified. Refresh and try again.');
    if(data.rows.some(r=>!/^\d{15}$/.test(r.imei)||!r.occurred_at))throw Error('Phone details could not be verified. Refresh and try again.');
    if(!kind){const a=data.average,shift=n=>{const d=new Date(data.date+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-n);return d.toISOString().slice(0,10);};
      if(!a||a.from!==shift(30)||a.to!==shift(1)||a.window_days!==30||a.exclude_sundays!==true||![25,26].includes(a.days)||![a.ready_total,a.export_total].every(n=>Number.isSafeInteger(n)&&n>=0)||![a.ready_daily,a.export_daily].every(n=>Number.isFinite(n)&&n>=0)||Math.abs(a.ready_daily-Math.round(a.ready_total/a.days*100)/100)>.001||Math.abs(a.export_daily-Math.round(a.export_total/a.days*100)/100)>.001)throw Error('Daily averages could not be verified. Refresh and try again.');
    }
    return data;
  }
  async function read(kind=null,pageOffset=0,date=activeDate){
    if(!allowed())throw Error('Ready Stock view permission is required.');
    const{data,error}=await GREENLOOP_GET_CLIENT().rpc(kind?'get_ready_stock_daily_activity_v1':'get_ready_stock_daily_metrics_v1',kind?{p_date:date,p_kind:kind,p_offset:pageOffset,p_limit:50}:{p_date:date});
    if(error)throw error;validate(data,kind);
    if(date&&data.date!==date||data.offset!==pageOffset||data.limit!==50||kind&&data.total!==data[kind+'_count']||data.rows.length!==(kind?Math.min(50,Math.max(0,data.total-pageOffset)):0))throw Error('Daily activity response changed. Refresh and try again.');
    return data;
  }
  function cards(data){
    if(reportedDate&&reportedDate!==data.date)close();
    reportedDate=data.date;
    $('ready-daily-date-label').textContent=dateText(data.date);
    if($('ready-daily-filters').hidden&&document.activeElement!==$('ready-daily-date'))$('ready-daily-date').value=data.date;
    $('ready-daily-date').max=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(data.as_of));
    for(const kind of ['ready','export']){
      const count=data[kind+'_count'],button=panel.querySelector('[data-daily-kind="'+kind+'"]');
      button.querySelector('[data-daily-count]').textContent=count.toLocaleString('en-GB');button.disabled=false;
      button.querySelector('[data-daily-average]').textContent=data.average[kind+'_daily'].toLocaleString('en-GB',{minimumFractionDigits:2,maximumFractionDigits:2});
      button.querySelector('[data-daily-day-label]').textContent=data.date===new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(data.as_of))?'Today':'Selected day';
      button.setAttribute('aria-label',`View ${count} ${kind==='ready'?'phones made ready':'exported phones'} on ${dateText(data.date)}`);
    }
    $('ready-daily-average-note').textContent='30-day average · Sundays excluded · '+data.average.days+' days · '+dateText(data.average.from)+' – '+dateText(data.average.to);
    $('ready-daily-note').textContent='10:00 AM – 9:00 PM · UAE (UTC+4)';
    $('ready-daily-updated').textContent='Updated '+timeText(data.as_of);
    $('ready-daily-error').hidden=true;
  }
  async function refresh(){
    if(!allowed()||document.hidden||$('ready-stock-view').hidden)return;
    const version=++summaryRequest,date=activeDate;
    try{const data=await read(null,0,date);if(version!==summaryRequest||!allowed()||date!==activeDate)return;cards(data);}
    catch(e){if(version!==summaryRequest||!allowed())return;$('ready-daily-average-note').textContent='';panel.querySelectorAll('[data-daily-average]').forEach(el=>el.textContent='—');panel.querySelectorAll('[data-daily-count]').forEach(el=>el.textContent='—');panel.querySelectorAll('[data-daily-kind]').forEach(el=>el.disabled=true);$('ready-daily-error').textContent=e.message||'Daily activity is unavailable. Refresh to try again.';$('ready-daily-error').hidden=false;}
  }
  function schedule(){if(!initialized||!allowed())return;clearTimeout(timer);timer=setTimeout(()=>{void refresh();if(dialog.open)void loadPhones();},200);}
  function updateSelection(){panel.querySelectorAll('[data-daily-kind]').forEach(el=>{const on=dialog.open&&el.dataset.dailyKind===selectedKind;el.classList.toggle('is-selected',on);el.setAttribute('aria-expanded',String(on));});}
  function stop(){live=false;request++;summaryRequest++;clearTimeout(timer);clearInterval(pending);if(dialog.open)dialog.close();$('ready-daily-rows').replaceChildren();panel.hidden=true;}
  function close(){window.GREENLOOP_READY_GROUPS?.close();request++;selectedKind=null;if(dialog.open)dialog.close();$('ready-daily-rows').replaceChildren();updateSelection();}
  function rows(data){
    const history=GREENLOOP_CAN?.('view','imei_search')&&GREENLOOP_CAN?.('search','imei_search'),fields=['S.No','IMEI','Model','GB','Grade','Color','Supplier code','Stock / Batch','Time'];if(selectedKind==='export')fields.push('Box');
    $('ready-daily-head').innerHTML='<tr>'+fields.map(label=>'<th scope="col">'+esc(label)+'</th>').join('')+'</tr>';
    $('ready-daily-rows').innerHTML=data.rows.length?data.rows.map((r,i)=>{
      const imei='<span data-gl-copy-identifier>'+esc(r.imei)+'</span>',supplier=GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,r.supplier_name),batch=window.GREENLOOP_BATCH_LABEL?.(r.batch_number,{batch_number:r.batch_number,receipt_quantity:r.planned_quantity})||r.batch_number||'—';
      const values=[String(offset+i+1),history?'<a href="imei-search.html?q='+encodeURIComponent(r.imei)+'" title="Open phone history">'+imei+'</a>':imei,esc(r.model||'Not recorded'),esc(r.storage_gb==null?'—':GREENLOOP_STORAGE.label(r.storage_gb)),esc(r.grade||'Not recorded'),esc(r.color||'—'),esc(supplier),'<span data-gl-copy-identifier>'+esc(batch)+'</span>',esc(timeText(r.occurred_at))];if(selectedKind==='export')values.push(esc(r.box_number||'Recorded dispatch'));
      return '<tr>'+values.map((v,j)=>'<td data-label="'+esc(fields[j])+'">'+v+'</td>').join('')+'</tr>';
    }).join(''):'<tr><td colspan="'+fields.length+'" class="rsd-empty">No '+(selectedKind==='ready'?'Ready Stock arrivals':'confirmed exports')+' recorded during these hours.</td></tr>';
  }
  async function loadPhones(){
    if(!allowed()||!dialog.open||!selectedKind)return;
    const ticket=++request,kind=selectedKind,date=reportedDate,pageOffset=offset;
    $('ready-daily-previous').disabled=$('ready-daily-next').disabled=true;dialog.setAttribute('aria-busy','true');$('ready-daily-status').textContent='Loading phones…';
    try{
      const data=await read(kind,pageOffset,date);if(ticket!==request||!allowed()||!dialog.open||selectedKind!==kind||date!==reportedDate)return;
      total=data.total;
      if(offset&&offset>=total){offset=Math.max(0,Math.floor((total-1)/50)*50);return await loadPhones();}
      rows(data);$('ready-daily-status').textContent=total+' phone'+(total===1?'':'s')+' · Each phone counted once for this day';
      $('ready-daily-page').textContent=total?`${offset+1}–${Math.min(offset+data.rows.length,total)} of ${total}`:'0 phones';
      $('ready-daily-previous').disabled=offset===0;$('ready-daily-next').disabled=offset+data.rows.length>=total;
    }catch(e){if(ticket===request&&allowed()&&dialog.open){$('ready-daily-status').textContent=e.message||'Phone details could not load.';$('ready-daily-rows').replaceChildren();$('ready-daily-page').textContent='';}}
    finally{if(ticket===request)dialog.removeAttribute('aria-busy');}
  }
  function open(kind){
    if(!allowed()||!reportedDate)return;
    if(window.GREENLOOP_READY_GROUPS){GREENLOOP_READY_GROUPS.open({mode:kind,date:reportedDate,label:kind==='ready'?'Daily Ready Stock':'Daily Export',source:panel.querySelector('[data-daily-kind="'+kind+'"]')});return;}
    request++;selectedKind=kind;offset=0;
    $('ready-daily-title').textContent=kind==='ready'?'Daily Ready Stock':'Daily Export';
    $('ready-daily-period').textContent=dateText(reportedDate)+' · 10:00 AM – 9:00 PM · UAE';
    $('ready-daily-rows').replaceChildren();if(!dialog.open)dialog.showModal();updateSelection();void loadPhones();
  }
  panel.addEventListener('click',e=>{const button=e.target.closest('[data-daily-kind]');if(button&&!button.disabled)open(button.dataset.dailyKind);});
  $('ready-daily-close').addEventListener('click',close);dialog.addEventListener('cancel',close);dialog.addEventListener('close',()=>{request++;selectedKind=null;updateSelection();});
  $('ready-daily-previous').addEventListener('click',()=>{offset=Math.max(0,offset-50);void loadPhones();});
  $('ready-daily-next').addEventListener('click',()=>{offset+=50;void loadPhones();});
  $('ready-daily-reload').addEventListener('click',()=>void loadPhones());
  $('ready-daily-refresh').addEventListener('click',()=>{void refresh();if(dialog.open)void loadPhones();});
  $('ready-daily-filter-toggle').addEventListener('click',()=>{if(!canSearch())return;const filters=$('ready-daily-filters');filters.hidden=!filters.hidden;$('ready-daily-filter-toggle').setAttribute('aria-expanded',String(!filters.hidden));});
  $('ready-daily-apply').addEventListener('click',()=>{
    if(!canSearch())return;const value=$('ready-daily-date').value;if(!/^\d{4}-\d{2}-\d{2}$/.test(value))return;
    close();activeDate=value;reportedDate=null;$('ready-daily-filters').hidden=true;$('ready-daily-filter-toggle').setAttribute('aria-expanded','false');void refresh();
  });
  $('ready-daily-today').addEventListener('click',()=>{if(!canSearch())return;close();activeDate=null;reportedDate=null;void refresh();});
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)schedule();});
  for(const event of ['greenloop:ready-stock-refreshed','greenloop:workflow-committed','greenloop:supplier-return-changed'])window.addEventListener(event,schedule);
  window.addEventListener('pagehide',stop);window.addEventListener('greenloop:office-locked',stop);
  window.addEventListener('hashchange',()=>{close();schedule();});
  (async()=>{
    await window.GREENLOOP_ACCESS_READY;const client=GREENLOOP_GET_CLIENT(),{data,error}=await client.auth.getSession();if(error||!data.session||!allowed())return;userId=data.session.user.id;
    client.auth.onAuthStateChange?.((event,session)=>{if(event==='SIGNED_OUT'||session?.user?.id&&session.user.id!==userId)stop();});
    initialized=true;panel.hidden=false;GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(panel);await refresh();
    if(allowed())pending=setInterval(()=>{if(!document.hidden&&allowed()){void refresh();if(dialog.open)void loadPhones();}},30000);
  })().catch(e=>{if(allowed()){$('ready-daily-error').textContent=e.message||'Daily activity is unavailable.';$('ready-daily-error').hidden=false;}});
})();
