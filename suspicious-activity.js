(() => {
  'use strict';
  if (!document.getElementById('sa-rows')) return;
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const can = cap => window.GREENLOOP_CAN?.(cap,'suspicious_activity') === true;
  const client = () => window.GREENLOOP_GET_CLIENT();
  const stamp = value => value ? new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'numeric',minute:'2-digit',hour12:true}).format(new Date(value)) : 'Not recorded';
  const statusLabel = value => ({new:'New',investigating:'Under review',valid:'Valid activity',resolved:'Resolved'}[value] || value);
  const friendly = value => ({price_amount:'Original price / part',copy_price_amount:'Copy price / part',department:'Department',damaged_by:'Employee',employee_id:'Employee ID',part_name:'Part',quantity:'Quantity',occurred_at:'Incident time',currency_id:'Currency ID',rule_settings:'Rule settings'}[value] || value.replaceAll('_',' '));
  let filters={},sort='newest',offset=0,total=0,generation=0,detailGeneration=0,summary=null,active=null,debounce;
  async function rpc(name,args) {const result=await client().rpc(name,args);if(result.error)throw new Error(result.error.message || 'Request failed.');return result.data;}
  function message(text='') {$('sa-message').textContent=text;$('sa-message').hidden=!text;}
  function locks(root=document) {
    root.querySelectorAll('[data-capability]').forEach(el=>{if(!can(el.dataset.capability)) {if(el.matches('button,input,select,textarea'))el.disabled=true;else el.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=true);}});
    window.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(root);
  }
  function renderRows(rows) {
    $('sa-rows').innerHTML=rows.length?rows.map(a=>`<tr><td>${esc(stamp(a.occurred_at))}<small>UAE time</small></td><td><span class="sa-priority ${esc(a.priority)}">${esc(a.priority.toUpperCase())}</span></td><td><strong>${esc(a.title)}</strong><p>${esc(a.reason)}</p><small>${esc(a.department)}</small></td><td>${esc(a.actor_name)}</td><td>${esc(a.entity)}</td><td><span class="sa-status ${esc(a.status)}">${esc(statusLabel(a.status))}</span></td><td><button class="secondary-button sa-view" data-capability="view" data-sa-detail="${esc(a.id)}">View details →</button></td></tr>`).join(''):`<tr><td colspan="7" class="sa-empty"><strong>${Object.keys(filters).length?'No matching alerts':'No alerts recorded'}</strong>${Object.keys(filters).length?'Adjust or clear the filters.':'New activity matching an enabled detection rule will appear here.'}</td></tr>`;
    $('sa-result').textContent=`${total.toLocaleString()} ${Object.keys(filters).length?'matching':'recorded'} alerts · UAE time`;
    $('sa-page').textContent=total?`${offset+1}–${Math.min(offset+25,total)} of ${total}`:'0 alerts';
    $('sa-prev').disabled=offset===0;$('sa-next').disabled=offset+25>=total;
    locks($('sa-rows'));
    window.GREENLOOP_HIGHLIGHTS?.show($('sa-rows'),filters.query||'');
  }
  async function load() {
    const seq=++generation;$('sa-refresh').disabled=true;
    try {const data=await rpc('get_suspicious_alerts_v1',{p_filters:filters,p_sort:sort,p_offset:offset,p_download:false});if(seq!==generation)return;
      total=data.total;if(offset && offset>=total){offset=Math.max(0,Math.ceil(total/25)-1)*25;return load();}renderRows(data.rows);message();
    }catch(e){if(seq===generation){message(e.message);$('sa-result').textContent='Could not refresh. Previously loaded records may be out of date.';}}
    finally{if(seq===generation)$('sa-refresh').disabled=false;}
  }
  function showSummary(data){summary=data;for(const key of ['new','high','investigating','closed'])$('sa-'+key).textContent=Number(data[key]).toLocaleString();
    $('sa-connection').textContent=data.health.length?'Monitoring needs attention':'Monitoring new activity';
    $('sa-updated').textContent='Checked '+stamp(data.checked_at)+' UAE';
    $('sa-started').textContent='Monitoring started '+stamp(data.started_at)+' UAE.';
    $('sa-health').textContent=data.health.length?'Some source events could not be checked. Ask the administrator to inspect monitoring: '+data.health.map(h=>`${h.source} · ${h.failures} failures · last ${stamp(h.failed_at)} · code ${h.error_code}`).join('; '):'No detector failures recorded.';
    $('sa-coverage-rules').innerHTML=data.rules.map(r=>`<span class="sa-coverage-rule">${esc(r.label)} · ${r.enabled?'On':'Off'}</span>`).join('');
    const select=$('sa-rule-filter'),value=select.value;select.innerHTML='<option value="">All activities</option>'+data.rules.map(r=>`<option value="${esc(r.key)}">${esc(r.label)}</option>`).join('');select.value=value;
  }
  async function refreshSummary(){try {const data=await rpc('get_suspicious_summary_v1');showSummary(data);window.dispatchEvent(new CustomEvent('greenloop:suspicious-summary',{detail:data}));}catch(e){$('sa-connection').textContent='Monitoring status unavailable';message(e.message);}}
  function readFilters(){const f={};for(const [k,v] of new FormData($('sa-filters')))if(String(v).trim())f[k]=String(v).trim();filters=f;offset=0;$('sa-filter-count').textContent=Object.keys(f).length?`(${Object.keys(f).length})`:'';load();}
  $('sa-filters-toggle').addEventListener('click',()=>{const open=$('sa-filters').hidden;$('sa-filters').hidden=!open;$('sa-filters-toggle').setAttribute('aria-expanded',String(open));if(open)$('sa-filters').querySelector('input').focus();});
  $('sa-filters').addEventListener('submit',e=>{e.preventDefault();if(can('search')){clearTimeout(debounce);readFilters();}});
  $('sa-filters').addEventListener('input',()=>{if(!can('search'))return;clearTimeout(debounce);debounce=setTimeout(readFilters,220);});
  $('sa-clear').addEventListener('click',()=>{if(can('search')){$('sa-filters').reset();readFilters();}});
  document.querySelectorAll('[data-sa-preset]').forEach(b=>b.addEventListener('click',()=>{if(!can('search'))return;$('sa-filters').reset();if(b.dataset.saPreset==='high'){$('sa-filters').elements.priority.value='high';$('sa-filters').elements.status.value='open';}else $('sa-filters').elements.status.value=b.dataset.saPreset;readFilters();}));
  document.querySelectorAll('[data-sa-sort]').forEach(b=>b.addEventListener('click',()=>{if(!can('sort'))return;sort=b.dataset.saSort==='time'?(sort==='newest'?'oldest':'newest'):b.dataset.saSort==='name'?(sort==='name_asc'?'name_desc':'name_asc'):'priority';offset=0;document.querySelectorAll('.sa-table th').forEach(th=>th.removeAttribute('aria-sort'));document.querySelectorAll('[data-sa-sort]').forEach(el=>{const selected=el===b,desc=sort==='newest'||sort==='name_desc';el.textContent=({time:'Date & time',priority:'Priority',name:'User'}[el.dataset.saSort])+' '+(selected?(desc?'↓':'↑'):'↕');});b.closest('th').setAttribute('aria-sort',sort==='newest'||sort==='name_desc'?'descending':'ascending');load();}));
  $('sa-prev').addEventListener('click',()=>{if(offset){offset-=25;load();}});$('sa-next').addEventListener('click',()=>{if(offset+25<total){offset+=25;load();}});
  $('sa-refresh').addEventListener('click',()=>{load();refreshSummary();});
  document.querySelectorAll('[data-sa-close]').forEach(b=>b.addEventListener('click',()=>b.closest('dialog').close()));
  const printableValue=(key,value)=>value==null?'Not recorded':typeof value==='boolean'?(value?'Yes':'No'):typeof value==='object'?JSON.stringify(value):/time|date|received|observed|entered|rework|qc|occurred_at/i.test(key)&&/^\d{4}-\d{2}-\d{2}T/.test(String(value))?stamp(value):String(value);
  function evidenceMarkup(ev){const before=ev.Before,after=ev.After;let changes='';
    if(before && typeof before==='object'){const keys=[...new Set([...Object.keys(before),...Object.keys(after||{})])].filter(k=>JSON.stringify(before[k])!==JSON.stringify(after?.[k]));changes=`<h3>Recorded changes</h3><table class="sa-changes"><thead><tr><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>${keys.map(k=>`<tr><td>${esc(friendly(k))}</td><td>${esc(printableValue(k,before[k]))}</td><td>${after===null?'Removed':esc(printableValue(k,after?.[k]))}</td></tr>`).join('')}</tbody></table>`;}
    const facts=Object.entries(ev).filter(([k])=>!['Before','After','Context','rule_settings'].includes(k));
    return `<dl class="sa-facts">${facts.map(([k,v])=>`<div class="sa-fact${k==='Correction reason'?' wide':''}"><dt>${esc(friendly(k))}</dt><dd>${esc(printableValue(k,v))}</dd></div>`).join('')}</dl>${changes}${ev.Context?`<p class="sa-context">${esc(ev.Context)}</p>`:''}${Object.keys(ev.rule_settings||{}).length?`<p class="sa-context">Rule settings at detection: ${esc(Object.entries(ev.rule_settings).map(([k,v])=>`${friendly(k)}: ${v}`).join(' · '))}</p>`:''}`;
  }
  async function openDetail(id){const seq=++detailGeneration;$('sa-detail-title').textContent='Loading evidence…';$('sa-detail-body').innerHTML='<div class="sa-dialog-body">Loading…</div>';if(!$('sa-detail').open)$('sa-detail').showModal();
    try {const a=await rpc('get_suspicious_detail_v1',{p_id:id});if(seq!==detailGeneration)return;active=a;$('sa-detail-title').textContent=a.title;
      $('sa-detail-body').innerHTML=`<div class="sa-dialog-body"><span class="sa-priority ${esc(a.priority)}">${esc(a.priority.toUpperCase())}</span> <span class="sa-status ${esc(a.status)}">${esc(statusLabel(a.status))}</span><p class="sa-context">${esc(a.actor_name)} · ${esc(stamp(a.occurred_at))} UAE</p><section class="sa-why"><strong>Why this was flagged</strong><p>${esc(a.reason)}</p></section>${evidenceMarkup(a.evidence)}<h3>Review history</h3><ul class="sa-review-history">${a.reviews.length?a.reviews.map(r=>`<li><strong>${esc(statusLabel(r.new_status))}</strong> · ${esc(r.actor_name)}<small> · ${esc(stamp(r.occurred_at))} UAE</small><p>${esc(r.note)}</p></li>`).join(''):'<li>Not reviewed yet.</li>'}</ul>${can('review')?`<form id="sa-review-form" class="sa-review" data-capability="review"><label>Review decision<select name="status"><option value="investigating">Needs investigation</option><option value="valid">Valid activity</option><option value="resolved">Resolved</option><option value="new">Reopen</option></select></label><label>Review note<textarea name="note" required minlength="3" maxlength="2000" placeholder="Explain what you checked and the outcome…"></textarea></label><button class="primary-button" type="submit">Save review</button><p class="sa-inline-message" role="status"></p></form>`:''}</div>`;
      locks($('sa-detail'));$('sa-review-form')?.addEventListener('submit',saveReview);
    }catch(e){if(seq===detailGeneration){$('sa-detail-title').textContent='Evidence unavailable';$('sa-detail-body').innerHTML=`<div class="sa-dialog-body">${esc(e.message)}</div>`;}}
  }
  $('sa-rows').addEventListener('click',e=>{const b=e.target.closest('[data-sa-detail]');if(b)openDetail(b.dataset.saDetail);});
  async function saveReview(e){e.preventDefault();if(!can('review')||!active)return;const form=e.currentTarget,button=form.querySelector('button'),msg=form.querySelector('.sa-inline-message');button.disabled=true;
    try{await rpc('review_suspicious_alert_v1',{p_id:active.id,p_status:form.elements.status.value,p_note:form.elements.note.value,p_revision:active.revision});await openDetail(active.id);load();refreshSummary();}catch(err){msg.textContent=err.message;button.disabled=false;}
  }
  function renderRules(){$('sa-rules-body').innerHTML=(summary?.rules||[]).map(r=>`<form class="sa-rule" data-rule="${esc(r.key)}" data-revision="${r.revision}" data-capability="manage_rules"><label><input name="enabled" type="checkbox"${r.enabled?' checked':''}>${esc(r.label)}</label>${r.key==='fast_ready'?`<div class="sa-rule-values"><label>Flag repair completion below <input name="minutes" type="number" min="1" max="120" value="${r.settings.minutes}" required> minutes</label></div>`:r.key==='outside_hours'?`<p>UAE working hours. Overnight shifts are supported. This rule starts disabled until you choose your hours.</p><div class="sa-rule-values"><label>Start hour<input name="start_hour" type="number" min="0" max="23" value="${r.settings.start_hour}" required></label><label>End hour<input name="end_hour" type="number" min="0" max="23" value="${r.settings.end_hour}" required></label></div>`:''}<button type="submit" class="secondary-button">Save rule</button><span class="sa-inline-message" role="status"></span></form>`).join('');locks($('sa-rules'));}
  $('sa-rules-open').addEventListener('click',()=>{if(!can('manage_rules'))return;renderRules();$('sa-rules').showModal();});
  $('sa-rules-body').addEventListener('submit',async e=>{e.preventDefault();if(!can('manage_rules'))return;const f=e.target,settings={};for(const el of f.querySelectorAll('input[type="number"]'))settings[el.name]=Number(el.value);const b=f.querySelector('button'),m=f.querySelector('.sa-inline-message');b.disabled=true;
    try{await rpc('save_suspicious_rule_v1',{p_key:f.dataset.rule,p_enabled:f.elements.enabled.checked,p_settings:settings,p_revision:Number(f.dataset.revision)});f.dataset.revision=String(Number(f.dataset.revision)+1);m.textContent='Rule saved.';refreshSummary();}catch(err){m.textContent=err.message;}finally{b.disabled=false;}
  });
  $('sa-download').addEventListener('click',async()=>{if(!can('download'))return;const b=$('sa-download');b.disabled=true;try{const data=await rpc('get_suspicious_alerts_v1',{p_filters:filters,p_sort:sort,p_offset:0,p_download:true});
    const csvCell=v=>'"'+String(v??'').replace(/^[\s]*[=+@-]/,"'$&").replaceAll('"','""')+'"';
    const lines=[['UAE date & time','Priority','Activity','Why flagged','User','IMEI / box / employee','Department','Status'],...data.rows.map(a=>[stamp(a.occurred_at),a.priority,a.title,a.reason,a.actor_name,a.entity,a.department,statusLabel(a.status)])];
    const url=URL.createObjectURL(new Blob(['\ufeff'+lines.map(row=>row.map(csvCell).join(',')).join('\r\n')],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download='Greenloop-Suspicious-Activity.csv';a.dataset.capability='download';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }catch(e){message(e.message);}finally{b.disabled=false;}});
  window.addEventListener('greenloop:suspicious-summary',e=>{if(e.detail!==summary){showSummary(e.detail);if(!$('sa-detail').open&&!$('sa-rules').open)load();}});
  (async()=>{await window.GREENLOOP_ACCESS_READY;if(!can('view'))return;locks();await Promise.all([load(),refreshSummary()]);})();
})();
