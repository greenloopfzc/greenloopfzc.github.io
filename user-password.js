(() => {
 'use strict';
 const $=id=>document.getElementById(id),box=$('user-password'),dialog=$('password-change-dialog');if(!box||!dialog)return;
 const stored=$('access-stored-password'),show=$('show-user-password'),change=$('change-user-password'),help=$('user-password-help'),message=$('user-password-message'),form=$('password-change-form'),password=$('change-password'),confirm=$('change-confirm-password'),submit=$('save-user-password'),check=$('check-password-status'),note=$('password-change-message'),toggle=$('show-new-passwords');
 let selected=null,working=false,stopped=false,generation=0,hideTimer,info=null;const pending=new Map();
 const can=()=>!stopped&&window.GREENLOOP_PAGE_ACCESS?.pageKey==='user_access'&&window.GREENLOOP_PAGE_ACCESS?.canEdit===true&&window.GREENLOOP_CAN?.('manage_access','user_access')===true;
 const allowed=()=>can()&&selected&&(!selected.protected||selected.superAdmin||selected.self),valid=v=>typeof v==='string'&&v.length>=6&&v.length<=20;
 function say(el,text='',bad=false){el.textContent=text;el.hidden=!text;el.classList.toggle('is-error',bad);}
 function hide(){clearTimeout(hideTimer);stored.value='';stored.type='password';show.textContent='Show';show.setAttribute('aria-pressed','false');}
 function clear(){password.value='';confirm.value='';password.type=confirm.type='password';toggle.checked=false;}
 function controls(){box.hidden=!can()||!selected;const ok=allowed();show.disabled=working||!ok||!info?.available;change.disabled=working||!ok;form.querySelectorAll('input,button').forEach(el=>el.disabled=working||!ok);$('password-change-close').disabled=working;check.hidden=!selected||!pending.has(selected.id);submit.hidden=!!selected&&pending.has(selected.id);password.disabled=confirm.disabled=working||!ok||!!selected&&pending.has(selected.id);toggle.disabled=password.disabled;}
 async function invoke(body){try{const result=await GREENLOOP_GET_CLIENT().functions.invoke('admin-create-user',{body});if(result.error){try{return{data:await result.error.context.clone().json(),status:result.error.context.status};}catch{return{data:null,status:0};}}return{data:result.data,status:200};}catch{return{data:null,status:0};}}
 async function loadInfo(){if(!allowed())return;const current=selected,ticket=++generation;info=null;hide();help.textContent='Checking password availability…';controls();const r=await invoke({action:'password_info',user_id:current.id});if(stopped||ticket!==generation||selected?.id!==current.id)return;
  if(r.data?.version==='20261030-user-password-1'&&r.data.user_id===current.id&&typeof r.data.available==='boolean'){info=r.data;help.textContent=info.available?'Only authorised admins can show or change this password.':'Set a new password to enable viewing.';stored.placeholder=info.available?'Password hidden':'Not available';}
  else help.textContent=r.data?.error||'Password availability could not be checked. Refresh the users list.';controls();
 }
 function close(){if(working)return;clear();if(dialog.open)dialog.close();}
 async function reveal(){if(!allowed()||working||!info?.available)return;if(stored.value){hide();return;}const current=selected,ticket=++generation,requestId=crypto.randomUUID();working=true;controls();say(message);
  try{const r=await invoke({action:'reveal_password',user_id:current.id,request_id:requestId});if(stopped||ticket!==generation||selected?.id!==current.id)return;const d=r.data;
   if(d?.version==='20261030-user-password-1'&&d.user_id===current.id&&d.request_id===requestId&&d.available===true&&valid(d.password)){stored.value=d.password;stored.type='text';show.textContent='Hide';show.setAttribute('aria-pressed','true');hideTimer=setTimeout(hide,30000);}
   else{hide();if(d?.available===false){info=d;help.textContent='Set a new password to enable viewing.';}else say(message,d?.error||'The password could not be displayed. Try again.',true);}
  }finally{working=false;controls();}
 }
 function open(){if(!allowed()||working)return;hide();clear();$('password-change-account').textContent='@'+selected.username;dialog.dataset.userId=selected.id;say(note,pending.has(selected.id)?'A previous update is not confirmed. Check its status before making another change.':'');$('password-self-notice').hidden=!selected.self;dialog.showModal();controls();if(!password.disabled)password.focus();}
 async function handleResult(r,current,requestId){const d=r.data;
  if(d?.version==='20261030-user-password-1'&&d.request_id===requestId&&d.user_id===current.id&&['confirmed','failed','pending','not_started'].includes(d.status)){
   if(d.status==='confirmed'&&d.success===true){pending.delete(current.id);clear();hide();if(dialog.open)dialog.close();say(message,'Password changed for @'+current.username+'.');await loadInfo();if(current.self){try{await GREENLOOP_GET_CLIENT().auth.signOut({scope:'local'});}finally{location.replace('index.html');}}return;}
   if(d.status==='failed'||d.status==='not_started'){pending.delete(current.id);clear();say(note,d.error||(d.status==='failed'?'The password was rejected. Choose a new password and try again.':'The password change did not start. Enter the password again.'),true);return;}
   clear();say(note,'The update is not confirmed yet. It may already be applied. Use Check status before trying another change.',true);return;
  }
  if([400,401,403,409,429].includes(r.status)&&!d?.request_id){pending.delete(current.id);clear();say(note,d?.error||'This password change was not allowed.',true);return;}
  clear();say(note,d?.error||'The connection was interrupted. The update may already be applied. Use Check status.',true);
 }
 async function save(event){event.preventDefault();if(!allowed()||working||pending.has(selected.id)||!form.reportValidity())return;say(note);
  if(!valid(password.value)){say(note,'Password must use 6 to 20 characters. Numbers alone are allowed.',true);return;}if(password.value!==confirm.value){say(note,'Passwords do not match.',true);confirm.focus();return;}
  const current=selected,requestId=crypto.randomUUID(),ticket=++generation,body={action:'change_password',user_id:current.id,expected_username:current.username,request_id:requestId,password:password.value};pending.set(current.id,requestId);working=true;hide();controls();say(note,'Changing password…');
  try{const r=await invoke(body);delete body.password;if(stopped||ticket!==generation||selected?.id!==current.id)return;await handleResult(r,current,requestId);}
  finally{delete body.password;clear();working=false;controls();}
 }
 async function status(){if(!allowed()||working||!pending.has(selected.id))return;const current=selected,requestId=pending.get(current.id),ticket=++generation;working=true;controls();say(note,'Checking password status…');try{const r=await invoke({action:'password_change_status',user_id:current.id,request_id:requestId});if(stopped||ticket!==generation||selected?.id!==current.id)return;await handleResult(r,current,requestId);}finally{working=false;controls();}}
 function select(user){if(working)return;generation++;hide();clear();if(dialog.open)dialog.close();info=null;selected=user?safeUser(user):null;say(message);if(selected&&can())loadInfo();controls();}
 function safeUser(u){return{id:String(u.userId),username:String(u.username||''),protected:u.protected===true,self:u.self===true,superAdmin:u.superAdmin===true};}
 show.addEventListener('click',()=>void reveal());change.addEventListener('click',open);form.addEventListener('submit',e=>void save(e));check.addEventListener('click',()=>void status());$('password-change-close').addEventListener('click',close);dialog.addEventListener('cancel',e=>{e.preventDefault();close();});toggle.addEventListener('change',()=>{password.type=confirm.type=toggle.checked?'text':'password';});
 window.addEventListener('greenloop:office-locked',()=>{stopped=true;generation++;pending.clear();hide();clear();working=false;selected=null;info=null;if(dialog.open)dialog.close();controls();});window.addEventListener('pagehide',()=>{generation++;hide();clear();});document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden')hide();});
 window.GREENLOOP_PASSWORD_ADMIN={select,isBusy:()=>working};controls();
})();
