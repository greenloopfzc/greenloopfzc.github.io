/* Live 48-hour Lab / Glass queue and read-only recorded-stay history. */
(() => {
 'use strict';
 const $=s=>document.querySelector(s),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const date=v=>v?new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:true}):'Not recorded';
 const duration=v=>{const mins=Math.floor(Math.max(0,Number(v)||0)/60);return `${Math.floor(mins/1440)}d ${Math.floor(mins%1440/60)}h ${mins%60}m`;};
 const can=cap=>window.GREENLOOP_CAN?.(cap,'overview')===true;
 async function rpc(name,args={}){const {data,error}=await window.GREENLOOP_GET_CLIENT().rpc(name,args);if(error)throw error;return data;}
 function mountHistory(container,deviceId,page){
  if(!container||!deviceId)return;
  const section=document.createElement('section');section.className='lab-delay-history';section.hidden=true;section.setAttribute('aria-label','Lab and Glass delay history');container.prepend(section);
  async function load(){section.hidden=true;try{const data=await rpc('get_lab_delay_history_v1',{p_identifier:deviceId,p_page:page});if(!section.isConnected)return;const stays=Array.isArray(data?.stays)?data.stays:[];if(!stays.length){section.remove();return;}
   section.innerHTML='<h3>Lab &amp; Glass · 2+ Days</h3>'+stays.map(s=>`<div class="lab-delay-stay"><strong>${s.ongoing?'Still waiting':'Previous delay'} · ${esc(duration(s.elapsed_seconds))}</strong><p>Arrived: ${esc(date(s.entered_at))} · ${s.ongoing?'Still in Lab &amp; Glass':'Left: '+esc(date(s.exited_at))}${s.job_number?' · '+esc(s.job_number):''}</p></div>`).join('');section.hidden=false;
  }catch(e){if(!section.isConnected)return;section.hidden=false;section.innerHTML='<p>Lab delay history could not be loaded.</p><button type="button" class="secondary-button lab-delay-retry" data-capability="view" data-capability-page="'+esc(page)+'" data-search-read-only>Retry</button>';section.querySelector('button').onclick=load;}}
  load();
 }
 const panel=$('#lab-delay-report');let filters,offset=0,total=0,busy=false,generation=0,countBusy=false;
 function message(text='',error=false){const el=$('#lab-delay-message');if(el){el.textContent=text;el.classList.toggle('is-error',error);}}
 function setCount(value,error=false){document.querySelectorAll('[data-lab-delay-count]').forEach(el=>{el.textContent=error?'—':String(value);el.closest('a')?.setAttribute('title',error?'Lab delay report could not be loaded. Click to retry.':'Phones waiting at least 48 hours in Lab & Glass');});}
 async function refreshDashboard(){if(!panel||countBusy||document.hidden)return;countBusy=true;try{const data=await rpc('get_lab_overdue_v1',{p_limit:1});setCount(data.overdue_total??data.total??0);}catch(e){setCount(null,true);}finally{countBusy=false;}}
 function pager(){ $('#lab-delay-prev').disabled=busy||offset===0;$('#lab-delay-next').disabled=busy||offset+50>=total;$('#lab-delay-page').textContent=total?`${offset+1}–${Math.min(offset+50,total)} of ${total}`:'0 records'; }
 async function load(){if(!panel||busy)return;const version=++generation;busy=true;filters.setBusy(true);pager();message();try{
  const sort=filters.sortArgs(),query=can('search')?filters.query():{};const data=await rpc('get_lab_overdue_v1',{p_filters:query,p_offset:offset,p_limit:50,p_sort_key:sort.p_sort_by||'elapsed_seconds',p_sort_direction:sort.p_sort_by?sort.p_sort_direction:'desc'});if(version!==generation)return;
  total=Number(data.total)||0;setCount(data.overdue_total??total);filters.result(data);
  $('#lab-delay-rows').innerHTML=data.rows?.length?data.rows.map(r=>`<tr><td class="lab-delay-imei">${esc(r.imei)}</td><td>${esc(r.model||'—')}</td><td>${esc(r.storage_gb?r.storage_gb+' GB':'—')}</td><td>${esc(r.color||'—')}</td><td>${esc(r.grade||'—')}</td><td>${esc(r.supplier_code||'—')}</td><td>${esc(r.department)}</td><td>${esc(r.technician_name||'Unassigned')}</td><td>${esc(date(r.entered_at))}</td><td><span class="lab-delay-age">${esc(duration(r.elapsed_seconds))}</span></td></tr>`).join(''):'<tr><td colspan="10" class="lab-delay-empty">No phones have been waiting for 48 hours or more.</td></tr>';
  filters.setBusy(false);filters.decorate?.();window.GREENLOOP_HIGHLIGHTS?.show($('#lab-delay-rows'),query._search||'');$('#lab-delay-updated').textContent='Updated '+date(data.server_time)+' · UAE';
 }catch(e){if(version===generation){message(e.message||'Could not load the report. Try Refresh.',true);$('#lab-delay-rows').innerHTML='<tr><td colspan="10">Report unavailable. Select Refresh to retry.</td></tr>';}}finally{if(version===generation){busy=false;filters.setBusy(false);pager();}}}
 function init(){if(!panel||filters)return;filters=window.GREENLOOP_FILTERS.get('lab-delay-filters',{before:$('#lab-delay-table-wrap'),sortTarget:$('#lab-delay-table'),dateKey:'entered_at',dateLabel:'Arrived',fields:[['department','Department'],['technician_name','Technician'],['model','Model']],searchFields:['imei','model','color','technician_name'],sortFields:[['imei','IMEI'],['model','Model'],['storage_gb','GB','number'],['color','Color'],['department','Department'],['technician_name','Technician'],['entered_at','Arrived','date'],['elapsed_seconds','Waiting','number']],onChange:()=>{offset=0;load();}});
 $('#lab-delay-prev').onclick=()=>{offset=Math.max(0,offset-50);load();};$('#lab-delay-next').onclick=()=>{offset+=50;load();};$('#lab-delay-refresh').onclick=()=>load();$('#lab-delay-close').onclick=()=>{panel.hidden=true;document.querySelector('[data-lab-delay-open]')?.setAttribute('aria-expanded','false');document.querySelector('[data-lab-delay-open]')?.focus();};
 document.addEventListener('click',e=>{const card=e.target.closest('[data-lab-delay-open]');if(!card)return;e.preventDefault();panel.hidden=false;card.setAttribute('aria-expanded','true');load();panel.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'start'});});
 setInterval(()=>{if(document.hidden)return;refreshDashboard();if(!panel.hidden&&!panel.contains(document.activeElement))load();},30000);window.addEventListener('focus',()=>{refreshDashboard();if(!panel.hidden)load();});}
 window.GREENLOOP_LAB_DELAY={mountHistory,refreshDashboard:()=>{init();return refreshDashboard();}};
})();
