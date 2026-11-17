/* Scanner focus is local to the current empty field and authorized page. */
(function(root){
  'use strict';
  let live=true,epoch=0;
  const versions=new WeakMap(),scanner='.qc-bulk-imei,.final-row-imei,.qc-issuance-imei,#imei-query';
  document.addEventListener('input',event=>{if(event.target.matches?.(scanner))versions.set(event.target,(versions.get(event.target)||0)+1);},true);
  for(const event of ['pagehide','greenloop:office-locked','greenloop:signed-out'])root.addEventListener(event,()=>{live=false;epoch++;});
  root.addEventListener('greenloop:permissions-changed',()=>{epoch++;});
  function available(input,allowed){return live&&input?.isConnected&&!input.disabled&&!input.closest('[hidden]')&&allowed()&&!input.closest('tr[data-completed="yes"],tr[data-saving="yes"]');}
  function focus(input,allowed=()=>true){
    if(!available(input,allowed)||document.querySelector('dialog[open]'))return;
    const active=document.activeElement;
    // Do not interrupt a deliberate grade/technician edit or a newer scan.
    if(active&&active!==input&&active!==document.body&&active!==document.documentElement&&!active.closest('dialog')&&!(active.matches(scanner)&&!active.value.trim()))return;
    input.focus();
  }
  async function notice({input,imei,reset,isCurrent=()=>true,allowed=()=>true,...details}){
    if(!available(input,allowed)||!isCurrent())return false;
    if(reset){if(input.value.trim()!==imei)return false;reset();input.value='';}
    const version=versions.get(input)||0,stamp=epoch,row=input.closest('tr'),load=row?.dataset.loadVersion,ticket=row?.dataset.ticket;
    const valid=()=>stamp===epoch&&available(input,allowed)&&!input.value.trim()&&(versions.get(input)||0)===version&&(!row||row.dataset.loadVersion===load&&row.dataset.ticket===ticket);
    const shown=await root.GREENLOOP_IMEI_STAGE_NOTICE.show({...details,imei,isCurrent:valid,onClose:()=>{if(valid())focus(input,allowed);}});
    if(!shown&&valid())focus(input,allowed);
    return shown;
  }
  root.GREENLOOP_SCAN_READY={focus,notice};
})(window);
