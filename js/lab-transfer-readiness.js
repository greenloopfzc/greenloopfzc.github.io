/* One fresh protected readiness preview; never a completed phone-state cache. */
(() => {
  'use strict';
  const version='20261118-lab-transfer-readiness-1',labStates=['laboratory_pending','laboratory_in_progress','glass_pending','glass_in_progress'];
  let dialog,finish,stamp=0,opened=0;
  const allowed=()=>window.GREENLOOP_PAGE_ACCESS?.pageKey==='lab_glass'&&window.GREENLOOP_CAN?.('view','lab_glass')===true;
  const stage=value=>String(value||'Not verified').replace(/â€”|â€“|—|–/g,' - ').replace(/Frame Department/gi,'B-DEPT').replace(/^Shop stock$/i,'Chaman Shop').replace(/^Chaman transfer.*awaiting Greenloop receiving$/i,'Chaman status not verified');
  function shortReason(value){
    const text=String(value||'Check failed. Retry.'),labels=[];
    if(/Chaman transfer|outside Greenloop|receive.*back at Greenloop/i.test(text))return 'Phone is outside Greenloop';
    if(/services?/i.test(text))labels.push('Services pending');
    if(/parts? return.*(?:review|pending)|return.*waiting.*review/i.test(text))labels.push('Part return pending');
    if(/required parts|parts.*(?:not.*issued|awaiting|fully issue)|parts department/i.test(text))labels.push('Parts pending');
    if(labels.length)return labels.join(' / ');
    if(/already in.*(?:transfer )?list|already prepared/i.test(text))return 'Already in list';
    if(/duplicate/i.test(text))return 'Duplicate IMEI';
    if(/(?:IMEI|phone).*not.*found|not found.*(?:stock|software)/i.test(text))return 'IMEI not found';
    if(/not found/i.test(text))return 'Record not found';
    if(/15-digit|invalid IMEI/i.test(text))return 'Invalid IMEI';
    if(/multiple active|multiple.*work lines/i.test(text))return 'Multiple work lines';
    if(/no active.*(?:Lab|Glass).*work/i.test(text))return 'No active Lab work';
    if(/no active.*job/i.test(text))return 'No active job';
    if(/not currently in Lab|not in the current Lab|not.*Lab.*queue/i.test(text))return 'Not in Lab & Glass';
    if(/assignment changed|phone changed/i.test(text))return 'Phone changed. Recheck.';
    if(/save or (?:cancel|discard)|unsaved|changed Lab work/i.test(text))return 'Save or cancel your changes first';
    if(/install.*update|readiness.*update/i.test(text))return 'Update required. Refresh after updating.';
    if(/office|network.*access/i.test(text))return 'Office access required';
    if(/permission|access is required|not allowed/i.test(text))return 'Access required';
    if(/not.*verified|could not.*check|incomplete|timeout|timed out|fetch|connection/i.test(text))return 'Check failed. Retry.';
    return text.length>100?'Check failed. Refresh and retry.':text;
  }
  function valid(p){return p&&typeof p.device_id==='string'&&/^\d{15}$/.test(p.imei)&&typeof p.ready==='boolean'&&Array.isArray(p.reasons)&&p.reasons.every(s=>typeof s==='string'&&s.trim())&&typeof p.selection_token==='string'&&p.selection_token&&p.readiness_version===version&&typeof p.current_stage==='string'&&p.current_stage.trim()&&(!p.ready||typeof p.step_id==='string'&&p.step_id&&labStates.includes(p.status)&&!p.reasons.length)&&(!p.ready?p.reasons.length>0:true);}
  async function check(imei,isCurrent=()=>true){
    if(!allowed()||window.GREENLOOP_CAN?.('entry','lab_glass')!==true)throw Error('Lab Job Completed access is required.');
    let timer;try{
      const result=await Promise.race([window.GREENLOOP_GET_CLIENT().rpc('lookup_lab_bulk_phone_v1',{p_imei:imei}),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Phone readiness could not be checked. Scan again to retry.')),12000);})]);
      if(!isCurrent()||!allowed())return null;
      if(result.error)throw result.error;
      if(!valid(result.data))throw Error('Phone readiness could not be verified. Install the Lab transfer readiness update, then refresh and retry.');
      return result.data;
    }finally{clearTimeout(timer);}
  }
  function issue(phone,imei){
    const custody={out_pending:['Chaman receiving pending','Chaman receiving pending'],shop:['At Chaman Shop','Chaman Shop'],return_pending:['GL receiving pending','GL receiving pending']}[phone.chaman_phase];
    if(custody)return{imei:phone.imei||imei,reason:custody[0],stage:custody[1]};
    return{imei:phone.imei||imei,stage:stage(phone.current_stage),reason:shortReason([...new Set(phone.reasons)].join(' '))};
  }
  const errorIssue=(imei,error)=>({imei,stage:/not found/i.test(error?.message||'')?'Not found in software':'Not verified',reason:error?.message||'Phone readiness could not be checked. Scan again to retry.'});
  function dismiss(){stamp++;const done=finish;finish=null;if(dialog?.open)dialog.close();if(dialog)dialog.querySelector('tbody').replaceChildren();done?.(false);}
  async function show(issues,{input,isCurrent=()=>true,title='Cannot transfer to Final QC',summary}={}){
    if(!issues.length||!allowed()||!isCurrent())return false;
    window.GREENLOOP_IMEI_STAGE_NOTICE?.dismiss?.();
    dismiss();const ticket=stamp;
    if(!dialog){
      dialog=document.createElement('dialog');dialog.className='lab-transfer-notice';dialog.setAttribute('aria-labelledby','lab-transfer-notice-title');
      dialog.innerHTML='<div class="lab-transfer-notice-heading"><span aria-hidden="true">!</span><h2 id="lab-transfer-notice-title"></h2></div><p data-transfer-notice-summary></p><div class="lab-transfer-notice-scroll"><table data-preserve-table-layout><thead><tr><th>S.No</th><th>IMEI</th><th>Reason</th><th>Current stage</th></tr></thead><tbody></tbody></table></div><div class="lab-transfer-notice-actions"><button type="button" class="primary-button" data-transfer-notice-ok data-capability="view" data-capability-page="lab_glass">OK</button></div>';
      document.body.append(dialog);
      const close=()=>{const done=finish;finish=null;if(dialog.open)dialog.close();done?.(true);};
      dialog.querySelector('[data-transfer-notice-ok]').addEventListener('click',close);
      dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
      dialog.addEventListener('keydown',event=>{if(event.key==='Enter'&&performance.now()-opened<180){event.preventDefault();event.stopImmediatePropagation();}});
    }
    dialog.querySelector('h2').textContent=title;
    const summaryNode=dialog.querySelector('[data-transfer-notice-summary]');summaryNode.textContent=summary??(issues.length>1?`${issues.length} phones need attention.`:'');summaryNode.hidden=!summaryNode.textContent;
    for(const [i,item]of issues.entries()){
      const row=document.createElement('tr');for(const value of [i+1,item.imei,shortReason(item.reason),stage(item.stage)]){const cell=document.createElement('td');cell.textContent=String(value??'');row.append(cell);}dialog.querySelector('tbody').append(row);
    }
    opened=performance.now();const closed=new Promise(resolve=>finish=resolve);dialog.showModal();dialog.querySelector('[data-transfer-notice-ok]').focus();
    const accepted=await closed;
    if(accepted&&ticket===stamp&&allowed()&&isCurrent()&&input?.isConnected&&!input.disabled&&!input.readOnly&&!input.closest('[hidden]'))input.focus({preventScroll:true});
    return accepted;
  }
  for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed','pagehide'])window.addEventListener(event,dismiss);
  window.GREENLOOP_LAB_TRANSFER={check,valid,issue,errorIssue,show,dismiss,stage};
})();
