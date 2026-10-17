(() => {
  'use strict';
  if(window.GREENLOOP_SUSPICIOUS_BADGE)return;window.GREENLOOP_SUSPICIOUS_BADGE=true;
  let busy=false,timer=null;
  function display(data){const link=document.querySelector('.sidebar-nav a[href="suspicious-activity.html"]');if(!link)return;let badge=link.querySelector('.sa-alert-count');if(!badge){badge=document.createElement('span');badge.className='nav-count sa-alert-count';badge.style.cssText='margin-left:auto;min-width:21px;height:21px;border-radius:50%;background:#b65343;color:white;text-align:center;font-size:11px;font-weight:800;line-height:21px;box-shadow:0 2px 5px #75453644';link.append(badge);}badge.textContent=data.new>99?'99+':String(data.new);badge.hidden=!data.new;badge.setAttribute('aria-label',`${data.new} unreviewed activity alerts`);}
  async function refresh(){if(busy||document.hidden||!window.GREENLOOP_CAN?.('view','suspicious_activity'))return;busy=true;try{const r=await window.GREENLOOP_GET_CLIENT().rpc('get_suspicious_summary_v1');if(!r.error&&r.data){display(r.data);window.dispatchEvent(new CustomEvent('greenloop:suspicious-summary',{detail:r.data}));}}catch{}finally{busy=false;}}
  window.addEventListener('greenloop:suspicious-summary',e=>display(e.detail));
  window.addEventListener('greenloop:workflow-committed',refresh);
  window.addEventListener('focus',refresh);document.addEventListener('visibilitychange',refresh);
  window.addEventListener('storage',e=>{if(e.key==='greenloop-workflow-commit-v1')refresh();});
  const start=()=>{if(!window.GREENLOOP_CAN?.('view','suspicious_activity'))return;if(!timer)timer=setInterval(refresh,15000);refresh();};
  window.addEventListener('pagehide',()=>{clearInterval(timer);timer=null;});
  window.addEventListener('pageshow',start);
  (async()=>{await window.GREENLOOP_ACCESS_READY;start();})();
})();
