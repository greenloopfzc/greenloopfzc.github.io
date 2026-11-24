/* Stock activity: reviewed day/month totals and transparent averaging periods. */
(() => {
 'use strict';
 const panel=document.querySelector('#ready-daily'),dialog=document.querySelector('#ready-daily-dialog');if(!panel||!dialog)return;
 const $=id=>document.getElementById(id),titles={ready:'Stock Production Report',export:'Stock Export Report',received:'Stock Received Report'},nouns={ready:'Production',export:'Export',received:'Received'};
 const metrics=['today','month','daily_average','monthly_average'];let live=true,data=null,selection=null,offset=0,total=0,request=0,summaryRequest=0,activeRange=null,timer,poll;
 const canSearch=()=>window.GREENLOOP_CAN?.('search','ready_stock')===true,allowed=()=>live&&GREENLOOP_PAGE_ACCESS?.pageKey==='ready_stock'&&GREENLOOP_CAN?.('view','ready_stock')===true;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const fmt=(v,average=false)=>v==null?'—':v.toLocaleString('en-GB',average?{minimumFractionDigits:2,maximumFractionDigits:2}:{});
 const date=v=>new Date(v+'T00:00:00Z').toLocaleDateString('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',year:'numeric'}),month=v=>new Date(v+'T00:00:00Z').toLocaleDateString('en-GB',{timeZone:'UTC',month:'short',year:'numeric'});
 const today=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 const whole=n=>Number.isSafeInteger(n)&&n>=0,validDate=v=>/^\d{4}-\d{2}-\d{2}$/.test(v||'');
 function verify(d){if(!d||d.version!=='20261117-stock-activity-reports-1'||!validDate(d.date)||d.timezone!=='Asia/Dubai'||!Number.isFinite(Date.parse(d.as_of))||!/^[a-f0-9]{32}$/.test(d.snapshot)||!d.exclude_sundays||![25,26].includes(d.daily_days)||!['month_from','month_to','daily_from','daily_to'].every(k=>validDate(d[k])))throw Error('Stock activity periods could not be verified. Refresh the reports.');
  for(const kind of Object.keys(titles)){const r=d.reports?.[kind];if(!r||![r.today,r.month,r.daily_total,r.monthly_total,r.monthly_months].every(whole)||r.monthly_months>3||!Number.isFinite(r.daily_average)||Math.abs(r.daily_average-Math.round(r.daily_total/d.daily_days*100)/100)>.001||r.monthly_months===0&&(r.monthly_average!==null||r.monthly_from!==null||r.monthly_to!==null)||r.monthly_months>0&&(!validDate(r.monthly_from)||!validDate(r.monthly_to)||!Number.isFinite(r.monthly_average)||Math.abs(r.monthly_average-Math.round(r.monthly_total/r.monthly_months*100)/100)>.001))throw Error('Stock activity figures could not be verified. Refresh the reports.');}
  return d;
 }
 async function rpc(name,args){if(!allowed())throw Error('Ready Stock view permission is required.');const r=await GREENLOOP_GET_CLIENT().rpc(name,args);if(r.error)throw r.error;return r.data;}
 function verifyRange(d,range){
  if(!d||d.range_from!==range.from||d.range_to!==range.to||d.kind!==null||d.timezone!=='Asia/Dubai'||
    !Number.isFinite(Date.parse(d.as_of))||!/^[a-f0-9]{32}$/.test(d.activity_snapshot)||
    !Object.keys(titles).every(kind=>whole(d.reports?.[kind])))throw Error('Stock activity range could not be verified. Refresh the reports.');
  return {...d,date:d.range_to,snapshot:d.activity_snapshot};
 }
 const rangeLabel=range=>date(range.from)+(range.to===range.from?'':' – '+date(range.to));
 const filter=$('ready-daily-filters'),fromInput=$('ready-daily-from'),toInput=$('ready-daily-to'),filterError=$('ready-daily-filter-error');
 function setFilterOpen(open){
  filter.hidden=!open;
  $('ready-daily-filter-toggle').setAttribute('aria-expanded',String(open));
  filterError.hidden=true;
 }
 async function rangeRequest(range,args={}){
  const d=await rpc('get_stock_activity_range_v1',{...args,p_from:range.from,p_to:range.to});
  if(d?.range_from!==range.from||d.range_to!==range.to||
    args.p_kind&&(d.kind!==args.p_kind||d.activity_snapshot!==args.p_expected))throw Error('Activity range changed. Refresh the reports.');
  return d;
 }
 function cards(d){
  const range=d.range_from?{from:d.range_from,to:d.range_to}:null;
  panel.classList.toggle('is-date-range',!!range);
  $('ready-daily-date-label').textContent=range?rangeLabel(range):date(d.date);
  fromInput.max=toInput.max=today();
  if(filter.hidden){fromInput.value=range?.from??d.date;toInput.value=range?.to??d.date;}
  $('ready-daily-average-note').hidden=!!range;
  if(range){
   for(const card of panel.querySelectorAll('[data-daily-kind]')){
    const kind=card.dataset.dailyKind,button=card.querySelector('[data-activity-metric="today"]');
    const label=nouns[kind]+' for selected dates',value=fmt(d.reports[kind]);
    button.querySelector('.rsa-label').textContent=label;
    button.querySelector('[data-activity-value]').textContent=value;
    button.querySelector('[data-activity-period]').textContent=rangeLabel(range);
    button.classList.toggle('rsa-long',value.length>7);
    button.disabled=!canSearch();
    button.title='View '+label;
   }
  }else{
  for(const card of panel.querySelectorAll('[data-daily-kind]')){const kind=card.dataset.dailyKind,r=d.reports[kind];for(const button of card.querySelectorAll('[data-activity-metric]')){const metric=button.dataset.activityMetric,average=metric.includes('average');const text=fmt(r[metric],average);button.querySelector('[data-activity-value]').textContent=text;button.classList.toggle('rsa-long',text.length>7);button.disabled=metric!=='today'&&!canSearch();button.querySelector('.rsa-label').textContent=(metric==='today'?(d.date===today()?'Today’s ':'Selected Day’s '):metric==='month'?'Monthly ':metric==='daily_average'?'Average Daily ':'Average Monthly ')+nouns[kind];button.querySelector('[data-activity-period]').textContent=metric==='today'?date(d.date):metric==='month'?date(d.month_from)+' – '+date(d.month_to):metric==='daily_average'?d.daily_days+' working days':r.monthly_months?r.monthly_months+' completed month'+(r.monthly_months===1?'':'s')+' · '+month(r.monthly_from)+' – '+month(r.monthly_to):'No completed recorded month';button.title=button.disabled?'Search permission is required to open this period.':'View '+button.querySelector('.rsa-label').textContent;}}
  $('ready-daily-average-note').textContent='Daily average: '+date(d.daily_from)+' – '+date(d.daily_to)+' · Sundays excluded. Monthly average: up to 3 completed recorded months; current month excluded.';
  }
  $('ready-daily-note').textContent='Production / Export: 10 AM – 9 PM · Received: full day · UAE (UTC+4)';$('ready-daily-updated').textContent='Updated '+new Date(d.as_of).toLocaleTimeString('en-GB',{timeZone:'Asia/Dubai',hour:'2-digit',minute:'2-digit',hour12:true});$('ready-daily-error').hidden=true;
 }
 let summaryRead,refreshAgain=false;
 function refresh(){
  if(!allowed()||document.hidden||$('ready-stock-view').hidden)return Promise.resolve(null);
  const anchor=activeRange;
  if(summaryRead?.anchor===anchor)return summaryRead.promise;
  const ticket=++summaryRequest;
  const promise=(async()=>{
   try{
    const d=anchor&&anchor.from!==anchor.to
      ?verifyRange(await rangeRequest(anchor),anchor)
      :verify(await rpc('get_stock_activity_reports_v1',{p_date:anchor?.to??null}));
    if(ticket!==summaryRequest||!allowed()||anchor!==activeRange)return null;
    if(anchor&&d.date!==anchor.to)throw Error('The selected date changed. Refresh.');
    if(data&&d.date!==data.date){close();window.GREENLOOP_READY_GROUPS?.close();}
    data=d;
    cards(d);
    if(dialog.open&&selection&&selection.snapshot!==d.snapshot){
     request++;
     dialog.removeAttribute('aria-busy');
     $('ready-daily-rows').replaceChildren();
     $('ready-daily-status').textContent='Activity changed. Refresh list to view the current figures.';
     $('ready-daily-previous').disabled=$('ready-daily-next').disabled=true;
    }
    return d;
   }catch(e){
    if(ticket===summaryRequest&&allowed()){
     $('ready-daily-error').hidden=false;
     $('ready-daily-error').textContent=e.message||'Stock activity is unavailable.';
     panel.querySelectorAll('[data-activity-metric]').forEach(b=>{b.disabled=true;b.querySelector('[data-activity-value]').textContent='—';});
    }
    return null;
   }finally{
    if(summaryRead?.ticket===ticket){
     summaryRead=null;
     if(refreshAgain){refreshAgain=false;schedule();}
    }
   }
  })();
  summaryRead={anchor,ticket,promise};
  return promise;
 }
 function close(){request++;selection=null;offset=0;if(dialog.open)dialog.close();$('ready-daily-rows').replaceChildren();}
 function stop(){live=false;request++;summaryRequest++;clearTimeout(timer);clearInterval(poll);data=null;close();panel.hidden=true;}
 function periodLabel(scope){return scope?.from?date(scope.from)+(scope.to!==scope.from?' – '+date(scope.to):''):'No completed recorded month';}
 function render(d){const view=d.scope.view;let headers,rows;
  if(view==='days'||view==='months'){headers=['S.No',view==='days'?'Date':'Completed month','Quantity','Details'];rows=d.rows.map((r,i)=>[offset+i+1,view==='days'?date(r.from):month(r.from),fmt(r.quantity),'<button type="button" class="secondary-button" data-activity-period="'+r.from+'" data-activity-total="'+r.quantity+'" data-capability="search" data-capability-page="ready_stock">View '+(selection.kind==='received'?'stock':'phones')+' →</button>']);}
  else if(view==='receipts'){headers=['S.No','Stock / Batch','Invoice','Supplier','Qty received','Received'];rows=d.rows.map((r,i)=>[offset+i+1,GREENLOOP_BATCH_LABEL?.(r.batch_number,{receipt_quantity:r.planned_quantity})||r.batch_number,r.invoice_number||'Not recorded',GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,r.supplier_name),fmt(r.quantity),new Date(r.received_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:true})]);}
  else{headers=['S.No','IMEI','Model','GB','Grade','Color','Supplier','Stock / Batch','Date'];rows=d.rows.map((r,i)=>[offset+i+1,r.imei,r.model,GREENLOOP_STORAGE.label(r.storage_gb),r.grade,r.color,GREENLOOP_SUPPLIER_RECEIPT_LABEL(r.supplier_code,r.planned_quantity,r.supplier_name),GREENLOOP_BATCH_LABEL?.(r.batch_number,{receipt_quantity:r.planned_quantity})||r.batch_number,new Date(r.occurred_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'})]);}
  $('ready-daily-head').innerHTML='<tr>'+headers.map(h=>'<th scope="col">'+esc(h)+'</th>').join('')+'</tr>';$('ready-daily-rows').innerHTML=rows.length?rows.map(row=>'<tr>'+row.map((v,i)=>'<td>'+(i===3&&(view==='days'||view==='months')?v:esc(v??'—'))+'</td>').join('')+'</tr>').join(''):'<tr><td colspan="'+headers.length+'" class="rsd-empty">'+(view==='months'?'No completed month of recorded history is available yet.':'No activity records in this period.')+'</td></tr>';
  $('ready-daily-period').textContent=periodLabel(d.scope)+' · UAE';$('ready-daily-back').hidden=!selection.period;const average=selection.metric.includes('average')&&!selection.period;
  $('ready-daily-status').textContent=average&&d.total===0?'Monthly average will be available after the first recorded calendar month completes.':average?fmt(d.quantity)+' total / '+d.total+(view==='days'?' working days':' completed months')+' = '+fmt(data.reports[selection.kind][selection.metric],true)+(view==='days'?' phones / day':' phones / month'):fmt(d.quantity)+' '+(selection.kind==='received'?'phones received · '+d.total+' original receipts':'activity entries');
  $('ready-daily-page').textContent=d.total?(offset+1)+'–'+Math.min(offset+d.rows.length,d.total)+' of '+d.total:'0 records';total=d.total;$('ready-daily-previous').disabled=offset===0;$('ready-daily-next').disabled=offset+d.rows.length>=total;
 }
 async function load(){if(!selection||!dialog.open||!allowed())return;const s=selection,t=++request,page=offset;$('ready-daily-previous').disabled=$('ready-daily-next').disabled=true;$('ready-daily-status').textContent='Loading activity…';dialog.setAttribute('aria-busy','true');try{if(s.range){
   const d=await rangeRequest(s.range,{p_kind:'received',p_view:'receipts',p_offset:page,p_expected:s.snapshot});
   if(t!==request||s!==selection||!dialog.open||!allowed())return;
   if(d.view!=='receipts'||d.offset!==page||d.limit!==50||!whole(d.total)||!whole(d.quantity)||
     !Array.isArray(d.rows)||d.rows.length!==Math.min(50,Math.max(0,d.total-page))||
     d.quantity!==data?.reports?.received)throw Error('Received activity could not be verified. Refresh the reports.');
   render({...d,scope:{...s.range,view:'receipts'}});
   return;
  }
  const d=await rpc('get_stock_activity_details_v1',{p_kind:s.kind,p_metric:s.metric,p_date:s.date,p_expected:s.snapshot,p_period_date:s.period,p_offset:page,p_limit:50});if(t!==request||s!==selection||!dialog.open||!allowed())return;if(d.version!=='20261117-stock-activity-reports-1'||d.date!==s.date||d.kind!==s.kind||d.metric!==s.metric||d.snapshot!==s.snapshot||d.period_date!==s.period||d.offset!==page||d.limit!==50||!whole(d.total)||!whole(d.quantity)||!Array.isArray(d.rows)||d.rows.length!==Math.min(50,Math.max(0,d.total-page))||!['days','months','receipts','phones'].includes(d.scope?.view))throw Error('Activity details could not be verified. Refresh the reports.');render(d);}catch(e){if(t===request&&allowed()&&dialog.open){$('ready-daily-rows').replaceChildren();$('ready-daily-status').textContent=e.message||'Activity details could not load.';}}finally{if(t===request)dialog.removeAttribute('aria-busy');}}
 function show(kind,metric,period=null,quantity=null){if(!data||!allowed()||metric!=='today'&&!canSearch())return;
  if(data.range_from){
   if(metric!=='today'||!canSearch())return;
   const range={from:data.range_from,to:data.range_to};
   if(kind!=='received'){
    window.GREENLOOP_READY_GROUPS?.open({mode:kind,date:data.date,label:titles[kind],
      activity:{kind,range,expected:data.snapshot,total:data.reports[kind]},
      source:panel.querySelector('[data-daily-kind="'+kind+'"] [data-activity-metric="today"]')});
    return;
   }
   request++;selection={kind,metric,range,snapshot:data.snapshot};offset=0;
   $('ready-daily-title').textContent=titles.received;
   $('ready-daily-rows').replaceChildren();
   if(!dialog.open)dialog.showModal();
   void load();
   return;
  }
  if(kind!=='received'&&(metric==='today'||metric==='month'||period)&&window.GREENLOOP_READY_GROUPS){const activity=metric==='today'?null:{kind,metric,date:data.date,expected:data.snapshot,period,total:quantity??data.reports[kind].month};GREENLOOP_READY_GROUPS.open({mode:kind,date:data.date,label:titles[kind]+' · '+(period?date(period):metric==='month'?'Monthly':data.date===today()?"Today’s":"Selected Day’s"),activity,source:panel.querySelector('[data-daily-kind="'+kind+'"] [data-activity-metric="'+metric+'"]')});return;}
  request++;selection={kind,metric,period,date:data.date,snapshot:data.snapshot};offset=0;$('ready-daily-title').textContent=titles[kind]+' · '+(metric==='today'?(data.date===today()?"Today’s ":"Selected Day’s "):metric==='month'?'Monthly ':metric==='daily_average'?'Average Daily ':'Average Monthly ')+nouns[kind];$('ready-daily-rows').replaceChildren();if(!dialog.open)dialog.showModal();void load();
 }
 panel.addEventListener('click',e=>{const b=e.target.closest('[data-activity-metric]');if(b&&!b.disabled)show(b.closest('[data-daily-kind]').dataset.dailyKind,b.dataset.activityMetric);});
 $('ready-daily-rows').onclick=e=>{const b=e.target.closest('[data-activity-period]');if(b&&selection&&canSearch())show(selection.kind,selection.metric,b.dataset.activityPeriod,Number(b.dataset.activityTotal));};
 $('ready-daily-back').onclick=()=>{if(selection){selection={...selection,period:null};offset=0;void load();}};$('ready-daily-close').onclick=close;dialog.addEventListener('cancel',close);dialog.addEventListener('close',()=>{request++;selection=null;});
 $('ready-daily-previous').onclick=()=>{offset=Math.max(0,offset-50);void load();};$('ready-daily-next').onclick=()=>{offset+=50;void load();};$('ready-daily-reload').onclick=async()=>{const d=await refresh();if(d&&selection){selection={...selection,snapshot:d.snapshot};offset=0;void load();}};
 $('ready-daily-refresh').onclick=async()=>{const d=await refresh();if(d&&selection){selection={...selection,snapshot:d.snapshot};offset=0;void load();}};
 $('ready-daily-filter-toggle').onclick=()=>{
  if(!canSearch())return;
  if(filter.hidden){fromInput.max=toInput.max=today();setFilterOpen(true);fromInput.focus();}
  else setFilterOpen(false);
 };
 function applyRange(range){
  close();
  window.GREENLOOP_READY_GROUPS?.close();
  activeRange=range;
  summaryRequest++;
  summaryRead=null;
  refreshAgain=false;
  data=null;
  panel.classList.toggle('is-date-range',!!range&&range.from!==range.to);
  const day=today();
  fromInput.value=range?.from??day;
  toInput.value=range?.to??day;
  $('ready-daily-date-label').textContent=range?rangeLabel(range):date(day);
  $('ready-daily-error').hidden=true;
  panel.querySelectorAll('[data-activity-metric]').forEach(b=>{b.disabled=true;b.querySelector('[data-activity-value]').textContent='—';});
  setFilterOpen(false);
  $('ready-daily-filter-toggle').focus();
  void refresh();
 }
 filter.onsubmit=event=>{
  event.preventDefault();
  if(!canSearch())return;
  const from=fromInput.value,to=toInput.value;
  let message='';
  if(!validDate(from)||!validDate(to)||from<'1900-01-01')message='Enter both From and To dates.';
  else if(from>to)message='From date must be on or before To date.';
  else if(to>today())message='To date must be today or earlier (UAE).';
  if(message){filterError.textContent=message;filterError.hidden=false;return;}
  applyRange({from,to});
 };
 $('ready-daily-today').onclick=()=>{if(canSearch())applyRange(null);};
 const schedule=()=>{
  clearTimeout(timer);
  timer=setTimeout(()=>{
   if(summaryRead){refreshAgain=true;return;}
   void refresh();
  },200);
 };
 for(const name of ['greenloop:ready-stock-refreshed','greenloop:workflow-committed','greenloop:supplier-return-changed'])window.addEventListener(name,schedule);document.addEventListener('visibilitychange',()=>{if(!document.hidden)schedule();});
 for(const name of ['pagehide','greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(name,stop);window.addEventListener('hashchange',()=>{close();schedule();});
 window.GREENLOOP_STOCK_ACTIVITY={async request(activity,args={}){
  if(activity.range){
   try{return {data:await rangeRequest(activity.range,{...args,p_kind:activity.kind,p_expected:activity.expected}),error:null};}
   catch(error){return {data:null,error};}
  }
  const response=await GREENLOOP_GET_CLIENT().rpc('get_stock_activity_grouped_v1',{p_kind:activity.kind,p_metric:activity.metric,p_date:activity.date,p_expected:activity.expected,p_period_date:activity.period,...args});if(!response.error&&response.data?.activity_snapshot!==activity.expected)return{data:null,error:{message:'Activity scope could not be verified. Refresh the reports.'}};return response;},async refreshScope(activity){const d=await refresh();if(!d)throw Error('Refresh stock activity reports first.');
  if(activity.range){
   if(d.range_from!==activity.range.from||d.range_to!==activity.range.to)throw Error('The selected activity range changed.');
   activity.expected=d.snapshot;
   activity.total=d.reports[activity.kind];
   return;
  }
  const det=await rpc('get_stock_activity_details_v1',{p_kind:activity.kind,p_metric:activity.metric,p_date:activity.date,p_expected:d.snapshot,p_period_date:activity.period,p_offset:0,p_limit:50});activity.expected=d.snapshot;activity.total=det.quantity;},period(activity){if(activity.range)return rangeLabel(activity.range);return activity.period?date(activity.period)+(activity.metric==='monthly_average'?' · Completed month':''):date(activity.date.slice(0,8)+'01')+' – '+date(activity.date);}};
 (async()=>{await GREENLOOP_ACCESS_READY;if(!allowed())return;panel.hidden=false;fromInput.max=toInput.max=today();fromInput.value=toInput.value=today();await refresh();poll=setInterval(()=>{if(!document.hidden)void refresh();},30000);})().catch(e=>{if(allowed()){$('ready-daily-error').hidden=false;$('ready-daily-error').textContent=e.message;}});
})();
