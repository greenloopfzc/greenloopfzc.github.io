/* One confirmed QC snapshot per scan; bounded batches for explicit trays. */
(function(root){
  'use strict';
  const pageRpcs={initial_qc:'get_initial_qc_fast_rows_v1',final_qc:'receive_final_qc_fast_rows_v1'};
  let live=true;
  root.addEventListener('pagehide',()=>{live=false;});
  root.addEventListener('greenloop:office-locked',()=>{live=false;});
  async function load(page,values,active=()=>true){
    const rpc=pageRpcs[page];if(!rpc)throw Error('Unknown QC page.');
    const imeis=[...new Set(values.filter(v=>/^\d{15}$/.test(v)))],rows=new Map();
    for(let offset=0;offset<imeis.length;offset+=100){
      if(!live||!active())break;
      if(root.GREENLOOP_PAGE_ACCESS?.pageKey!==page||!root.GREENLOOP_CAN?.(page==='final_qc'?'entry':'view',page))throw Error('This action is not allowed for your account.');
      const group=imeis.slice(offset,offset+100);
      // Never replay a receive or Save after a network error.
      const {data,error}=await root.GREENLOOP_GET_CLIENT().rpc(rpc,{p_imeis:group});
      if(error)throw error;
      if(!live||!active()||root.GREENLOOP_PAGE_ACCESS?.pageKey!==page||!root.GREENLOOP_CAN?.(page==='final_qc'?'entry':'view',page))break;
      if(!Array.isArray(data)||data.length!==group.length)throw Error('QC scan response needs checking. Scan the phone again.');
      const checked=new Map();
      for(const row of data){
        if(!group.includes(row?.imei)||checked.has(row.imei)||typeof row.ok!=='boolean'||row.ok&&(!row.item||page==='initial_qc'&&(row.item.found!==true||row.item.device?.imei_1!==row.imei)||page==='final_qc'&&row.item.work_order?.job?.device?.imei_1!==row.imei))throw Error('QC scan response needs checking. Scan the phone again.');
        checked.set(row.imei,row);
      }
      for(const [imei,row]of checked)rows.set(imei,row);
    }
    return rows;
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
