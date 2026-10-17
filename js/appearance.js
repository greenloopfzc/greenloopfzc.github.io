(() => {
  'use strict';
  const key='greenloop-appearance-v1';
  const root=document.documentElement;
  root.dataset.glPage=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  root.dataset.appearanceVersion='20261017-settings-appearance-1';
  const normalise=value=>({design:value?.design==='neumorphism'?'neumorphism':'classic',mode:value?.mode==='dark'?'dark':'light'});
  const read=()=>{try{return normalise(JSON.parse(localStorage.getItem(key)||'{}'));}catch{return normalise({});}};
  let choice=read(),dialog,lastTrigger;
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
    dialog.querySelectorAll('input[name="gl-design"]').forEach(input=>setControlAccess(input,can('theme')));
    dialog.querySelectorAll('input[name="gl-mode"]').forEach(input=>setControlAccess(input,can('display_mode')));
    dialog.querySelector('[data-appearance-note="theme"]').hidden=can('theme');
    dialog.querySelector('[data-appearance-note="display_mode"]').hidden=can('display_mode');
    if(!canOpen()&&dialog.open)dialog.close();
  }
  function render(){
    root.dataset.design=choice.design;root.dataset.mode=choice.mode;
    root.style.colorScheme=choice.mode;
    if(dialog){
      dialog.querySelectorAll('input[name="gl-design"]').forEach(el=>el.checked=el.value===choice.design);
      dialog.querySelectorAll('input[name="gl-mode"]').forEach(el=>el.checked=el.value===choice.mode);
    }
  }
  render();
  window.addEventListener('storage',event=>{if(event.key===key||event.key===null){choice=read();render();}});
  window.addEventListener('greenloop:access-ready',syncAccess);
  // Appearance is a browser preference, authorized independently of data entry.
  // Keep the local handler fail-closed even before the shared guard is ready.
  window.addEventListener('change',event=>{
    const input=event.target;
    if(!input.closest?.('#gl-appearance-settings') || !['gl-design','gl-mode'].includes(input.name))return;
    if(!can(input.name==='gl-design'?'theme':'display_mode')){
      render();syncAccess();event.preventDefault();event.stopImmediatePropagation();
    }
  },true);
  function mount(){
    if(document.getElementById('gl-appearance-settings'))return;
    dialog=document.createElement('dialog');dialog.id='gl-appearance-settings';dialog.className='gl-appearance-dialog';
    dialog.setAttribute('aria-labelledby','gl-appearance-title');
    dialog.innerHTML=`<div class="gl-settings-heading"><div><p class="gl-settings-eyebrow">SETTINGS</p><h2 id="gl-appearance-title">Appearance</h2><p>Choose a theme and display mode.</p></div><button type="button" class="gl-settings-close" aria-label="Close appearance settings">&times;</button></div>
      <fieldset><legend>Theme</legend><div class="gl-theme-options"><label class="gl-theme-option"><input type="radio" name="gl-design" value="classic" disabled><span class="gl-theme-swatch gl-classic-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Existing theme</strong><small>Familiar Greenloop layout</small></label><label class="gl-theme-option"><input type="radio" name="gl-design" value="neumorphism" disabled><span class="gl-theme-swatch gl-neo-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Neumorphism</strong><small>Soft raised cards and controls</small></label></div><p class="gl-settings-access-note" data-appearance-note="theme">Theme changes are not enabled for your account.</p></fieldset>
      <fieldset><legend>Display mode</legend><div class="gl-mode-options"><label><input type="radio" name="gl-mode" value="light" disabled><span aria-hidden="true">&#9728;</span>Light</label><label><input type="radio" name="gl-mode" value="dark" disabled><span aria-hidden="true">&#9790;</span>Dark</label></div><p class="gl-settings-access-note" data-appearance-note="display_mode">Display mode changes are not enabled for your account.</p></fieldset>
      <div class="gl-settings-footer"><span id="gl-appearance-saved" role="status">Your choice is saved on this browser.</span><button class="gl-settings-done" type="button">Done</button></div>`;
    document.body.append(dialog);render();syncAccess();
    const close=()=>dialog.close();
    dialog.querySelector('.gl-settings-close').addEventListener('click',close);
    dialog.querySelector('.gl-settings-done').addEventListener('click',close);
    dialog.addEventListener('close',()=>{if(lastTrigger?.isConnected&&!lastTrigger.disabled)lastTrigger.focus();});
    dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();});
    dialog.addEventListener('change',event=>{
      if(event.target.name==='gl-design'&&can('theme'))choice=normalise({...choice,design:event.target.value});
      else if(event.target.name==='gl-mode'&&can('display_mode'))choice=normalise({...choice,mode:event.target.value});
      else{render();syncAccess();return;}
      render();
      let message='Saved. Your next screen will use this appearance.';
      try{localStorage.setItem(key,JSON.stringify(choice));}catch{message='Applied for now. This browser could not save the choice.';}
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
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
