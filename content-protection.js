/* Ordinary page-content restrictions and explicitly client-reported security signals.
   OS capture is not observable or guaranteed preventable by a website. */
(() => {
 'use strict';
 if(window.GREENLOOP_CONTENT_PROTECTION)return;
 const version='20261109-content-protection-1',abort=new AbortController(),options={capture:true,signal:abort.signal};
 let active=false,stopped=false,actor='',page='',queue=[],sending=false,retryTimer,noticeTimer,coverTimer,cover,notice,drag=null,subscription;
 const recent=new Map(),client=()=>window.GREENLOOP_GET_CLIENT();
 const element=node=>node?.nodeType===1?node:node?.parentElement;
 const ignored=target=>!!element(target)?.closest('#gl-content-notice,#gl-content-cover');
 function editable(target){const el=element(target),control=el?.closest('input,textarea,select,[contenteditable]');return !!control&&!control.disabled&&!control.readOnly&&(control.matches('input,textarea,select')||control.isContentEditable);}
 function pageKey(){const key=window.GREENLOOP_PAGE_ACCESS?.pageKey;if(key==='manual_damage_report')return window.GREENLOOP_CAN?.('view','damage_report')?'damage_report':'tv_manual_entry';if(key==='supplier_returns')return ['supplier_returns','supplier_return_approval','supplier_return_handover'].find(p=>window.GREENLOOP_CAPABILITIES?.[p]?.includes('view'))||key;return key;}
 const allowed=()=>active&&!stopped&&pageKey()===page&&window.GREENLOOP_CAN?.('view',page)===true;
 function inform(text){if(!notice){notice=document.createElement('div');notice.id='gl-content-notice';notice.setAttribute('role','status');notice.setAttribute('aria-live','polite');document.body.append(notice);}notice.textContent=text;notice.hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>{notice.hidden=true;},3200);}
 function conceal(){if(!cover){cover=document.createElement('dialog');cover.id='gl-content-cover';cover.setAttribute('aria-label','Screen capture restriction');cover.innerHTML='<div><span aria-hidden="true">🔒</span><h2>Screen capture is restricted</h2><p>A capture shortcut was detected. Screenshot completion cannot be confirmed by this website.</p></div>';cover.addEventListener('cancel',e=>e.preventDefault());document.body.append(cover);}if(!cover.open)cover.showModal();clearTimeout(coverTimer);coverTimer=setTimeout(()=>cover?.close(),1500);}
 function uuid(){if(crypto.randomUUID)return crypto.randomUUID();const a=crypto.getRandomValues(new Uint8Array(16));a[6]=(a[6]&15)|64;a[8]=(a[8]&63)|128;return [...a].map((x,i)=>([4,6,8,10].includes(i)?'-':'')+x.toString(16).padStart(2,'0')).join('');}
 async function flush(){
  if(sending||!allowed()||!queue.length)return;sending=true;
  try{
   const session=await client().auth.getSession();if(session.error||session.data?.session?.user?.id!==actor){stop();return;}
   while(queue.length&&allowed()){
    const item=queue[0];let result;
    try{result=await client().rpc('log_content_protection_attempt_v1',{p_action:item.action,p_page:page,p_request_id:item.id});}catch{break;}
    if(result.error){if(['42501','PGRST301','PGRST303'].includes(result.error.code)){queue=[];break;}if(['22023','22P02'].includes(result.error.code)){queue.shift();continue;}break;}
    queue.shift();if(result.data?.accepted){window.dispatchEvent(new Event('greenloop:security-attempt-logged'));try{localStorage.setItem('greenloop-security-attempt-v1',Date.now()+'-'+item.id);}catch{}}
   }
  }finally{sending=false;if(queue.length&&allowed()){clearTimeout(retryTimer);retryTimer=setTimeout(flush,10000);}}
 }
 function report(action){if(!allowed())return;const now=performance.now(),previous=recent.get(action)??-Infinity;if(now-previous<2000)return;recent.set(action,now);if(queue.length<20)queue.push({id:uuid(),action});void flush();}
 function restrict(e,action,capture=false){if(!e.isTrusted||!allowed()||ignored(e.target))return;e.preventDefault();e.stopImmediatePropagation();if(!capture)window.getSelection()?.removeAllRanges();if(capture)conceal();else inform('Selecting or copying protected page content is restricted. Entry and search fields remain available.');report(action);}
 function captureAction(e){
  if(e.key==='PrintScreen'||e.code==='PrintScreen')return e.altKey?'alt_print_screen':'print_screen';
  if(e.metaKey&&e.shiftKey&&(e.code==='KeyS'||e.key?.toLowerCase()==='s'))return 'windows_snip';
  if(e.ctrlKey&&e.shiftKey&&(e.code==='KeyS'||e.key?.toLowerCase()==='s')&&/Edg\//.test(navigator.userAgent))return 'edge_capture';
  if(e.metaKey&&e.shiftKey&&['Digit3','Digit4','Digit5'].includes(e.code))return 'mac_capture';
  return null;
 }
 function textAt(e){
  if(editable(e.target)||ignored(e.target)||element(e.target)?.closest('button,a,select,[role="button"],label:has(input)'))return false;
  const position=document.caretPositionFromPoint?.(e.clientX,e.clientY),range=position?null:document.caretRangeFromPoint?.(e.clientX,e.clientY),node=position?.offsetNode||range?.startContainer;
  if(node?.nodeType!==3||!node.textContent?.trim()||editable(node))return false;
  const bounds=document.createRange();bounds.selectNodeContents(node);return [...bounds.getClientRects()].some(r=>e.clientX>=r.left&&e.clientX<=r.right&&e.clientY>=r.top&&e.clientY<=r.bottom);
 }
 function stop(){if(stopped)return;stopped=true;active=false;queue=[];drag=null;abort.abort();clearTimeout(retryTimer);clearTimeout(coverTimer);clearTimeout(noticeTimer);cover?.remove();notice?.remove();document.documentElement.classList.remove('gl-content-protected');subscription?.unsubscribe();}
 const style=document.createElement('style');style.id='gl-content-protection-style';style.textContent=`
 html.gl-content-protected body,html.gl-content-protected body *{-webkit-user-select:none!important;user-select:none!important}
 html.gl-content-protected input:not([disabled]):not([readonly]),html.gl-content-protected textarea:not([disabled]):not([readonly]),html.gl-content-protected [contenteditable="true"],html.gl-content-protected [contenteditable="true"] *{-webkit-user-select:text!important;user-select:text!important}
 #gl-content-notice{position:fixed;right:20px;bottom:20px;z-index:2147483646;max-width:min(420px,calc(100vw - 40px));padding:14px 18px;border:1px solid #b5594d;border-radius:14px;background:#fff4f1;color:#762e25;font:600 14px/1.5 Arial,sans-serif;box-shadow:0 4px 18px #182f3633}
 #gl-content-notice[hidden]{display:none!important}
 #gl-content-cover{position:fixed;inset:0;box-sizing:border-box;width:100vw;height:100dvh;max-width:none;max-height:none;margin:0;padding:32px;border:0;background:#e2eaed;color:#173b39;text-align:center;outline:0}
 #gl-content-cover[open]{display:grid;place-items:center}
 #gl-content-cover::backdrop{background:#e2eaed}
 #gl-content-cover>div{max-width:570px}#gl-content-cover span{font-size:48px}#gl-content-cover h2{font:750 26px/1.3 Arial,sans-serif}#gl-content-cover p{font:16px/1.6 Arial,sans-serif}
 @media print{#gl-content-notice,#gl-content-cover{display:none!important}}
 `;document.head.append(style);
 window.addEventListener('keydown',e=>{if(!e.isTrusted||!allowed()||e.repeat)return;const capture=captureAction(e);if(capture){restrict(e,capture,true);return;}if(editable(e.target)||editable(document.activeElement))return;if((e.ctrlKey||e.metaKey)&&!e.altKey&&!e.shiftKey){const key=e.key.toLowerCase();if(key==='a')restrict(e,'select_all');else if(key==='c')restrict(e,'copy');else if(key==='x')restrict(e,'cut');}},options);
 window.addEventListener('keyup',e=>{const capture=captureAction(e);if(capture)restrict(e,capture,true);},options);
 for(const type of ['copy','cut','selectstart'])window.addEventListener(type,e=>{if(!editable(e.target)&&!editable(document.activeElement))restrict(e,type==='selectstart'?'text_select':type);},options);
 window.addEventListener('pointerdown',e=>{drag=null;if(!e.isTrusted||!allowed()||e.button!==0||e.pointerType==='touch'||!textAt(e))return;drag={id:e.pointerId,x:e.clientX,y:e.clientY};},options);
 window.addEventListener('pointermove',e=>{if(!e.isTrusted||!allowed()||!drag||e.pointerId!==drag.id||!(e.buttons&1))return;if(Math.hypot(e.clientX-drag.x,e.clientY-drag.y)>=10){drag=null;inform('Text selection is restricted on this page.');report('text_drag');}},options);
 for(const name of ['pointerup','pointercancel'])window.addEventListener(name,()=>{drag=null;},options);
 window.addEventListener('dblclick',e=>{if(e.isTrusted&&allowed()&&textAt(e))restrict(e,'text_select');},options);
 window.addEventListener('online',()=>void flush(),{signal:abort.signal});
 window.addEventListener('pagehide',()=>{active=false;queue=[];drag=null;clearTimeout(retryTimer);clearTimeout(coverTimer);clearTimeout(noticeTimer);cover?.close();if(notice)notice.hidden=true;document.documentElement.classList.remove('gl-content-protected');},{signal:abort.signal});
 window.addEventListener('pageshow',e=>{if(e.persisted&&!stopped)(async()=>{const r=await client().auth.getSession();if(stopped)return;if(r.error||r.data?.session?.user?.id!==actor){stop();return;}if(pageKey()===page&&window.GREENLOOP_CAN?.('view',page)){active=true;document.documentElement.classList.add('gl-content-protected');}})().catch(()=>stop());},{signal:abort.signal});
 for(const name of ['greenloop:signed-out','greenloop:office-locked'])window.addEventListener(name,stop,{signal:abort.signal});
 window.addEventListener('greenloop:permissions-changed',()=>{if(active&&!window.GREENLOOP_CAN?.('view',page))stop();},{signal:abort.signal});
 window.GREENLOOP_CONTENT_PROTECTION=Object.freeze({version,get enabled(){return active&&!stopped;}});
 (async()=>{await window.GREENLOOP_ACCESS_READY;if(stopped)return;page=pageKey();if(!page||!window.GREENLOOP_CAN?.('view',page))return;const r=await client().auth.getSession();if(stopped||r.error||!r.data?.session?.user?.id)return;actor=r.data.session.user.id;active=true;document.documentElement.classList.add('gl-content-protected');
  subscription=client().auth.onAuthStateChange?.((event,session)=>{if(event==='SIGNED_OUT'||session?.user?.id&&session.user.id!==actor)stop();})?.data?.subscription;
 })().catch(()=>{});
})();
