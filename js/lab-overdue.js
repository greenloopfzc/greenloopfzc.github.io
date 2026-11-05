/* Read-only Lab overdue count -> employees -> 50 phone rows. */
(() => {
 'use strict';
 const launch=document.querySelector('#open-lab-overdue'),app=document.querySelector('#lab-overdue-app');
 if(!launch&&!app)return;
 const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const can=()=>window.GREENLOOP_PAGE_ACCESS?.pageKey==='lab_glass'&&window.GREENLOOP_CAN?.('view','lab_glass')===true;
 const number=v=>Number(v).toLocaleString('en-US');
 const age=v=>{const m=Math.floor(Math.max(0,Number(v))/60);return [Math.floor(m/1440)+'d',Math.floor(m%1440/60)+'h',m%60+'m'].join(' ');};
 const date=v=>new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:true});
 let key=null,employeeName='',offset=0,total=0,busy=false,generation=0,stopped=false,started=false,timer=null,stamp=0;
 function message(value,error=false){if(!app)return;const el=$('lo-message');el.textContent=value;el.classList.toggle('is-error',error);}
 function pager(){if(!app)return;$('lo-prev').disabled=busy||offset===0;$('lo-next').disabled=busy||offset+50>=total;$('lo-refresh').disabled=busy||!can();$('lo-back').disabled=busy;}
 function clear(){if(!app)return;$('lo-employees').replaceChildren();$('lo-phone-rows').replaceChildren();$('lo-range').textContent='';}
 function count(value,error=false){if(!launch)return;$('lab-overdue-count').textContent=error?'—':number(value);launch.title=error?'Overdue count unavailable. Open the report to retry.':'Phones pending over 2 days, excluding Sunday';launch.setAttribute('aria-label',error?'Overdue Phones — count unavailable':`Overdue Phones — ${value} phones pending over 2 days`);}
 async function read(){let timeout;try{const result=await Promise.race([window.GREENLOOP_GET_CLIENT().rpc('get_lab_overdue_report_v1',{p_employee_key:app?key:null,p_offset:app?offset:0,p_limit:app?50:1}),new Promise((_,reject)=>{timeout=setTimeout(()=>reject(Error('Overdue phones took too long to load. Select Refresh to retry.')),12000);})]);if(result.error)throw result.error;const d=result.data;
  if(!d||d.threshold_days!==2||d.sunday_excluded!==true||!Number.isSafeInteger(d.total)||d.total<0||!Number.isSafeInteger(d.phone_count)||d.phone_count<0||!Number.isSafeInteger(d.employee_count)||d.employee_count<0||!Array.isArray(d.employees)||!Array.isArray(d.rows)||d.employees.length>50||d.rows.length>50||!Number.isFinite(Date.parse(d.server_now)))throw Error('Overdue phone details could not be verified. Refresh to retry.');return d;
 }finally{clearTimeout(timeout);}}
 async function load(){if(busy||stopped||!can()||document.hidden)return;busy=true;const request=++generation,selected=key;pager();if(app){clear();message('Loading overdue phones…');app.setAttribute('aria-busy','true');}
  try{const d=await read();if(request!==generation||stopped||!can()||selected!==key)return;stamp=Date.now();count(d.phone_count);
   if(!app)return;total=d.total;if(offset&&offset>=total){offset=0;busy=false;void load();return;}
   $('lo-phone-total').textContent=number(d.phone_count);$('lo-employee-total').textContent=number(d.employee_count);$('lo-updated').textContent='Updated '+date(d.server_now)+' · UAE';
   $('lo-employees-view').hidden=key!==null;$('lo-phones-view').hidden=key===null;$('lo-back').hidden=key===null;
   $('lo-view-title').textContent=key===null?'Technicians with overdue phones':(d.employee_name||employeeName||'Technician')+' — Overdue phones';
   if(key===null){$('lo-employees').innerHTML=d.employees.length?d.employees.map(e=>`<button type="button" class="lo-employee" data-lo-employee="${esc(e.employee_key)}" data-lo-name="${esc(e.employee_name)}" data-capability="view" data-capability-page="lab_glass" data-search-read-only><strong class="lo-name">${esc(e.employee_name)}</strong><span class="lo-employee-count">${number(e.phone_count)}</span><span>overdue phone${e.phone_count===1?'':'s'}</span><small>Oldest pending: ${esc(age(e.oldest_seconds))}</small><span class="lo-view-link">View phones →</span></button>`).join(''):'<p class="lo-empty">No phones have been pending over 2 days. Sunday is excluded.</p>';}
   else{$('lo-phone-rows').innerHTML=d.rows.length?d.rows.map((p,i)=>`<tr><td>${offset+i+1}</td><td><strong>${esc(p.imei)}</strong></td><td>${esc(p.model||'Not recorded')}</td><td>${esc(p.storage_gb==null?'Not recorded':p.storage_gb>=1024?p.storage_gb/1024+' TB':p.storage_gb+' GB')}</td><td>${esc(p.color||'Not recorded')}</td><td>${esc(p.battery_health==null?'Not recorded':p.battery_health+'%')}</td><td>${esc(p.supplier_code||'Not recorded')}</td><td>${esc(p.batch_number||'Not recorded')}<small class="lo-invoice">${esc(p.invoice_number||'')}</small></td><td>${esc(p.department)}</td><td>${esc(date(p.entered_at))}</td><td><strong class="lo-age">${esc(age(p.elapsed_seconds))}</strong></td></tr>`).join(''):'<tr><td colspan="11" class="lo-empty">No overdue phones remain for this technician.</td></tr>';}
   $('lo-range').textContent=total?`${offset+1}–${Math.min(offset+50,total)} of ${number(total)} ${key===null?'technicians':'phones'}`:'0 '+(key===null?'technicians':'phones');message('');
  }catch(error){if(request===generation&&!stopped){count(null,true);if(app){clear();message(error.message||'Overdue report unavailable. Select Refresh to retry.',true);}}}
  finally{if(request===generation){busy=false;if(app)app.removeAttribute('aria-busy');pager();}}
 }
 function refresh(force=false){if(!busy&&!document.hidden&&(force||Date.now()-stamp>=10000))void load();}
 function stop(){stopped=true;++generation;busy=false;clearTimeout(timer);clear();count(null,true);if(app){app.hidden=true;app.removeAttribute('aria-busy');}if(launch){launch.setAttribute('aria-disabled','true');launch.removeAttribute('href');}pager();}
 async function initialize(){await window.GREENLOOP_ACCESS_READY;if(!can()||stopped)return;started=true;if(app){app.hidden=false;$('lo-refresh').onclick=()=>refresh(true);$('lo-prev').onclick=()=>{if(!busy&&offset>=50){offset-=50;void load();}};$('lo-next').onclick=()=>{if(!busy&&offset+50<total){offset+=50;void load();}};
   $('lo-back').onclick=()=>{if(busy)return;key=null;employeeName='';offset=0;void load();};
   $('lo-employees').onclick=e=>{const b=e.target.closest('[data-lo-employee]');if(!b||busy||!can())return;key=b.dataset.loEmployee;employeeName=b.dataset.loName;offset=0;void load();};
   const menu=open=>{document.querySelector('#sidebar')?.classList.toggle('is-open',open);$('menu-backdrop').hidden=!open;document.body.classList.toggle('menu-open',open);};$('open-menu')?.addEventListener('click',()=>menu(true));$('close-menu')?.addEventListener('click',()=>menu(false));$('menu-backdrop')?.addEventListener('click',()=>menu(false));
  }void load();timer=setInterval(()=>refresh(),30000);
 }
 document.addEventListener('greenloop:workflow-notifications-refreshed',()=>refresh());document.addEventListener('greenloop:notifications-changed',()=>refresh(true));window.addEventListener('focus',()=>refresh(true));document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh(true);});
 window.addEventListener('greenloop:office-locked',stop);window.addEventListener('pagehide',stop);window.addEventListener('greenloop:permissions-changed',()=>{if(!started)return;if(!can())stop();else{++generation;busy=false;clear();refresh(true);}});
 initialize().catch(e=>{count(null,true);if(app){$('permission-message').textContent=e.message||'Lab & Glass access could not be verified.';$('permission-message').hidden=false;}});
})();
