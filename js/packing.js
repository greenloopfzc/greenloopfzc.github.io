(() => { "use strict";
  const config=window.GREENLOOP_CONFIG||{}; const app=document.querySelector("#packing-app"), pm=document.querySelector("#permission-message"), select=document.querySelector("#packing-job-select"), count=document.querySelector("#queue-count"), empty=document.querySelector("#packing-empty"), workspace=document.querySelector("#packing-workspace"), summary=document.querySelector("#packing-device-summary"), form=document.querySelector("#packing-form"), msg=document.querySelector("#packing-message"), start=document.querySelector("#start-packing"), complete=document.querySelector("#complete-packing"), title=document.querySelector("#packing-status-title"), text=document.querySelector("#packing-status-text"), side=document.querySelector("#sidebar"), back=document.querySelector("#menu-backdrop"), toast=document.querySelector("#toast"); let client,jobs=[],selected,record,timer; let selectionVersion=0, pending=false, recordLoading=false;
  const api=()=>client||(client=window.GREENLOOP_GET_CLIENT()); const esc=v=>String(v||"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[c]); const dev=j=>Array.isArray(j.device)?j.device[0]:j.device; const message=(t="",ok=false)=>{msg.textContent=t;msg.classList.toggle("is-visible",!!t);msg.classList.toggle("is-success",ok)}; const notify=t=>{clearTimeout(timer);toast.textContent=t;toast.hidden=false;toast.classList.add("is-visible");timer=setTimeout(()=>{toast.hidden=true;toast.classList.remove("is-visible")},3400)}; const busy=(b,on,label)=>{b.disabled=on;if(on)b.dataset.label=b.textContent.trim();b.textContent=on?label:b.dataset.label||b.textContent};
  function state(r){record=r||null;const started=!!(r?.started_at&&!r?.completed_at);start.hidden=started;complete.disabled=pending||recordLoading||!started;start.disabled=pending||recordLoading;title.textContent=started?"Packing in progress":"Ready to start";text.textContent=started?`Started ${new Date(r.started_at).toLocaleString()}. Complete after package details are confirmed.`:"Start packing to record the packer and automatic start time."}
  function show(){const version=++selectionVersion;recordLoading=true;state();selected=jobs.find(j=>j.id===select.value);workspace.hidden=!selected;form.reset();message();if(!selected){recordLoading=false;state();return}const d=dev(selected)||{}, details=[d.brand,d.model,d.original_grade?`Grade ${d.original_grade}`:""].filter(Boolean).join(" - ");summary.innerHTML=`<div><p class="panel-kicker">Selected device</p><h2>${esc(d.device_number||"Device")}</h2><p>${esc(details||"No model details recorded")}</p></div><dl><div><dt>Job</dt><dd>${esc(selected.job_number)}</dd></div><div><dt>IMEI</dt><dd>${esc(d.imei_1||"—")}</dd></div><div><dt>Status</dt><dd>Packing pending</dd></div></dl>`;api().from("packing_records").select("id,started_at,completed_at").eq("job_id",selected.id).maybeSingle().then(({data,error})=>{if(version!==selectionVersion)return;recordLoading=false;if(error){message(error.message);state();start.disabled=true;return}state(data)}).catch(error=>{if(version!==selectionVersion)return;recordLoading=false;message(error.message||"Packing details could not be loaded.");state();start.disabled=true})}
  async function load(){const keep=select.value,{data,error}=await api().from("jobs").select("id,job_number,device:devices(device_number,imei_1,brand,model,original_grade)").eq("current_status","ready_for_packing").is("deleted_at",null).order("received_at",{ascending:true});if(error)throw error;jobs=data||[];count.textContent=`${jobs.length} waiting`;select.replaceChildren(new Option(jobs.length?"Select a Packing device":"No Packing jobs waiting", ""));jobs.forEach(j=>{const d=dev(j)||{};select.add(new Option(`${j.job_number} - ${d.device_number||"Device"} - ${d.brand||"Unknown"} ${d.model||""}`.trim(),j.id))});empty.hidden=!!jobs.length;if(keep&&jobs.some(j=>j.id===keep)){select.value=keep;show()}else{select.value="";selected=undefined;workspace.hidden=true;message();state()}}
  async function begin(){
    if(!selected||pending||recordLoading||start.disabled)return;
    const jobId=selected.id, version=selectionVersion;
    pending=true;select.disabled=true;busy(start,true,"Starting...");
    try {
      const {data,error}=await api().rpc("start_packing",{p_job_id:jobId});
      if(error)throw error;
      if(version===selectionVersion&&selected?.id===jobId){const result=Array.isArray(data)?data[0]:data;state({started_at:result?.started_at})}
      notify("Packing started.");
    } catch(error){message(error.message||"Packing could not be started.")}
    finally{pending=false;select.disabled=false;busy(start,false);state(record)}
  }
  async function finish(e){
    e.preventDefault();
    if(!selected||pending||recordLoading||!record?.started_at||record.completed_at)return;
    if(!form.reportValidity())return;
    const jobId=selected.id;
    pending=true;select.disabled=true;busy(complete,true,"Completing...");
    try {
      const {error}=await api().rpc("complete_packing",{p_job_id:jobId,p_package_reference:document.querySelector("#package-reference").value,p_accessories:document.querySelector("#package-accessories").value,p_notes:document.querySelector("#packing-notes").value});
      if(error)throw error;
      record=null;state();
      notify("Packing completed. Device is ready for Stock Out.");
      try{await load()}catch(error){workspace.hidden=true;message("Packing was saved, but the queue could not refresh. Refresh the queue before continuing.")}
    } catch(error){message(error.message||"Packing could not be completed.")}
    finally{pending=false;select.disabled=false;busy(complete,false);state(record)}
  }

  async function init(){if(!config.supabaseUrl||!config.supabaseAnonKey||!window.supabase){pm.textContent="Supabase authentication is not configured.";pm.hidden=false;return}const{data:s}=await api().auth.getSession();if(!s.session){location.replace("index.html");return}const{data:yes,error}=await api().rpc("has_role",{required_roles:["super_admin","owner","manager","packing"]});if(error)throw error;if(!yes){pm.textContent="Your account does not have Packing permission.";pm.hidden=false;return}app.hidden=false;await load()}
  document.querySelector("#open-menu").onclick=()=>{side.classList.add("is-open");back.hidden=false};document.querySelector("#close-menu").onclick=()=>{side.classList.remove("is-open");back.hidden=true};back.onclick=()=>{side.classList.remove("is-open");back.hidden=true};document.querySelectorAll(".module-link").forEach(b=>b.onclick=()=>notify(`${b.dataset.module} will be added in the next workflow steps.`));document.querySelector("#refresh-queue").onclick=()=>load().catch(e=>notify(e.message));select.onchange=show;start.onclick=begin;form.onsubmit=finish;init().catch(e=>{pm.textContent=e.message||"Packing could not be loaded.";pm.hidden=false});
})();
