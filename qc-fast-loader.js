/* One confirmed QC snapshot per scan; bounded batches for explicit trays. */
(function(root){
  'use strict';
  const pageRpcs={initial_qc:'get_initial_qc_fast_rows_v1',final_qc:'receive_final_qc_fast_rows_v1',qc_issuance:'get_qc_issuance_rows_v1'};
  let live=true,epoch=0;
  const queues=new Map();
  const permitted=page=>live&&root.GREENLOOP_PAGE_ACCESS?.pageKey===page&&root.GREENLOOP_CAN?.(page==='final_qc'?'entry':'view',page)===true;
  function invalidate(stop=false){epoch++;if(stop)live=false;for(const q of queues.values())pump(q);}
  root.addEventListener('pagehide',()=>invalidate(true));
  root.addEventListener('greenloop:office-locked',()=>invalidate(true));
  root.addEventListener('greenloop:signed-out',()=>invalidate(true));
  root.addEventListener('greenloop:permissions-changed',()=>invalidate());
  function valid(waiter){return waiter.epoch===epoch&&permitted(waiter.page)&&waiter.active();}
  function settle(q,entry,value,error){
    if(q.entries.get(entry.imei)===entry)q.entries.delete(entry.imei);
    for(const waiter of entry.waiters){if(!valid(waiter))waiter.resolve(null);else if(error){waiter.cancel();waiter.reject(error);}else waiter.resolve(value);}
  }
  function checkRows(page,group,data){
    if(page==='qc_issuance'){
      if(!data||!Array.isArray(data.rows)||!Number.isSafeInteger(data.total)||data.rows.length>group.length)throw Error('Saved inspection response needs checking. Reload before continuing.');
      const checked=new Map();
      for(const row of data.rows){if(!group.includes(row?.imei)||checked.has(row.imei)||!row.job_id||!row.inspection_id)throw Error('Saved inspection response needs checking. Reload before continuing.');checked.set(row.imei,{imei:row.imei,ok:true,item:row});}
      return new Map(group.map(imei=>[imei,checked.get(imei)||{imei,ok:false}]));
    }
    if(!Array.isArray(data)||data.length!==group.length)throw Error('QC scan response needs checking. Scan the phone again.');
    const checked=new Map();
    for(const row of data){
      if(!group.includes(row?.imei)||checked.has(row.imei)||typeof row.ok!=='boolean'||row.ok&&(!row.item||page==='initial_qc'&&(row.item.found!==true||row.item.device?.imei_1!==row.imei)||page==='final_qc'&&row.item.work_order?.job?.device?.imei_1!==row.imei))throw Error('QC scan response needs checking. Scan the phone again.');
      checked.set(row.imei,row);
    }
    return checked;
  }
  function pump(q){
    while(q.running<(q.page==='final_qc'?1:2)&&q.pending.length){
      const batch=[];
      while(q.pending.length&&batch.length<100){const entry=q.pending.shift();if(entry.waiters.some(valid))batch.push(entry);else settle(q,entry,null);}
      if(!batch.length)continue;
      q.running++;
      void (async()=>{
        try{
          const group=batch.map(e=>e.imei);
          // Final QC receives are serialized and are never replayed after an error.
          const args=q.page==='qc_issuance'?{p_imeis:group,p_limit:100}:{p_imeis:group};
          const {data,error}=await root.GREENLOOP_GET_CLIENT().rpc(pageRpcs[q.page],args);
          if(error)throw error;
          const checked=checkRows(q.page,group,data);
          for(const entry of batch)settle(q,entry,checked.get(entry.imei));
        }catch(error){for(const entry of batch)settle(q,entry,null,error);}
        finally{q.running--;pump(q);}
      })();
    }
  }
  async function load(page,values,active=()=>true){
    if(!pageRpcs[page])throw Error('Unknown QC page.');
    if(!permitted(page))throw Error('This action is not allowed for your account.');
    const imeis=[...new Set(values.filter(v=>/^\d{15}$/.test(v)))];
    let q=queues.get(page);if(!q){q={page,pending:[],entries:new Map(),running:0,timer:null};queues.set(page,q);}
    const state={cancelled:false};
    const promises=imeis.map(imei=>new Promise((resolve,reject)=>{
      let entry=q.entries.get(imei);
      if(!entry||entry.epoch!==epoch){entry={imei,epoch,waiters:[]};q.entries.set(imei,entry);q.pending.push(entry);}
      entry.waiters.push({page,epoch,active:()=>!state.cancelled&&active(),cancel:()=>{state.cancelled=true;},resolve,reject});
    }));
    // Coalesce scans from the same frame; retain only in-flight data, never a
    // completed snapshot that could bypass a new authoritative stage check.
    if(!q.timer)q.timer=setTimeout(()=>{q.timer=null;pump(q);},12);
    const results=await Promise.all(promises),rows=new Map();
    results.forEach((row,i)=>{if(row)rows.set(imeis[i],row);});return rows;
  }
  async function saveRows(app,rows,work){
    const page=root.GREENLOOP_PAGE_ACCESS?.pageKey,controls=new Map([...app.querySelectorAll('input,select,textarea,button')].map(c=>[c,c.disabled]));
    controls.forEach((_,c)=>c.disabled=true);
    let next=0;const results=new Array(rows.length);
    try{
      await Promise.all(Array.from({length:Math.min(3,rows.length)},async()=>{
        while(next<rows.length){const index=next++,row=rows[index];
          if(!live||root.GREENLOOP_PAGE_ACCESS?.pageKey!==page||!root.GREENLOOP_CAN?.('entry',page)){results[index]={ok:false,error:'This action is not allowed for your account.'};continue;}
          // Restore only this row immediately before its normal save routine
          // snapshots the values and locks it. Queued rows remain untouched.
          row.querySelectorAll('input,select,textarea,button').forEach(c=>c.disabled=controls.get(c)??true);
          try{results[index]=await work(row,index);}catch(e){results[index]={ok:false,error:e.message||'Could not save this phone.'};}
          row.querySelectorAll('input,select,textarea,button').forEach(c=>c.disabled=true);
        }
      }));
      return results;
    }finally{
      const allowed=live&&root.GREENLOOP_PAGE_ACCESS?.pageKey===page&&root.GREENLOOP_CAN?.('entry',page);
      controls.forEach((disabled,c)=>{if(c.isConnected)c.disabled=disabled||!allowed||c.closest('tr')?.dataset.completed==='yes';});
      root.GREENLOOP_LOCK_VIEW_ONLY_CONTROLS?.(app);
    }
  }
  root.GREENLOOP_QC_FAST={load,saveRows};
})(window);
