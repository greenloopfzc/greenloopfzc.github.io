(() => {
  'use strict';
  async function initialize(){
    await window.GREENLOOP_ACCESS_READY;
    if(window.GREENLOOP_PAGE_ACCESS?.pageKey!=='lab_glass')return;
    const host=document.getElementById('lab-bulk-host');if(!host||!host.isConnected)return;
    host.hidden=false;window.GREENLOOP_LAB_BULK.mount(host,{standalone:true});
    const menu=open=>{document.getElementById('sidebar')?.classList.toggle('is-open',open);document.getElementById('menu-backdrop').hidden=!open;document.body.classList.toggle('menu-open',open);};
    document.getElementById('open-menu')?.addEventListener('click',()=>menu(true));
    document.getElementById('close-menu')?.addEventListener('click',()=>menu(false));
    document.getElementById('menu-backdrop')?.addEventListener('click',()=>menu(false));
  }
  initialize().catch(error=>{const message=document.getElementById('permission-message');if(message){message.textContent=error.message||'Bulk Lab transfer could not be opened. Refresh to retry.';message.hidden=false;}});
})();
