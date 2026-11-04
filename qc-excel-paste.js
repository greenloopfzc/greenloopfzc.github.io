/* Excel IMEI columns fill QC tray lines without completing inspections. */
(function(root) {
  'use strict';
  const digits=s=>s.replace(/[\u0660-\u0669\u06f0-\u06f9]/g,c=>String(c.charCodeAt(0)-(c.charCodeAt(0)>=0x6f0?0x6f0:0x660)));
  function clean(value) {
    let s=digits(String(value).replace(/^\uFEFF/,'').trim());
    if(s.startsWith('"')&&s.endsWith('"'))s=s.slice(1,-1).trim();
    if(s.startsWith("'"))s=s.slice(1).trim();
    return s;
  }
  function parse(text) {
    const entries=[],issues=[];let headers=0,position=0;
    for(const cell of String(text??'').split(/[\r\n\t,;]+/)){
      const value=clean(cell);if(!value)continue;
      const words=value.split(/\s+/),items=words.length>1&&words.every(s=>/^\d{15}$/.test(s))?words:[value];
      for(const item of items){position++;
        if(!entries.length&&!issues.length&&/^(?:IMEI(?:\s*1)?|IMEI\s*(?:NO\.?|NUMBER))$/i.test(item)){headers++;continue;}
        const entry={value:item,position};
        if(/^\d{15}$/.test(item))entries.push(entry);
        else issues.push({...entry,message:/[eE][+-]?\d|\.\d/.test(item)?'Excel changed this number. Format the IMEI column as Text and copy its full 15 digits.':'Enter an exact 15-digit IMEI. This value was not imported.'});
      }
    }
    return{entries,issues,headers,total:entries.length+issues.length};
  }
  function attach(options) {
    const {app,tableBody,selector,page,createRows,clearRow,loadRow,prepare,onUnlock}=options;
    const permitted=()=>root.GREENLOOP_PAGE_ACCESS?.pageKey===page&&root.GREENLOOP_CAN?.('entry',page)===true;
    let current=null,stopped=false;
    const region=document.createElement('section');region.className='qc-excel-paste-status';region.hidden=true;
    region.setAttribute('aria-label','Excel IMEI paste result');
    const status=document.createElement('p');status.setAttribute('role','status');status.setAttribute('aria-live','polite');
    const stop=document.createElement('button');stop.type='button';stop.className='secondary-button';stop.textContent='Stop loading';stop.dataset.capability='entry';stop.dataset.capabilityPage=page;
    const details=document.createElement('details'),summary=document.createElement('summary'),list=document.createElement('ul');summary.textContent='Check these IMEIs';details.append(summary,list);region.append(status,stop,details);
    const toolbar=app.querySelector('.qc-bulk-toolbar,.final-bulk-toolbar');toolbar.after(region);
    function rowState(row,text,error=true){const e=row.querySelector('[data-row-state]');e.textContent=text;e.hidden=!text;e.className=error?'is-error':'is-loading';row.classList.toggle('is-error',error);}
    function issue(item){const li=document.createElement('li'),label=document.createElement('span');label.textContent=`${item.value.slice(0,100)}${item.value.length>100?'…':''} — ${item.message}`;li.append(label);
      if(item.record?.found&&item.record.current_stage){const button=document.createElement('button');button.type='button';button.className='secondary-button';button.textContent='Show current location';button.dataset.capability='view';button.dataset.capabilityPage=page;button.addEventListener('click',()=>{if(root.GREENLOOP_CAN?.('view',page))void root.GREENLOOP_IMEI_STAGE_NOTICE.show({imei:item.value,knownRecord:item.record,title:'Phone unavailable here',message:item.message});});li.append(button);}list.append(li);
    }
    function update(job,finished=false){if(!job.live||stopped)return;if(!permitted()){region.hidden=true;return;}
      status.textContent=finished?`${job.total} pasted · ${job.loaded} loaded · ${job.issues.length} need checking${job.unloaded?' · '+job.unloaded+' not loaded':''}${job.cancel?' · Stopped':''}`:`Loading ${job.settled} of ${job.rows.length} IMEIs… ${job.loaded} loaded`;
      if(job.headers&&finished)status.textContent+=` · ${job.headers} column heading ignored`;
      region.dataset.state=finished?(job.issues.length||job.unloaded?'review':'success'):'loading';stop.hidden=finished;stop.disabled=job.cancel;
      if(finished){list.replaceChildren();job.issues.forEach(issue);details.hidden=!job.issues.length;summary.textContent=`Check ${job.issues.length} IMEI${job.issues.length===1?'':'s'}`;}
    }
    function lock(job){for(const e of app.querySelectorAll('input,select,textarea,button'))if(!region.contains(e)){job.controls.set(e,e.disabled);e.disabled=true;}}
    function unlock(job){for(const [e,disabled]of job.controls)if(e.isConnected)e.disabled=disabled||stopped||!job.live||!permitted();if(!stopped&&job.live&&permitted())onUnlock?.();root.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(app);}
    async function run(input,parsed) {
      const job={...parsed,issues:[...parsed.issues],loaded:0,settled:0,unloaded:0,cancel:false,live:true,rows:[],controls:new Map()};current=job;
      region.hidden=false;details.hidden=true;details.open=false;list.replaceChildren();stop.hidden=false;stop.disabled=false;
      const active=()=>current===job&&job.live&&!stopped&&permitted()&&tableBody.isConnected;
      const occupied=new Set([...tableBody.querySelectorAll(selector)].map(e=>e.value.trim()).filter(Boolean));
      const accepted=[];
      for(const item of parsed.entries){if(occupied.has(item.value))job.issues.push({...item,message:'Duplicate IMEI: already in this tray or this pasted list.'});else{occupied.add(item.value);accepted.push(item);}}
      let start=[...tableBody.rows].indexOf(input.closest('tr'));
      let blanks=[...tableBody.rows].slice(Math.max(start,0)).filter(r=>{const e=r.querySelector(selector);return !e.value.trim()&&!e.disabled&&r.dataset.completed!=='yes'&&r.dataset.saving!=='yes'&&r.dataset.loading!=='yes';});
      if(accepted.length>blanks.length){createRows(accepted.length-blanks.length);blanks=[...tableBody.rows].slice(Math.max(start,0)).filter(r=>{const e=r.querySelector(selector);return !e.value.trim()&&!e.disabled&&r.dataset.completed!=='yes'&&r.dataset.saving!=='yes'&&r.dataset.loading!=='yes';});}
      for(let i=0;i<accepted.length;i++){const row=blanks[i];if(!row){job.issues.push({...accepted[i],message:'This row could not be prepared. Paste again into an empty IMEI line.'});continue;}clearRow(row);row.querySelector(selector).value=accepted[i].value;rowState(row,'Waiting to load…',false);job.rows.push({...accepted[i],row,started:false});}
      lock(job);update(job);
      try{
        if(job.rows.length&&active())await prepare?.(job.rows.map(r=>r.value));
        let next=0;
        async function worker(){while(next<job.rows.length&&!job.cancel&&active()){
          const item=job.rows[next++];item.started=true;
          try{const result=await loadRow(item.row,{bulk:true,isCurrent:active});if(!active())return;
            if(result?.loaded)job.loaded++;else job.issues.push({...item,message:result?.message||'This phone could not be loaded. Press Enter on its row to retry.',record:result?.record});
          }catch(error){if(active()){const message=error.message||'Could not load this phone. Press Enter on its row to retry.';rowState(item.row,message);job.issues.push({...item,message});}}
          job.settled++;update(job);
        }}
        await Promise.all(Array.from({length:Math.min(4,job.rows.length)},worker));
      }catch(error){for(const item of job.rows.filter(r=>!r.started)){rowState(item.row,error.message||'Queue could not load. Press Enter to retry.');job.issues.push({...item,message:error.message||'Queue could not load. Press Enter to retry.'});item.started=true;}}
      finally{
        for(const item of job.rows.filter(r=>!r.started)){job.unloaded++;rowState(item.row,'Not loaded — paste stopped. Press Enter to retry.');}
        unlock(job);update(job,true);if(current===job)current=null;
      }
    }
    stop.addEventListener('click',()=>{if(current){current.cancel=true;stop.disabled=true;status.textContent='Stopping after the phones already being checked…';}});
    root.addEventListener('paste',event=>{
      const input=event.target?.closest?.(selector);if(!input||!tableBody.contains(input))return;
      if(current||!permitted()||input.disabled||input.readOnly){event.preventDefault();event.stopImmediatePropagation();return;}
      const text=event.clipboardData?.getData('text/plain')||event.clipboardData?.getData('text')||'';
      if(!text.trim()||/^\d{15}$/.test(text.trim()))return; // Keep the existing single-phone scanner behavior.
      event.preventDefault();event.stopImmediatePropagation();
      if(tableBody.querySelector('tr[data-saving="yes"],tr[data-loading="yes"]')||app.querySelector('#auto-pick-pending:disabled')){region.hidden=false;status.textContent='Wait for the current QC operation to finish, then paste again.';details.hidden=true;stop.hidden=true;return;}
      void run(input,parse(text)).catch(error=>{if(current)unlock(current);region.dataset.state='review';status.textContent=error.message||'The pasted list could not load. Existing tray entries are preserved.';stop.hidden=true;current=null;});
    },true);
    function block(event){if(current&&app.contains(event.target)&&!region.contains(event.target)){event.preventDefault();event.stopImmediatePropagation();}}
    for(const type of ['click','input','change','keydown','submit'])root.addEventListener(type,block,true);
    root.addEventListener('greenloop:imei-scan',event=>{if(current){event.preventDefault();event.stopImmediatePropagation();}},true);
    function stopPage(){stopped=true;if(current){current.cancel=true;current.live=false;}region.hidden=true;}
    root.addEventListener('pagehide',stopPage);root.addEventListener('greenloop:office-locked',stopPage);
    options.client.auth.onAuthStateChange?.(event=>{if(event==='SIGNED_OUT')stopPage();});
    return{get busy(){return Boolean(current);},clear(){if(!current)region.hidden=true;}};
  }
  if(root)root.GREENLOOP_QC_EXCEL_PASTE={attach,parse};
  if(typeof module!=='undefined'&&module.exports)module.exports={parse};
})(typeof window!=='undefined'?window:null);
