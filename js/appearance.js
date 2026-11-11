(() => {
  'use strict';
  const key='greenloop-appearance-v1',accountPrefix='greenloop-appearance-account-v2:';
  const ruby='ruby-obsidian',version='20261111-ruby-obsidian-1';
  let accountId='',adminVerified=false,contextEpoch=0,authClient=null;
  const root=document.documentElement;
  root.dataset.glPage=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  root.dataset.appearanceVersion=version;
  const normalise=(value,allowRuby=false)=>({design:allowRuby&&value?.design===ruby?ruby:value?.design==='neumorphism'?'neumorphism':'classic',mode:value?.mode==='dark'?'dark':'light'});
  const read=()=>{try{return normalise(JSON.parse(localStorage.getItem(key)||'{}'));}catch{return normalise({});}};
  let choice=read(),dialog,lastTrigger;
  const storageKey=()=>accountId?accountPrefix+accountId:key;
  function readAccount(){try{const saved=accountId&&localStorage.getItem(storageKey());return saved?normalise(JSON.parse(saved),adminVerified):read();}catch{return read();}}
  function loadRubyStyles(){if(document.getElementById('gl-ruby-theme-style'))return;const link=document.createElement('link');link.id='gl-ruby-theme-style';link.rel='stylesheet';link.href='css/ruby-obsidian.css?v='+version;document.head.append(link);if(!document.getElementById('gl-ruby-font')){const font=document.createElement('link');font.id='gl-ruby-font';font.rel='stylesheet';font.href='https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap';document.head.append(font);}}
  function clearAccount(){contextEpoch++;accountId='';adminVerified=false;choice=read();render();syncAccess();}
  async function refreshAccount(){
    const epoch=++contextEpoch;
    try{
      const client=window.GREENLOOP_GET_CLIENT?.();if(!client||!window.GREENLOOP_PAGE_ACCESS){clearAccount();return;}
      if(authClient!==client&&client.auth.onAuthStateChange){authClient=client;client.auth.onAuthStateChange((event)=>{if(['SIGNED_OUT','SIGNED_IN','USER_UPDATED'].includes(event)){clearAccount();if(event!=='SIGNED_OUT')window.setTimeout(refreshAccount,0);}});}
      const session=await client.auth.getSession();const id=session?.data?.session?.user?.id;
      if(epoch!==contextEpoch)return;
      if(session.error||typeof id!=='string'||!id){clearAccount();return;}
      // The same verified Owner/Super Admin boundary used by User Access. Never use a username or browser-stored role.
      const role=await client.rpc('has_role',{required_roles:['super_admin','owner']});
      if(epoch!==contextEpoch)return;
      accountId=id;adminVerified=!role.error&&role.data===true;choice=readAccount();if(adminVerified)loadRubyStyles();render();syncAccess();
    }catch{if(epoch===contextEpoch)clearAccount();}
  }
  const can=capability=>Boolean(window.GREENLOOP_PAGE_ACCESS && typeof window.GREENLOOP_CAN==='function' && window.GREENLOOP_CAN(capability,'appearance'));
  const canOpen=()=>can('theme')||can('display_mode');
  function setControlAccess(control,allowed){
    if(control.disabled===allowed)control.disabled=!allowed;
    if(allowed){
      control.removeAttribute('aria-disabled');control.removeAttribute('data-view-only-locked');
      if(control.title==='Access not granted')control.removeAttribute('title');
    }else{
      if(control.getAttribute('aria-disabled')!=='true')control.setAttribute('aria-disabled','true');
      if(control.title!=='Access not granted')control.title='Access not granted';
    }
  }
  function syncAccess(){
    document.querySelectorAll('[data-gl-appearance]').forEach(button=>setControlAccess(button,canOpen()));
    if(!dialog)return;
    dialog.querySelector('[data-ruby-option]').hidden=!adminVerified;
    dialog.querySelectorAll('input[name="gl-design"]').forEach(input=>setControlAccess(input,can('theme')&&(input.value!==ruby||adminVerified)));
    dialog.querySelectorAll('input[name="gl-mode"]').forEach(input=>setControlAccess(input,can('display_mode')&&choice.design!==ruby));
    dialog.querySelector('[data-appearance-note="theme"]').hidden=can('theme');
    dialog.querySelector('[data-appearance-note="display_mode"]').hidden=can('display_mode');
    dialog.querySelector('[data-ruby-mode-note]').hidden=choice.design!==ruby;
    if(!canOpen()&&dialog.open)dialog.close();
  }
  function render(){
    const design=choice.design===ruby&&!adminVerified?read().design:choice.design;
    const mode=design===ruby?'dark':choice.mode;
    root.dataset.design=design;root.dataset.mode=mode;
    if(design===ruby){root.dataset.theme=ruby;loadRubyStyles();}else delete root.dataset.theme;
    root.style.colorScheme=mode;
    if(dialog){
      dialog.querySelectorAll('input[name="gl-design"]').forEach(el=>el.checked=el.value===choice.design);
      dialog.querySelectorAll('input[name="gl-mode"]').forEach(el=>el.checked=el.value===mode);
    }
  }
  render();
  window.addEventListener('storage',event=>{if(event.key==='greenloop-app-session-change-v1'){clearAccount();window.setTimeout(refreshAccount,0);return;}if(event.key===storageKey()||event.key===key||event.key===null){choice=readAccount();render();syncAccess();}});
  window.addEventListener('greenloop:access-ready',()=>{syncAccess();refreshAccount();});
  window.addEventListener('greenloop:office-locked',clearAccount);
  window.addEventListener('pageshow',event=>{if(event.persisted)refreshAccount();});
  // Appearance is a browser preference, authorized independently of data entry.
  // Keep the local handler fail-closed even before the shared guard is ready.
  window.addEventListener('change',event=>{
    const input=event.target;
    if(!input.closest?.('#gl-appearance-settings') || !['gl-design','gl-mode'].includes(input.name))return;
    if(!can(input.name==='gl-design'?'theme':'display_mode')||(input.value===ruby&&!adminVerified)||(input.name==='gl-mode'&&choice.design===ruby)){
      render();syncAccess();event.preventDefault();event.stopImmediatePropagation();
    }
  },true);
  function mount(){
    if(document.getElementById('gl-appearance-settings'))return;
    dialog=document.createElement('dialog');dialog.id='gl-appearance-settings';dialog.className='gl-appearance-dialog';
    dialog.setAttribute('aria-labelledby','gl-appearance-title');
    dialog.innerHTML=`<div class="gl-settings-heading"><div><p class="gl-settings-eyebrow">SETTINGS</p><h2 id="gl-appearance-title">Appearance</h2><p>Choose a theme and display mode.</p></div><button type="button" class="gl-settings-close" aria-label="Close appearance settings">&times;</button></div>
      <fieldset><legend>Theme</legend><div class="gl-theme-options"><label class="gl-theme-option"><input type="radio" name="gl-design" value="classic" disabled><span class="gl-theme-swatch gl-classic-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Existing theme</strong><small>Familiar Greenloop layout</small></label><label class="gl-theme-option"><input type="radio" name="gl-design" value="neumorphism" disabled><span class="gl-theme-swatch gl-neo-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Neumorphism</strong><small>Soft raised cards and controls</small></label><label class="gl-theme-option" data-ruby-option hidden><input type="radio" name="gl-design" value="ruby-obsidian" disabled><span class="gl-theme-swatch gl-ruby-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Ruby Obsidian Glass</strong><small>Admin only · Black &amp; ruby glass</small></label></div><p class="gl-settings-access-note" data-appearance-note="theme">Theme changes are not enabled for your account.</p></fieldset>
      <fieldset><legend>Display mode</legend><div class="gl-mode-options"><label><input type="radio" name="gl-mode" value="light" disabled><span aria-hidden="true">&#9728;</span>Light</label><label><input type="radio" name="gl-mode" value="dark" disabled><span aria-hidden="true">&#9790;</span>Dark</label></div><p class="gl-settings-access-note" data-appearance-note="display_mode">Display mode changes are not enabled for your account.</p></fieldset>
      <p class="gl-settings-access-note" data-ruby-mode-note hidden>Ruby Obsidian Glass uses its own dark palette. Choose another theme to use Light mode.</p><div class="gl-settings-footer"><span id="gl-appearance-saved" role="status">Your choice is saved for your account on this browser.</span><button class="gl-settings-done" type="button">Done</button></div>`;
    document.body.append(dialog);render();syncAccess();
    const close=()=>dialog.close();
    dialog.querySelector('.gl-settings-close').addEventListener('click',close);
    dialog.querySelector('.gl-settings-done').addEventListener('click',close);
    dialog.addEventListener('close',()=>{if(lastTrigger?.isConnected&&!lastTrigger.disabled)lastTrigger.focus();});
    dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();});
    dialog.addEventListener('change',event=>{
      if(event.target.name==='gl-design'&&can('theme'))choice=normalise({...choice,design:event.target.value},adminVerified);
      else if(event.target.name==='gl-mode'&&can('display_mode'))choice=normalise({...choice,mode:event.target.value},adminVerified);
      else{render();syncAccess();return;}
      render();syncAccess();
      let message='Saved for your account on this browser.';
      try{localStorage.setItem(storageKey(),JSON.stringify(choice));}catch{message='Applied for now. This browser could not save the choice.';}
      document.getElementById('gl-appearance-saved').textContent=message;
    });
    const open=event=>{syncAccess();if(!canOpen())return;lastTrigger=event.currentTarget;if(!dialog.open)dialog.showModal();};
    function addButton(host,className,label){
      if(host.querySelector('[data-gl-appearance]'))return;
      const button=document.createElement('button');button.type='button';button.className=className;button.dataset.glAppearance='';button.disabled=true;
      button.setAttribute('aria-haspopup','dialog');button.setAttribute('aria-controls',dialog.id);
      button.innerHTML=`<span class="nav-icon" aria-hidden="true">&#9881;</span><span>${label}</span>`;
      button.addEventListener('click',open);host.append(button);setControlAccess(button,canOpen());
    }
    const nav=document.querySelector('.sidebar-nav');
    if(nav){
      const ensure=()=>addButton(nav,'nav-item gl-appearance-nav','Settings');
      ensure();new MutationObserver(ensure).observe(nav,{childList:true});
    }else{addButton(document.body,'gl-appearance-floating','Settings');}
    const tvActions=document.querySelector('.lab-live-actions');
    if(tvActions)addButton(tvActions,'secondary-button gl-appearance-tv','Settings');
    if(window.GREENLOOP_PAGE_ACCESS)refreshAccount();
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
