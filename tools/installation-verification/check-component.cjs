'use strict';
const sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt='sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt';const ROOT='https://prypklagfznpdlleldll.supabase.co/rest/v1/rpc/';
async function probe(name,expected){
 const transientCodes=new Set(['57014','53300','53400','57P01','57P02','57P03','08000','08001','08003','08004','08006','08007','08P01']);
 for(let attempt=1;attempt<=3;attempt++){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);let outcome,retry=false;
  try{
   const r=await fetch(ROOT+'get_installation_component_version',{method:'POST',redirect:'error',headers:{apikey:sb_publishable_hMIRbfKmh4vhGvEgVcPjow_F21WmwXt,Accept:'application/json','Content-Type':'application/json'},body:JSON.stringify({p_name:name}),signal:controller.signal});
   const raw=await r.text();let body;try{body=JSON.parse(raw);}catch{body=null;}
   if(r.status===404&&body?.code==='PGRST202')return{ok:false,kind:'missing-engine',rpc:'get_installation_component_engine_version',message:'Component verification engine is not installed or schema reload is pending.'};
   if(!r.ok){
    const code=typeof body?.code==='string'?body.code:'';
    const detail=typeof body?.message==='string'?body.message.replace(/[\r\n\t]+/g,' ').slice(0,180):'';
    outcome={ok:false,kind:'http-error',rpc:name,httpStatus:r.status,code,attempts:attempt,message:'Database check failed: HTTP '+r.status+(code?' ['+code+']':'')+(detail?' - '+detail:'')};
    retry=r.status===429||[502,503,504].includes(r.status)||(r.status===500&&(!code||transientCodes.has(code)));
   }else{
    const result=body?.result;
    if(body?.engine_version!=='20261107-installation-components-1'||body?.target!==name||!result||result.rpc!==name||typeof result.ok!=='boolean')return{ok:false,kind:'invalid-response',rpc:name,message:'Component verification response could not be validated.'};
    if(result.ok&&result.kind==='verified'&&result.version===expected)return{ok:true,kind:'verified',rpc:name,version:expected,engine_version:body.engine_version};
    if(result.ok)return{ok:false,kind:'changed-marker',rpc:name,message:'Database version differs from the tested update.'};
    if(!['missing-marker','changed-marker','dependency-error','verification-error'].includes(result.kind))return{ok:false,kind:'invalid-response',rpc:name,message:'Unknown component verification result.'};
    return{...result,message:typeof result.message==='string'?result.message.replace(/[\r\n\t]+/g,' ').slice(0,500):'Database component could not be verified.'};
   }
  }catch{
   outcome={ok:false,kind:'network-error',rpc:name,attempts:attempt,message:'Cannot connect securely to the database after '+attempt+' attempt(s). Retry later.'};retry=true;
  }finally{clearTimeout(timer);}
  if(!retry||attempt===3)return outcome;
  await new Promise(resolve=>setTimeout(resolve,attempt*2000));
 }
}
module.exports={probe};
