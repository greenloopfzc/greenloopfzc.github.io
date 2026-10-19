/* Voice fills a draft only. The existing Save button is the only stock write. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GREENLOOP_PRODUCTION_VOICE=api;})(typeof window==='undefined'?globalThis:window,()=>{
 'use strict';
 const small={zero:0,oh:0,one:1,two:2,three:3,four:4,five:5,six:6,seven:7,eight:8,nine:9,ten:10,eleven:11,twelve:12,thirteen:13,fourteen:14,fifteen:15,sixteen:16,seventeen:17,eighteen:18,nineteen:19,twenty:20,thirty:30,forty:40,fifty:50,sixty:60,seventy:70,eighty:80,ninety:90};
 const urdu={'صفر':'zero','ایک':'one','دو':'two','تین':'three','چار':'four','پانچ':'five','چھ':'six','سات':'seven','آٹھ':'eight','نو':'nine','دس':'ten','گیارہ':'eleven','بارہ':'twelve','تیرہ':'thirteen','چودہ':'fourteen','پندرہ':'fifteen','سولہ':'sixteen','سترہ':'seventeen','اٹھارہ':'eighteen','انیس':'nineteen','بیس':'twenty','تیس':'thirty','چالیس':'forty','پچاس':'fifty','ساٹھ':'sixty','ستر':'seventy','اسی':'eighty','نوے':'ninety','سو':'hundred','ہزار':'thousand','پرو':'pro','میکس':'max','پلس':'plus','گریڈ':'grade','کوانٹیٹی':'quantity','تعداد':'quantity','پیس':'pcs','اے':'a','بی':'b','سی':'c','ڈی':'d'};
 function normalize(value){return String(value??'').normalize('NFKC').toLowerCase()
  .replace(/[۰-۹٠-٩]/g,c=>String(c.charCodeAt(0)-(c>='۰'?'۰':'٠').charCodeAt(0)))
  .replace(/آئی\s*فون|آئیفون/g,'iphone').replace(/جی\s*بی/g,'gb').replace(/ٹی\s*بی/g,'tb')
  .replace(/i\s+phone/g,'iphone').replace(/g\s+b|gigabytes?|gigs?/g,'gb').replace(/t\s+b|terabytes?/g,'tb')
  .replace(/([0-9])([a-z])/g,'$1 $2').replace(/([a-z])([0-9])/g,'$1 $2')
  .replace(/[،,;:!?۔]/g,' ').replace(/\.(?=\s|$)/g,' ').replace(/\s+/g,' ').trim()
  .split(' ').map(w=>urdu[w]||w).join(' ');}
 const isNumberToken=t=>/^\d+$/.test(t)||Object.hasOwn(small,t)||['hundred','thousand','and'].includes(t);
 function number(text){const t=text.trim().split(/\s+/);if(!t.length||t.some(x=>!isNumberToken(x))||t[0]==='and'||t.at(-1)==='and')return null;
  if(t.length===1)return /^\d+$/.test(t[0])?Number(t[0]):small[t[0]]??null;
  if(t.includes('hundred')||t.includes('thousand')){
   let total=0,group=0,last='';for(const x of t){if(x==='and'){if(!['hundred','thousand'].includes(last))return null;last=x;continue;}
    if(x==='hundred'){if(group<1||group>9||last==='hundred')return null;group*=100;}
    else if(x==='thousand'){if(group<1||group>999||total)return null;total=group*1000;group=0;}
    else {const n=/^\d+$/.test(x)?Number(x):small[x];if(n==null||n>99||(last&&last!=='and'&&!['hundred','thousand'].includes(last)&&!(group%100>=20&&group%10===0&&n<10)))return null;group+=n;}last=x;
   }return total+group;
  }
  if(t.includes('and'))return null;const values=t.map(x=>/^\d+$/.test(x)?Number(x):small[x]);
  if(values.every(n=>n<10))return Number(values.join(''));
  if(values.length===2&&values[0]>=20&&values[0]%10===0&&values[1]<10)return values[0]+values[1];
  // Common storage pronunciation: "one twenty eight" or "two fifty six".
  if((values.length===2||values.length===3)&&values[0]>0&&values[0]<10&&values[1]>=20&&values[1]<100&&values[1]%10===0&&(values.length===2||values[2]<10))return values[0]*100+values[1]+(values[2]||0);
  if(values.length===2&&/^\d$/.test(t[0])&&/^\d{2}$/.test(t[1]))return Number(t.join(''));
  return null;
 }
 function compact(text){const tokens=normalize(text).replace(/^apple\s+/, '').replace(/^iphone\s+/, '').replace(/\bplus\b/g,'+').split(' '),out=[];
  for(let i=0;i<tokens.length;){if(isNumberToken(tokens[i])){let end=i+1;while(end<tokens.length&&isNumberToken(tokens[end]))end++;const n=number(tokens.slice(i,end).join(' '));out.push(n==null?tokens.slice(i,end).join(' '):String(n));i=end;}else out.push(tokens[i++]);}return out.join('').replace(/[·\-]/g,'');}
 function gradeKey(text){const key=compact(text);return ({ay:'a',bee:'b',be:'b',see:'c',sea:'c',dee:'d'})[key]||key;}
 function parse(transcript,options){
  if(typeof transcript!=='string'||!transcript.trim()||transcript.length>500)return {error:'Say one Model, GB, Grade and quantity.'};
  const text=normalize(transcript),tokens=text.split(' ');const units=tokens.map((t,i)=>['gb','tb'].includes(t)?i:-1).filter(i=>i>=0);
  if(units.length!==1)return {error:'Include one storage size, for example 128 GB.'};
  const unit=units[0],active=options.filter(o=>o.active),pairs=[];
  for(let start=unit-1;start>=0&&isNumberToken(tokens[start]);start--){const size=number(tokens.slice(start,unit).join(' '));if(size==null||size<=0)continue;
   const modelText=tokens.slice(0,start).join(' ').replace(/^model\s+/,'');
   const models=active.filter(o=>o.kind==='model'&&compact(o.name)===compact(modelText));const storage=active.filter(o=>o.kind==='gb'&&compact(o.name)===compact(size+' '+tokens[unit]));
   for(const model of models)for(const gb of storage)pairs.push({model,gb});
  }
  if(pairs.length!==1)return {error:pairs.length?'Model or GB has more than one match. Select them manually.':'The model and GB did not match one saved choice. Repeat the full model and storage size.'};
  const tail=tokens.slice(unit+1).join(' ');if(!tail.startsWith('grade '))return {error:'Say Grade followed by its name, then Quantity and the number.'};
  const rest=tail.slice(6);let gradeText,qtyText;const marker=rest.match(/^(.*?)\s+(?:quantity|qty|count)\s+(.+)$/);
  if(marker){gradeText=marker[1];qtyText=marker[2];}
  else {const withoutSuffix=rest.replace(/\s+(?:quantity|qty|pieces?|pcs)$/,'');const parts=withoutSuffix.split(' ');let from=parts.length;while(from>0&&isNumberToken(parts[from-1]))from--;gradeText=parts.slice(0,from).join(' ');qtyText=parts.slice(from).join(' ');}
  qtyText=(qtyText||'').replace(/\s+(?:pieces?|pcs)$/,'');const qty=number(qtyText);
  if(qty==null||!Number.isSafeInteger(qty)||qty<0||qty>1000000)return {error:'The quantity was unclear. Say Quantity followed by a whole number.'};
  const grades=active.filter(o=>o.kind==='grade'&&gradeKey(o.name)===gradeKey(gradeText));
  if(grades.length!==1)return {error:grades.length?'Grade has more than one match. Select it manually.':`No saved grade matches "${gradeText}". Repeat or select it manually.`};
  return {value:{model:pairs[0].model.id,gb:pairs[0].gb.id,grade:grades[0].id,quantity:qty}};
 }
 function create(config){
  const panel=document.getElementById('dp-voice'),button=document.getElementById('dp-voice-start'),cancelButton=document.getElementById('dp-voice-cancel'),language=document.getElementById('dp-voice-language'),status=document.getElementById('dp-voice-status'),heard=document.getElementById('dp-voice-heard');
  const Recognition=window.SpeechRecognition||window.webkitSpeechRecognition;let current=null,serial=0;
  const say=(text,state='')=>{status.textContent=text;status.dataset.state=state;};
  function finish(session){if(current!==session)return;clearTimeout(session.timer);current=null;config.setBusy(false);button.textContent='Voice Entry';button.setAttribute('aria-pressed','false');cancelButton.hidden=true;language.disabled=false;refresh();}
  function cancel(text){const session=current;if(!session)return;text=text||(session.applied?'Voice entry stopped. Review the fields; nothing was saved.':'Voice entry cancelled. Your fields were not changed.');serial++;session.cancelled=true;try{session.recognition?.abort();}catch{}finish(session);say(text);}
  function refresh(){const allowed=config.canUse();panel.hidden=!allowed;if(!allowed&&current)cancel('Voice Entry access is no longer available.');button.disabled=!allowed||!Recognition||(!current&&config.isBusy());language.disabled=!!current;if(!Recognition&&allowed)say('Voice recognition is unavailable in this browser. You can still enter fields manually.');}
  function clear(){if(current)cancel();heard.textContent='';say('Say one model, storage, grade and box quantity.');}
  button.addEventListener('click',async()=>{
   if(current||!config.canUse()||config.isBusy()||!Recognition)return;
   const session={id:++serial,cancelled:false,handled:false,draft:config.draft()};current=session;config.setBusy(true);button.disabled=true;cancelButton.hidden=false;language.disabled=true;heard.textContent='';say('Checking Voice Entry access…');
   try{await config.authorize();if(current!==session||session.cancelled)return;if(!config.canUse())throw new Error('Voice Entry access is no longer available.');
    const recognition=new Recognition();session.recognition=recognition;recognition.lang=language.value;recognition.continuous=false;recognition.interimResults=false;recognition.maxAlternatives=3;
    recognition.onresult=async event=>{
     if(current!==session||session.cancelled||session.handled)return;
     const finals=Array.from(event.results).filter(result=>result.isFinal);if(!finals.length)return;session.handled=true;clearTimeout(session.timer);try{recognition.abort();}catch{}
     try{
      if(finals.length!==1)throw new Error('Say one stock entry at a time.');const alternatives=Array.from(finals[0]);const top=alternatives[0];heard.textContent='Heard: '+String(top?.transcript||'').slice(0,500);
      const parsed=alternatives.map(a=>parse(a.transcript,config.options()));if(!parsed[0]?.value)throw new Error(parsed[0]?.error||'No clear entry was heard.');
      if(top.confidence>0&&top.confidence<0.55)throw new Error('Speech was unclear. Repeat the entry or fill it manually.');
      const key=JSON.stringify(parsed[0].value);if(parsed.some(p=>p.value&&JSON.stringify(p.value)!==key))throw new Error('More than one entry was heard as a possible match. Repeat or select the fields manually.');
      say('Checking the entry…');await config.authorize();if(current!==session||session.cancelled)return;
      if(!config.canUse()||config.draft()!==session.draft)throw new Error('The form or access changed while listening. Please try again.');
      session.applied=true;await config.apply(parsed[0].value);if(current!==session||session.cancelled)return;say('Fields filled. Review the four values, then click Save.','success');
     }catch(error){if(current===session&&!session.cancelled)say(error.message+' Fields were not saved.','error');}
     finally{finish(session);}
    };
    recognition.onerror=event=>{if(current!==session||session.cancelled||session.handled)return;const errors={'not-allowed':'Microphone access was denied. Allow it in your browser, then try again.','service-not-allowed':'Speech recognition is blocked by your browser or device.','audio-capture':'No microphone is available. Check your microphone connection.','network':'Speech recognition could not connect. Check the internet connection and try again.','language-not-supported':'This speech language is unavailable. Try English or enter manually.','no-speech':'No speech was heard. Press Voice Entry and try again.'};say(errors[event.error]||'Voice entry stopped. Try again or enter manually.','error');finish(session);};
    recognition.onend=()=>{if(current===session&&!session.handled){say('No complete entry was heard. Try again.');finish(session);}};
    recognition.start();button.textContent='Listening…';button.setAttribute('aria-pressed','true');say('Listening… Say Model, GB, Grade and Quantity.');session.timer=setTimeout(()=>cancel('Listening timed out. Press Voice Entry to try again.'),15000);
   }catch(error){if(current===session){say(error.message||'Could not start voice recognition.','error');finish(session);}}
  });
  cancelButton.addEventListener('click',()=>cancel());document.addEventListener('visibilitychange',()=>{if(document.hidden)cancel();});window.addEventListener('pagehide',()=>cancel());
  refresh();return {refresh,clear,cancel};
 }
 return Object.freeze({parse,number,normalize,create});
});
