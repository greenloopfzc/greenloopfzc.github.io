(() => {
'use strict';
let timer=null,inFlight=false,dirty=false,stopped=false,epoch=0,lastStarted=-Infinity,poll,authSubscription,lastUser;
const elements=()=>[...document.querySelectorAll('[data-parts-pending]')];
const names={ordered:['Parts Ordered','IMEIs awaiting parts issue'],returned:['Parts Returned','IMEIs awaiting return review']};
function reset(){for(const el of elements()){el.hidden=false;el.textContent='…';el.dataset.countState='loading';el.title='Checking pending IMEI count';el.closest('button').setAttribute('aria-label',names[el.dataset.partsPending][0]+', checking pending IMEI count');}}
function render(data){const values={};for(const key of ['ordered','returned']){const raw=data?.[key];if(!((typeof raw==='number'||typeof raw==='string'&&/^\d+$/.test(raw))&&Number.isSafeInteger(Number(raw))&&Number(raw)>=0))throw new Error('Invalid pending IMEI counts');values[key]=Number(raw);}for(const el of elements()){const n=values[el.dataset.partsPending],label=names[el.dataset.partsPending];el.textContent=n.toLocaleString('en-GB');el.hidden=n===0;el.dataset.countState='ready';el.title=n+' '+label[1];el.closest('button').setAttribute('aria-label',label[0]+', '+n+' '+label[1]);}}
function stale(){for(const el of elements()){el.dataset.countState='stale';el.title='Pending IMEI count temporarily unavailable';el.closest('button').setAttribute('aria-label',names[el.dataset.partsPending][0]+', pending IMEI count temporarily unavailable');}}
function refresh(){dirty=true;if(stopped||document.hidden||inFlight||timer)return;timer=setTimeout(run,Math.max(0,200-(performance.now()-lastStarted)));}
async function run(){timer=null;if(stopped||document.hidden||inFlight)return;inFlight=true;dirty=false;lastStarted=performance.now();const requestEpoch=epoch;let deadline;try{const result=await Promise.race([GREENLOOP_GET_CLIENT().rpc('get_parts_pending_imei_counts_v1'),new Promise((_,reject)=>{deadline=setTimeout(()=>reject(new Error('Pending IMEI count request timed out')),10000);})]);if(requestEpoch!==epoch||stopped||document.hidden)return;if(result.error)throw result.error;render(result.data);}catch(_){if(requestEpoch===epoch&&!stopped&&!document.hidden)stale();}finally{clearTimeout(deadline);inFlight=false;if(dirty)refresh();}}
async function init(){await window.GREENLOOP_ACCESS_READY;if(window.GREENLOOP_PAGE_ACCESS?.pageKey!=='parts'||!window.GREENLOOP_CAN?.('view','parts')||!elements().length)return;reset();refresh();
for(const name of ['greenloop:notifications-changed','greenloop:workflow-committed','greenloop:workflow-notifications-refreshed'])document.addEventListener(name,refresh);
window.addEventListener('storage',e=>{if(e.key==='greenloop-workflow-commit-v1')refresh();});window.addEventListener('focus',refresh);window.addEventListener('online',refresh);
document.addEventListener('visibilitychange',()=>{epoch++;if(!document.hidden)refresh();});
window.addEventListener('greenloop:office-locked',()=>{stopped=true;epoch++;clearTimeout(timer);timer=null;for(const el of elements()){el.textContent='';el.hidden=true;el.closest('button').setAttribute('aria-label',names[el.dataset.partsPending][0]);}});
window.addEventListener('pagehide',()=>{stopped=true;epoch++;clearTimeout(timer);timer=null;});window.addEventListener('pageshow',()=>{stopped=false;epoch++;refresh();});
authSubscription=GREENLOOP_GET_CLIENT().auth?.onAuthStateChange?.((event,session)=>{const user=session?.user?.id||null;if(user!==lastUser||event==='SIGNED_OUT'){lastUser=user;epoch++;if(!user){stopped=true;for(const el of elements()){el.hidden=true;el.textContent='';el.closest('button').setAttribute('aria-label',names[el.dataset.partsPending][0]);}}else{stopped=false;reset();refresh();}}})?.data?.subscription;
poll=setInterval(refresh,15000);
}
init().catch(()=>stale());
})();
