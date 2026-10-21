/* Voice fills a draft only. The existing Save button is the only stock write. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GREENLOOP_PRODUCTION_VOICE=api;})(typeof window==='undefined'?globalThis:window,()=>{
 'use strict';
 const small={zero:0,oh:0,o:0,one:1,won:1,two:2,to:2,too:2,three:3,four:4,for:4,five:5,six:6,seven:7,eight:8,eigh:8,ate:8,nine:9,ten:10,eleven:11,twelve:12,thirteen:13,fourteen:14,fifteen:15,sixteen:16,seventeen:17,eighteen:18,nineteen:19,twenty:20,thirty:30,forty:40,fifty:50,sixty:60,seventy:70,eighty:80,ninety:90};
 // Urdu and common Roman Urdu number spellings may be mixed with English.
 const numberNames=[
  'صفر sifr', 'ایک ek aik', 'دو do', 'تین teen', 'چار char chaar', 'پانچ panch paanch', 'چھ چھے chhe chhay chay', 'سات sat saat', 'آٹھ ath aath', 'نو nau',
  'دس das dus', 'گیارہ gyarah gyara', 'بارہ barah bara', 'تیرہ terah tera', 'چودہ chaudah choda', 'پندرہ pandrah pandra', 'سولہ solah sola', 'سترہ satrah satra', 'اٹھارہ atharah athara', 'انیس unnees unnis',
  'بیس bees bis', 'اکیس ikkees ikkis', 'بائیس baees bais', 'تئیس teis', 'چوبیس chaubees chobis', 'پچیس pachis pachees', 'چھبیس chhabbis chhabbees', 'ستائیس sattais', 'اٹھائیس athais atthais', 'انتیس untees untis',
  'تیس tees tis', 'اکتیس iktees iktis', 'بتیس battees battis', 'تینتیس tentees taintis', 'چونتیس chauntees chauntis', 'پینتیس paintees paintis', 'چھتیس chhattees chhattis', 'سینتیس saintees saintis', 'اڑتیس artees arhtis', 'انتالیس untalees untalis',
  'چالیس chalees chalis chaalis', 'اکتالیس iktalees iktalis', 'بیالیس bayalees bayalis', 'تینتالیس taintalees taintalis', 'چوالیس chawalees chawalis', 'پینتالیس paintalees paintalis', 'چھیالیس chhiyalees chhiyalis', 'سینتالیس saintalees saintalis', 'اڑتالیس artalees arhtalis', 'انچاس unchas unchaas',
  'پچاس pachas pachaas', 'اکیاون ikyavan ikyawan', 'باون bavan bawan', 'ترپن tirpan', 'چون chawan chauwan', 'پچپن pachpan', 'چھپن chhappan chappan', 'ستاون sattavan sattawan', 'اٹھاون atthavan atthawan', 'انسٹھ unsath unsathh',
  'ساٹھ saath', 'اکسٹھ iksath', 'باسٹھ basath', 'تریسٹھ tirsath', 'چونسٹھ chaunsath', 'پینسٹھ painsath', 'چھیاسٹھ chhiyasath', 'سڑسٹھ sarsath', 'اڑسٹھ arsath', 'انہتر unhattar',
  'ستر sattar', 'اکہتر ikhattar', 'بہتر bahattar', 'تہتر tihattar', 'چوہتر chauhattar', 'پچھتر pachhattar', 'چھہتر chhihattar', 'ستتر satahattar', 'اٹھتر athhattar', 'اناسی unasi unaasi',
  'اسی assi', 'اکیاسی ikyasi', 'بیاسی bayasi', 'تراسی tirasi', 'چوراسی chaurasi', 'پچاسی pachasi', 'چھیاسی chhiyasi', 'ستاسی satasi', 'اٹھاسی athasi', 'نواسی nawasi',
  'نوے nabbe', 'اکانوے ikyanve', 'بانوے banve', 'ترانوے tiranve', 'چورانوے chauranve', 'پچانوے pachanve', 'چھیانوے chhiyanve', 'ستانوے satanve', 'اٹھانوے athanve', 'ننانوے ninyanve'
 ];
 const aliases=Object.fromEntries(numberNames.flatMap((words,n)=>words.split(' ').map(word=>[word,String(n)])));
 Object.assign(aliases,{'سو':'hundred',sau:'hundred',sou:'hundred','ہزار':'thousand',hazar:'thousand',hazaar:'thousand','پرو':'pro','میکس':'max','پلس':'plus','گریڈ':'grade','کوانٹیٹی':'quantity','تعداد':'quantity','پیس':'pcs','پیسز':'pcs',pice:'piece',pices:'pieces','اے':'a','بی':'b','سی':'c','ڈی':'d'});
 function normalize(value){return String(value??'').normalize('NFKC').toLowerCase()
  .replace(/[۰-۹٠-٩]/g,c=>String(c.charCodeAt(0)-(c>='۰'?'۰':'٠').charCodeAt(0)))
  .replace(/آئی\s*فون|آئیفون/g,'iphone').replace(/جی\s*بی/g,'gb').replace(/ٹی\s*بی/g,'tb')
  .replace(/\bi\s+phone\b/g,'iphone').replace(/\b(?:g\s+b|gigabytes?|gigs?)\b/g,'gb').replace(/\b(?:t\s+b|terabytes?)\b/g,'tb')
  .replace(/([0-9])([a-z])/g,'$1 $2').replace(/([a-z])([0-9])/g,'$1 $2')
  .replace(/([a-z])-([a-z])/g,'$1 $2').replace(/[،,;:!?۔]/g,' ').replace(/\.(?=\s|$)/g,' ').replace(/\s+/g,' ').trim()
  .split(' ').map(word=>aliases[word]||word).join(' ');}
 const isNumberToken=t=>/^\d+$/.test(t)||Object.hasOwn(small,t)||['hundred','thousand','and'].includes(t);
 function number(text){const t=normalize(text).split(/\s+/);if(!t.length||t.some(x=>!isNumberToken(x))||t[0]==='and'||t.at(-1)==='and')return null;
  if(t.length===1)return /^\d+$/.test(t[0])?Number(t[0]):small[t[0]]??(t[0]==='hundred'?100:t[0]==='thousand'?1000:null);
  if(t.includes('hundred')||t.includes('thousand')){
   let total=0,group=0,last='';for(const x of t){if(x==='and'){if(!['hundred','thousand'].includes(last))return null;last=x;continue;}
    if(x==='hundred'){if(group<1||group>9||last==='hundred')return null;group*=100;}
    else if(x==='thousand'){if(group<1||group>999||total)return null;total=group*1000;group=0;}
    else {const n=/^\d+$/.test(x)?Number(x):small[x];if(n==null||n>99||(last&&last!=='and'&&!['hundred','thousand'].includes(last)&&!(group%100>=20&&group%10===0&&n<10)))return null;group+=n;}last=x;
   }return total+group;
  }
  if(t.includes('and'))return null;const values=t.map(x=>/^\d+$/.test(x)?Number(x):small[x]);
  if(values.every(n=>n<10))return Number(t.map((word,i)=>/^\d+$/.test(word)?word:String(values[i])).join(''));
  if(values.length===2&&values[0]>=20&&values[0]%10===0&&values[1]<10)return values[0]+values[1];
  if((values.length===2||values.length===3)&&values[0]>0&&values[0]<10&&values[1]>=20&&values[1]<100&&values[1]%10===0&&(values.length===2||values[2]<10))return values[0]*100+values[1]+(values[2]||0);
  if(values.length===2&&values[0]>0&&values[0]<10&&/^\d{2}$/.test(t[1]))return values[0]*100+values[1];
  return null;
 }
 function compact(text){const tokens=normalize(text).replace(/^apple\s+/, '').replace(/^iphone\s+/, '').replace(/\bplus\b/g,'+').split(' '),out=[];
  for(let i=0;i<tokens.length;){if(isNumberToken(tokens[i])){let end=i+1;while(end<tokens.length&&isNumberToken(tokens[end]))end++;const n=number(tokens.slice(i,end).join(' '));out.push(n==null?tokens.slice(i,end).join(' '):String(n));i=end;}else out.push(tokens[i++]);}return out.join('').replace(/[·\-]/g,'');}
 function modelKey(text){return compact(normalize(text).replace(/^model\s+/,''));}
 const gradeLetters={ay:'a',aye:'a',bee:'b',be:'b',see:'c',sea:'c',dee:'d'};
 // These are grade-word aliases only, never fuzzy model or quantity matches.
 const bulgesWords=new Set(['bulges','bulge','bulgis','bulgus','bulgers','buljes','bulj','bagees','bageez','bagis','bajz','bajze','بلجز','بلج','بولجز','بلجس']);
 function gradeKey(text){
  const words=normalize(text).replace(/\bgrade\b/g,' ').trim().split(/\s+/);
  const letter=t=>gradeLetters[t]||t;
  if(words.length>1){
   const last=letter(words.at(-1)),first=letter(words[0]);
   if(['a','b'].includes(last)&&bulgesWords.has(words.slice(0,-1).join('')))return 'bulges'+last;
   if(['a','b'].includes(first)&&bulgesWords.has(words.slice(1).join('')))return 'bulges'+first;
  }
  const key=compact(words.join(' '));return gradeLetters[key]||key;
 }
 function storageValue(text){const t=normalize(text).replace(/^(?:storage|memory)\s+/,'').split(' ');let unit='';if(['gb','tb'].includes(t[0]))unit=t.shift();if(['gb','tb'].includes(t.at(-1))){const last=t.pop();if(unit&&unit!==last)return null;unit=last;}const size=number(t.join(' '));return Number.isSafeInteger(size)&&size>0?{size,unit}:null;}
 function quantityValue(text){return number(normalize(text).replace(/^(?:quantity|qty|count|pieces?|pcs)\s+/,'').replace(/\s+(?:quantity|qty|count|pieces?|pcs)$/,''));}
 function indexOptions(options,key){const map=new Map();for(const o of options){const k=key(o.name);if(!map.has(k))map.set(k,[]);map.get(k).push(o);}return map;}
 function parseFields(transcript,options,recover=false){
  if(typeof transcript!=='string'||!transcript.trim()||transcript.length>500)return {error:'Say Model, storage, grade and quantity, in that order.'};
  const original=normalize(transcript).split(' ');
  // Speech services can join 13 + 128 into 13128. In recovery, expose digit
  // boundaries and resolve them against saved choices. Never change a digit.
  const tokens=recover?original.flatMap(t=>/^\d{2,}$/.test(t)?t.split(''):t):original;
  if(tokens.length>64)return {error:'Say one stock entry at a time.'};
  const active=(options||[]).filter(o=>o.active),models=indexOptions(active.filter(o=>o.kind==='model'),modelKey),grades=indexOptions(active.filter(o=>o.kind==='grade'),gradeKey);
  const storage=active.filter(o=>o.kind==='gb').map(o=>({option:o,value:storageValue(o.name)})).filter(o=>o.value),matches=new Map();
  let foundModel=false,foundStorage=false,foundGrade=false;
  // Try field boundaries against saved choices. Optional labels are consumed only
  // by their own field, so every word belongs to exactly one of the four fields.
  for(let m=1;m<tokens.length-2;m++){
   const modelMatches=models.get(modelKey(tokens.slice(0,m).join(' ')));if(!modelMatches)continue;foundModel=true;
   for(let s=m+1;s<tokens.length-1;s++){
    const size=storageValue(tokens.slice(m,s).join(' '));if(!size)continue;
    const storageMatches=storage.filter(o=>o.value.size===size.size&&(!size.unit||size.unit===(o.value.unit||'gb')));if(!storageMatches.length)continue;foundStorage=true;
    for(let g=s+1;g<tokens.length;g++){
     const gradeText=tokens.slice(s,g).join(' '),key=gradeKey(gradeText);
     let gradeMatches=grades.get(key),inferredGrade=false;
     // A ten can be transcribed as 810. A saved numeric grade takes priority.
     // Only recover this at the grade boundary; quantities keep all their digits.
     if(!gradeMatches&&recover&&['8','eight','ate'].includes(key)){gradeMatches=grades.get('a');inferredGrade=!!gradeMatches;}
     if(!gradeMatches)continue;foundGrade=true;
     const qty=quantityValue(tokens.slice(g).join(' '));if(!Number.isSafeInteger(qty)||qty<0||qty>1000000)continue;
     for(const model of modelMatches)for(const gb of storageMatches)for(const grade of gradeMatches){const value={model:model.id,gb:gb.option.id,grade:grade.id,quantity:qty};const id=JSON.stringify(value),previous=matches.get(id);if(!previous||!inferredGrade)matches.set(id,{value,inferredGrade});}
    }
   }
  }
  if(matches.size===1){const match=matches.values().next().value;return recover?{value:match.value,review:match.inferredGrade?'Interpreted the grade as A from the speech reading.':'Separated joined numbers using saved choices.'}:{value:match.value};}
  if(matches.size>1)return {ambiguous:true,error:'More than one saved choice matches this entry. Say the full model, storage unit or grade, or select the fields manually.'};
  if(!foundModel)return {progress:0,error:'The model did not match a saved choice. Say its number and version, for example 13 Pro Max.'};
  if(!foundStorage)return {progress:1,error:'The storage was unclear or is not a saved choice. Say it after the model, for example one two eight.'};
  if(!foundGrade)return {progress:2,error:'The grade was unclear or is not a saved choice. Say the full grade after the storage, for example A, B or a saved custom grade.'};
  return {progress:3,error:'The quantity was unclear. Say a whole number after the grade, for example fifty, five zero or pachaas.'};
 }
 function parse(transcript,options){
  const exact=parseFields(transcript,options);
  if(exact.value||exact.ambiguous)return exact;
  const recovered=parseFields(transcript,options,true);
  const result=recovered.value||recovered.ambiguous||(recovered.progress??0)>(exact.progress??0)?recovered:exact;
  const {progress,...publicResult}=result;return publicResult;
 }
 function create(config){
  const panel=document.getElementById('dp-voice'),button=document.getElementById('dp-voice-start'),cancelButton=document.getElementById('dp-voice-cancel'),language=document.getElementById('dp-voice-language'),status=document.getElementById('dp-voice-status'),heard=document.getElementById('dp-voice-heard'),matched=document.getElementById('dp-voice-matched');
  const Recognition=window.SpeechRecognition||window.webkitSpeechRecognition;let current=null,serial=0;
  const say=(text,state='')=>{status.textContent=text;status.dataset.state=state;};
  function finish(session){if(current!==session)return;clearTimeout(session.timer);current=null;config.setBusy(false);button.textContent='Voice Entry';button.setAttribute('aria-pressed','false');cancelButton.hidden=true;language.disabled=false;refresh();}
  function cancel(text){const session=current;if(!session)return;text=text||(session.applied?'Voice entry stopped. Review the fields; nothing was saved.':'Voice entry cancelled. Your fields were not changed.');serial++;session.cancelled=true;try{session.recognition?.abort();}catch{}finish(session);say(text);}
  function refresh(){const allowed=config.canUse();panel.hidden=!allowed;if(!allowed&&current)cancel('Voice Entry access is no longer available.');button.disabled=!allowed||!Recognition||(!current&&config.isBusy());language.disabled=!!current;if(!Recognition&&allowed)say('Voice recognition is unavailable in this browser. You can still enter fields manually.');}
  function clear(){if(current)cancel();heard.textContent='';matched.textContent='';say('Say: 13, one two eight, A, five zero.');}
  // The matched summary describes the voice draft; clear it after manual edits.
  for(const event of ['input','change'])document.getElementById('dp-entry-form').addEventListener(event,()=>{matched.textContent='';});
  button.addEventListener('click',async()=>{
   if(current||!config.canUse()||config.isBusy()||!Recognition)return;
   const session={id:++serial,cancelled:false,handled:false,draft:config.draft()};current=session;config.setBusy(true);button.disabled=true;cancelButton.hidden=false;language.disabled=true;heard.textContent='';matched.textContent='';say('Checking Voice Entry access…');
   try{await config.authorize();if(current!==session||session.cancelled)return;if(!config.canUse())throw new Error('Voice Entry access is no longer available.');
    const recognition=new Recognition();session.recognition=recognition;recognition.lang=language.value;recognition.continuous=false;recognition.interimResults=false;recognition.maxAlternatives=5;
    recognition.onresult=async event=>{
     if(current!==session||session.cancelled||session.handled)return;
     const finals=Array.from(event.results).filter(result=>result.isFinal);if(!finals.length)return;session.handled=true;clearTimeout(session.timer);try{recognition.abort();}catch{}
     try{
      if(finals.length!==1)throw new Error('Say one stock entry at a time.');const alternatives=Array.from(finals[0]);const top=alternatives[0];heard.textContent='Heard: '+String(top?.transcript||'').slice(0,500);
      const parsed=alternatives.map(a=>parse(a.transcript,config.options())),valid=parsed.filter(p=>p.value);
      if(!valid.length)throw new Error(parsed[0]?.error||'No clear entry was heard.');
      const match=valid[0],key=JSON.stringify(match.value);
      if(parsed.some(p=>p.ambiguous)||valid.some(p=>JSON.stringify(p.value)!==key))throw new Error('More than one entry was heard as a possible match. Repeat or select the fields manually.');
      const needsReview=!!match.review||!parsed[0]?.value||(top.confidence>0&&top.confidence<0.55);
      say('Checking the entry…');await config.authorize();if(current!==session||session.cancelled)return;
      if(!config.canUse()||config.draft()!==session.draft)throw new Error('The form or access changed while listening. Please try again.');
      session.applied=true;await config.apply(match.value);if(current!==session||session.cancelled)return;
      const options=config.options(),name=(kind,id)=>options.find(o=>o.kind===kind&&o.id===id)?.name||'';
      matched.textContent='Matched: '+[name('model',match.value.model),name('gb',match.value.gb),'Grade '+name('grade',match.value.grade),match.value.quantity+' pcs'].join(' · ');
      say(needsReview?(match.review||'Matched a possible speech reading.')+' Review all four fields, then click Save.':'Fields filled. Review the four values, then click Save.',needsReview?'review':'success');
     }catch(error){if(current===session&&!session.cancelled)say(error.message+' Fields were not saved.','error');}
     finally{finish(session);}
    };
    recognition.onerror=event=>{if(current!==session||session.cancelled||session.handled)return;const errors={'not-allowed':'Microphone access was denied. Allow it in your browser, then try again.','service-not-allowed':'Speech recognition is blocked by your browser or device.','audio-capture':'No microphone is available. Check your microphone connection.','network':'Speech recognition could not connect. Check the internet connection and try again.','language-not-supported':'This speech language is unavailable. Try English or enter manually.','no-speech':'No speech was heard. Press Voice Entry and try again.'};say(errors[event.error]||'Voice entry stopped. Try again or enter manually.','error');finish(session);};
    recognition.onend=()=>{if(current===session&&!session.handled){say('No complete entry was heard. Try again.');finish(session);}};
    recognition.start();button.textContent='Listening…';button.setAttribute('aria-pressed','true');say('Listening… Model → Storage → Grade → Quantity. Labels are optional.');session.timer=setTimeout(()=>cancel('Listening timed out. Press Voice Entry to try again.'),15000);
   }catch(error){if(current===session){say(error.message||'Could not start voice recognition.','error');finish(session);}}
  });
  cancelButton.addEventListener('click',()=>cancel());document.addEventListener('visibilitychange',()=>{if(document.hidden)cancel();});window.addEventListener('pagehide',()=>cancel());
  refresh();return {refresh,clear,cancel};
 }
 return Object.freeze({parse,number,normalize,create});
});
