(() => {
  'use strict';
  const key='greenloop-appearance-v1';
  const root=document.documentElement;
  root.dataset.glPage=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  root.dataset.appearanceVersion='20260923-neumorphism-1';
  const normalise=value=>({design:value?.design==='neumorphism'?'neumorphism':'classic',mode:value?.mode==='dark'?'dark':'light'});
  const read=()=>{try{return normalise(JSON.parse(localStorage.getItem(key)||'{}'));}catch{return normalise({});}};
  let choice=read(),dialog,lastTrigger;
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
  function mount(){
    if(document.getElementById('gl-appearance-settings'))return;
    dialog=document.createElement('dialog');dialog.id='gl-appearance-settings';dialog.className='gl-appearance-dialog';
    dialog.setAttribute('aria-labelledby','gl-appearance-title');
    dialog.innerHTML=`<div class="gl-settings-heading"><div><p class="gl-settings-eyebrow">SETTINGS</p><h2 id="gl-appearance-title">Appearance</h2><p>Choose a theme and display mode.</p></div><button type="button" class="gl-settings-close" aria-label="Close appearance settings">×</button></div>
      <fieldset><legend>Theme</legend><div class="gl-theme-options"><label class="gl-theme-option"><input type="radio" name="gl-design" value="classic"><span class="gl-theme-swatch gl-classic-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Existing theme</strong><small>Familiar Greenloop layout</small></label><label class="gl-theme-option"><input type="radio" name="gl-design" value="neumorphism"><span class="gl-theme-swatch gl-neo-swatch" aria-hidden="true"><i></i><i></i><i></i></span><strong>Neumorphism</strong><small>Soft raised cards and controls</small></label></div></fieldset>
      <fieldset><legend>Display mode</legend><div class="gl-mode-options"><label><input type="radio" name="gl-mode" value="light"><span aria-hidden="true">☀</span>Light</label><label><input type="radio" name="gl-mode" value="dark"><span aria-hidden="true">☾</span>Dark</label></div></fieldset>
      <div class="gl-settings-footer"><span id="gl-appearance-saved" role="status">Your choice is saved on this browser.</span><button class="gl-settings-done" type="button">Done</button></div>`;
    document.body.append(dialog);render();
    const close=()=>dialog.close();
    dialog.querySelector('.gl-settings-close').addEventListener('click',close);
    dialog.querySelector('.gl-settings-done').addEventListener('click',close);
    dialog.addEventListener('close',()=>{if(lastTrigger?.isConnected)lastTrigger.focus();});
    dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();});
    dialog.addEventListener('change',event=>{
      if(event.target.name==='gl-design')choice=normalise({...choice,design:event.target.value});
      else if(event.target.name==='gl-mode')choice=normalise({...choice,mode:event.target.value});
      else return;
      render();
      let message='Saved. Your next screen will use this appearance.';
      try{localStorage.setItem(key,JSON.stringify(choice));}catch{message='Applied for now. This browser could not save the choice.';}
      document.getElementById('gl-appearance-saved').textContent=message;
    });
    const open=event=>{lastTrigger=event.currentTarget;if(!dialog.open)dialog.showModal();};
    function addButton(host,className,label){
      if(host.querySelector('[data-gl-appearance]'))return;
      const button=document.createElement('button');button.type='button';button.className=className;button.dataset.glAppearance='';
      button.setAttribute('aria-haspopup','dialog');button.setAttribute('aria-controls',dialog.id);
      button.innerHTML=`<span class="nav-icon" aria-hidden="true">⚙</span><span>${label}</span>`;
      button.addEventListener('click',open);host.append(button);
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
