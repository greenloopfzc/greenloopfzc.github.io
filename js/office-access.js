(function (window) {
 'use strict';
 var state=null,token='',timer=null,pending=null,locked=false,generation=0;
 var nativeFetch=window.fetch && window.fetch.bind(window);
 function config(){return window.GREENLOOP_CONFIG || window.GREENLOOP_TV_CONFIG || {};}
 function schedule(){window.clearTimeout(timer);if(token&&!document.hidden)timer=window.setTimeout(function(){check(token,function(){});},state&&state.mode==='office'?10000:60000);}
 function lock(message){
  if(locked)return;locked=true;generation++;
  if(window.GREENLOOP_GET_CLIENT){try{var client=window.GREENLOOP_GET_CLIENT();if(client.removeAllChannels)client.removeAllChannels();}catch(ignore){}}
  function paint(){
   if(!document.body)return;
   var shell=document.createElement('main');shell.className='office-access-lock';
   shell.innerHTML='<section class="office-access-lock-card"><span class="office-lock-icon" aria-hidden="true">&#128274;</span><p class="panel-kicker">GREENLOOP ACCESS</p><h1>Office access only</h1><p class="office-lock-message"></p><div><button type="button" class="primary-button office-recheck">Check connection</button><button type="button" class="secondary-button office-signout">Sign out</button></div></section>';
   shell.querySelector('.office-lock-message').textContent=message||'Please connect to the approved office network.';
   shell.querySelector('.office-recheck').onclick=function(){check(token,function(ok){if(ok)window.location.reload();});};
   shell.querySelector('.office-signout').onclick=function(){window.clearTimeout(timer);token='';try{api.reset();if(window.GREENLOOP_CLEAR_SESSION)window.GREENLOOP_CLEAR_SESSION();if(window.GREENLOOP_TV_API&&window.GREENLOOP_TV_API.logout)window.GREENLOOP_TV_API.logout(function(){});var c=window.GREENLOOP_GET_CLIENT&&window.GREENLOOP_GET_CLIENT();if(c)c.auth.signOut({scope:'local'});}catch(ignore){}window.location.replace('index.html');};
   while(document.body.firstChild)document.body.removeChild(document.body.firstChild);document.body.appendChild(shell);
  }
  if(document.body)paint();else document.addEventListener('DOMContentLoaded',paint);
  var event=document.createEvent('Event');event.initEvent('greenloop:office-locked',false,false);window.dispatchEvent(event);
 }
 function check(accessToken,callback){
  if(!callback)return new Promise(function(resolve){check(accessToken,resolve);});
  if(!accessToken){callback(false);return;}
  if(token!==accessToken){generation++;token=accessToken;}
  var stamp=generation;
  var xhr=new window.XMLHttpRequest(),c=config();
  xhr.open('POST',String(c.supabaseUrl||'').replace(/\/$/,'')+'/rest/v1/rpc/get_my_office_access_v1',true);
  xhr.setRequestHeader('apikey',c.supabaseAnonKey||'');xhr.setRequestHeader('Authorization','Bearer '+token);xhr.setRequestHeader('Content-Type','application/json');xhr.timeout=10000;
  var finished=false;
  function done(value){if(finished)return;finished=true;if(stamp!==generation){if(token&&!locked)check(token,callback);else callback(false);return;}if(!value||typeof value.allowed!=='boolean'||['anywhere','office'].indexOf(value.mode)<0){lock('Your office access could not be verified. Check the connection and try again.');schedule();callback(false);return;}state=value;api.state=value;if(!value.allowed)lock(value.configured?'Please connect to the approved office network.':'Ask your administrator to verify the office network.');schedule();callback(value.allowed);}
  xhr.onload=function(){var value;try{value=JSON.parse(xhr.responseText);}catch(ignore){}done(xhr.status===200?value:null);};xhr.onerror=xhr.ontimeout=function(){done(null);};xhr.send('{}');
 }
 function protectedUrl(url){var base=String(config().supabaseUrl||'').replace(/\/$/,'');return base&&url.indexOf(base+'/')===0&&/\/(rest|storage|functions)\/v1\//.test(url);}
 function denied(){return new Response(JSON.stringify({code:'42501',message:'Office access only. Please connect to the office network.',details:'GREENLOOP_OFFICE_ONLY'}),{status:403,headers:{'Content-Type':'application/json'}});}
 var api={check:check,lock:lock,reset:function(){generation++;token='';state=null;locked=false;api.state=null;window.clearTimeout(timer);},state:null,fetch:nativeFetch&&function(input,options){
  var url=typeof input==='string'?input:input.url,protectedRequest=protectedUrl(url)&&url.indexOf('/rpc/get_my_office_access_v1')<0,stamp=generation;
  if(locked&&protectedRequest)return Promise.resolve(denied());
  return nativeFetch(input,options).then(function(response){
   if(locked&&protectedRequest&&stamp!==generation)return denied();
   if(protectedRequest&&response.status===403)return response.clone().json().catch(function(){return {};}).then(function(body){if(body.details==='GREENLOOP_OFFICE_ONLY'){lock(body.message);return denied();}return response;});
   return response;
  });
 }};
 window.GREENLOOP_OFFICE=api;
 window.addEventListener('focus',function(){if(token)check(token,function(){});});
 window.addEventListener('online',function(){if(token)check(token,function(){});});
 window.addEventListener('offline',function(){if(state&&state.mode==='office')lock('Connect to the office network to continue.');});
 document.addEventListener('visibilitychange',function(){if(!document.hidden&&token)check(token,function(){});else window.clearTimeout(timer);});
})(window);
