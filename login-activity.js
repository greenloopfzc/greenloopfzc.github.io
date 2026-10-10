(() => {
  'use strict';
  if (!window.GREENLOOP_GET_CLIENT || window.GREENLOOP_LOGIN_TRACKER) return;
  const client=window.GREENLOOP_GET_CLIENT(), page=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  let userId='', generation=0, cursor=null, busy=false, tracking=false, offset=0, allowed=false, link, notice, panel, mounted=false;
  const fmt=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:true});
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const stamp=v=>v&&Number.isFinite(new Date(v).getTime())?fmt.format(new Date(v)):'—';
  const el=id=>document.getElementById(id);
  const key=()=>`greenloop-login-alert-cursor:${userId}`;
  function reset(id='') {
    generation++;userId=id;cursor=null;allowed=false;offset=0;busy=false;
    if(link)link.remove();link=null;if(notice)notice.remove();notice=null;
    if(panel){panel.hidden=true;el('login-activity-rows').innerHTML='';el('login-activity-updated').textContent='';}
    if(id)try{const saved=localStorage.getItem(key());if(/^\d+$/.test(saved||''))cursor=saved;}catch(_){}
  }
  async function session() {
    const {data,error}=await client.auth.getSession();
    const id=!error&&data?.session?.user?.id||'';if(id!==userId)reset(id);return id;
  }
  async function touch(end=false) {
    if(tracking&&!end)return;tracking=true;
    try{if(await session())await client.rpc('touch_login_activity_v1',{p_surface:'Software',p_page:page,p_end:end});}catch(_){}finally{tracking=false;}
  }
  window.GREENLOOP_LOGIN_TRACKER={touch,refresh:()=>poll()};
  // Logging cannot prevent signing out or delay it indefinitely.
  const signOut=client.auth.signOut.bind(client.auth);
  client.auth.signOut=async (...args)=>{await Promise.race([touch(true),new Promise(r=>setTimeout(r,1200))]);const result=await signOut(...args);reset();return result;};
  client.auth.onAuthStateChange((event,data)=>{
    if(event==='SIGNED_OUT'){reset();return;}
    const id=data?.user?.id||'';if(id&&id!==userId)reset(id);
    // Supabase auth callbacks must not await another auth call.
    setTimeout(()=>{touch();poll();},0);
  });
  function mount() {
    if(mounted)return;mounted=true;
    const style=document.createElement('link');style.rel='stylesheet';style.href='css/login-activity.css?v=20261006-login-activity-1';document.head.append(style);
    if(page!=='user-access.html')return;
    const sectionHost=document.querySelector('#access-login-view');
    const host=sectionHost||document.querySelector('.user-access-content');if(!host)return;
    panel=document.createElement('section');panel.id='login-activity';panel.className='login-activity-panel access-panel';panel.hidden=true;
    panel.innerHTML=`<div class="access-panel-heading"><div><p class="panel-kicker">SUPER ADMIN ONLY</p><h2>Login Activity</h2></div><button id="login-activity-refresh" type="button" class="secondary-button">Refresh</button></div>
      <p class="login-activity-help">Software and TV sign-ins · UAE time · Refresh every 30 seconds.<br>Recently active = connection confirmed within 90 seconds. Offline can mean a closed browser or lost connection. Existing sessions are marked separately.</p>
      <form id="login-activity-filters" class="login-activity-filters"><label>User<input id="login-activity-search" maxlength="100" placeholder="Name or username"></label><label>From<input id="login-activity-from" type="date"></label><label>To<input id="login-activity-to" type="date"></label><button class="primary-button" type="submit">Apply</button><button id="login-activity-clear" class="secondary-button" type="button">Clear</button></form>
      <div class="login-activity-summary"><strong id="login-activity-count"></strong><span id="login-activity-updated"></span></div><p id="login-activity-message" role="status"></p>
      <div class="login-activity-table"><table><thead><tr><th>User</th><th>Login · UAE</th><th>Device / browser</th><th>Signed in through</th><th>Last activity · UAE</th><th>Last window</th><th>Status</th></tr></thead><tbody id="login-activity-rows"></tbody></table></div>
      <div class="login-activity-pages"><button id="login-activity-prev" class="secondary-button" type="button">Previous</button><span id="login-activity-range"></span><button id="login-activity-next" class="secondary-button" type="button">Next</button></div><p id="login-activity-since" class="login-activity-help"></p>`;
    const anchor=host.querySelector('#permission-message');anchor?anchor.after(panel):host.append(panel);
    panel.querySelectorAll('button').forEach(button=>button.setAttribute('data-search-read-only',''));
    el('login-activity-filters').addEventListener('submit',e=>{e.preventDefault();offset=0;poll();});
    el('login-activity-clear').onclick=()=>{el('login-activity-filters').reset();offset=0;poll();};
    el('login-activity-refresh').onclick=()=>poll();
    el('login-activity-prev').onclick=()=>{offset=Math.max(0,offset-25);poll();};
    el('login-activity-next').onclick=()=>{offset+=25;poll();};
  }
  function showLink() {
    if(page==='user-access.html'&&document.querySelector('.user-access-sections'))return;
    if(link||!document.querySelector('.topbar-actions'))return;
    link=document.createElement('a');link.className='secondary-button login-activity-link';link.href='user-access.html#login-activity';link.textContent='Login Activity';document.querySelector('.topbar-actions').prepend(link);
  }
  function render(data) {
    if(!panel)return;
    const firstOpen=panel.hidden;
    panel.hidden=false;
    el('login-activity-count').textContent=`${data.total_count} sign-in records · ${data.active_users} recently active users`;
    el('login-activity-updated').textContent=`Updated ${stamp(data.server_time)} UAE`;
    el('login-activity-since').textContent=`Tracking enabled ${stamp(data.installed_at)} UAE. Earlier sign-ins appear only if their sessions reconnect.`;
    el('login-activity-rows').innerHTML=data.rows.length?data.rows.map(r=>`<tr><td><strong>${esc(r.name)}</strong><small>@${esc(r.username)}</small></td><td>${esc(stamp(r.login_at))}${r.existing_session?'<small>Existing session</small>':''}</td><td>${esc(r.device)}<small>${esc(r.browser)}</small></td><td>${esc(r.login_surface)}</td><td>${esc(stamp(r.last_seen))}</td><td>${esc(r.last_surface)}<small>${esc(r.last_page.replace(/\.html$/,'').replace(/-/g,' '))}</small></td><td><span class="login-state ${r.status==='Recently active'?'is-active':''}">${esc(r.status)}</span>${r.logout_at?`<small>${esc(stamp(r.logout_at))}</small>`:''}</td></tr>`).join(''):'<tr><td colspan="7">No sign-ins match these filters.</td></tr>';
    el('login-activity-range').textContent=data.rows.length?`${offset+1}–${offset+data.rows.length} of ${data.total_count}`:'0 records';
    el('login-activity-prev').disabled=offset===0;el('login-activity-next').disabled=!data.has_more;
    el('login-activity-message').textContent='';
    if(firstOpen&&location.hash==='#login-activity')panel.scrollIntoView({block:'start'});
  }
  function alertNew(rows) {
    if(!rows.length)return;
    if(!notice){notice=document.createElement('aside');notice.className='login-activity-notice';notice.setAttribute('role','status');document.body.append(notice);}
    const last=rows[rows.length-1];
    notice.innerHTML=`<strong>New login${rows.length>1?` · ${rows.length} updates`:''}</strong><p>${esc(last.name)} (@${esc(last.username)}) · ${esc(stamp(last.login_at))} UAE · ${esc(last.device)} · ${esc(last.surface)}</p><a href="user-access.html#login-activity">View Login Activity</a><button type="button" aria-label="Dismiss login alert">×</button>`;
    notice.querySelector('button').onclick=()=>{notice.remove();notice=null;};
  }
  async function poll() {
    if(busy||document.hidden||!document.body.classList.contains('app-page'))return;
    busy=true;let mine;
    try {
      if(!await session())return;mine=generation;
      const access=await client.rpc('get_login_activity_access_v1');if(mine!==generation)return;
      const unavailable=el('login-activity-unavailable');
      if(access.error||access.data!==true){allowed=false;if(unavailable){unavailable.hidden=false;unavailable.textContent=access.error?'Login Activity access could not be checked. Select the Login Activity card again to retry.':'Only Super Admin can view Login Activity.';}if(link)link.remove();link=null;if(notice)notice.remove();notice=null;if(panel){panel.hidden=true;el('login-activity-rows').innerHTML='';}return;}
      if(unavailable)unavailable.hidden=true;
      allowed=true;mount();showLink();
      const from=el('login-activity-from')?.value||null,to=el('login-activity-to')?.value||null;
      if(from&&to&&from>to){el('login-activity-message').textContent='From date must be before or equal to To date.';return;}
      const result=await client.rpc('get_login_activity_v1',{p_search:el('login-activity-search')?.value.trim()||'',p_from:from,p_to:to,p_offset:panel?offset:0,p_limit:panel?25:1,p_after_id:cursor});
      if(mine!==generation)return;
      if(result.error){if(result.error.code==='42501'){reset(userId);return;}throw result.error;}
      const data=result.data;if(!data||!Array.isArray(data.rows)||!Array.isArray(data.alerts)||!/^\d+$/.test(data.cursor))throw Error('Login Activity response could not be verified.');
      render(data);alertNew(data.alerts);cursor=data.cursor;try{localStorage.setItem(key(),cursor);}catch(_){}
    }catch(_){if(panel&&!panel.hidden)el('login-activity-message').textContent='Live connection unavailable. The last loaded records remain below; use Refresh to retry.';else if(el('login-activity-unavailable')){el('login-activity-unavailable').hidden=false;el('login-activity-unavailable').textContent='Login Activity could not be loaded. Select the Login Activity card again to retry.';}}
    finally{if(mine===undefined||mine===generation)busy=false;}
  }
  function start(){mount();touch();poll();setInterval(()=>{if(!document.hidden){touch();poll();}},30000);}
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){touch();poll();}});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
