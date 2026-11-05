(function(root){
 'use strict';
 let libraryPromise;
 const clean=v=>String(v??'').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g,'').replace(/[–—‑]/g,'-');
 function library(){if(root.PDFLib)return Promise.resolve(root.PDFLib);if(!libraryPromise)libraryPromise=new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='js/vendor/pdf-lib-1.17.1.min.js';s.onload=()=>root.PDFLib?resolve(root.PDFLib):(libraryPromise=null,reject(Error('PDF library unavailable. Retry.')));s.onerror=()=>{libraryPromise=null;s.remove();reject(Error('PDF library could not load. Check the connection and retry.'));};document.head.append(s);});return libraryPromise;}
 async function create(r){
  const F=root.GREENLOOP_STOCK_GRADE_FORMAT;F.validate(r);if(!r.selected||!r.rows.length)throw Error('Select stock with entered IMEIs before creating a PDF.');
  const lib=await library(),doc=await lib.PDFDocument.create(),regular=await doc.embedFont(lib.StandardFonts.Helvetica),bold=await doc.embedFont(lib.StandardFonts.HelveticaBold);
  doc.setTitle(F.title);doc.setAuthor('Greenloop FZC');doc.setSubject('Initial QC GL Grade and required Glass / Polish analysis');
  let logo;try{const res=await fetch('assets/greenloop-fzc-logo.jpg');if(res.ok)logo=await doc.embedJpg(await res.arrayBuffer());}catch(_){}
  const W=595.28,H=841.89,M=28,IW=W-2*M,ink='#243b4b',green='#087651',muted='#536a76',border='#cad8df',pages=[],canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');let ops,y;
  const width=(s,n=9,b=false)=>{try{return(b?bold:regular).widthOfTextAtSize(clean(s),n);}catch(_){ctx.font=(b?'bold ':'')+n+'px Arial';return ctx.measureText(clean(s)).width;}};
  function wrap(v,max,n=9,b=false){const result=[];for(const paragraph of clean(v).split(/\r?\n/)){let line='';for(const word of paragraph.split(/\s+/).filter(Boolean)){if(line&&width(line+' '+word,n,b)>max){result.push(line);line='';}let part='';for(const ch of word){if(part&&width(part+ch,n,b)>max){if(line){result.push(line);line='';}result.push(part);part='';}part+=ch;}line+=(line?' ':'')+part;}result.push(line);}return result;}
  const text=(v,x,top,n=9,b=false,color=ink)=>ops.push({kind:'text',text:clean(v),x,top,n,b,color});
  const rect=(x,top,w,h,fill)=>ops.push({kind:'rect',x,top,w,h,fill});
  const centered=(v,x,top,w,n=9,b=false,color=ink)=>text(v,x+(w-width(v,n,b))/2,top,n,b,color);
  const unique=values=>[...new Set(values.filter(Boolean))],suppliers=unique(r.stocks.map(s=>F.supplier(s,r))),batches=unique(r.stocks.map(s=>s.batch_number)),invoices=unique(r.stocks.map(s=>s.invoice_number));
  const fullScope=['Supplier: '+(suppliers.length===1?suppliers[0]:suppliers.length+' suppliers'),'Stock / Batch: '+(batches.length===1?batches[0]:batches.length+' selected batches')+' | Invoice: '+(invoices.length===1?invoices[0]:invoices.length+' invoices')],longScope=fullScope.some(value=>wrap(value,IW,8).length>3);
  function start(){
   ops=[];pages.push(ops);if(logo)ops.push({kind:'logo',x:M,top:H-24,w:166,h:55.38});else text('GREENLOOP FZC',M,H-31,23,true,green);
   text(F.title,M,H-96,19,true);const date=new Date(r.generated_at).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:true});text('Generated '+date+' | UAE (UTC+4)',M,H-122,8,false,muted);y=H-141;
   const scope=longScope?['Supplier: '+unique(r.stocks.map(s=>String(s.supplier_code||'Not recorded').replace(/-\(\d+\)$/,'')+(s.stock_quantity==null?'':'-('+s.stock_quantity+')'))).join(', '),'Selected stock details are listed after the analysis.']:fullScope;
   for(const value of scope)for(const line of wrap(value,IW,8)){text(line,M,y,8,false,muted);y-=11;}
   y-=8;const stats=[['Received stock',r.totals.stock_quantity],['Entered IMEIs',r.totals.qty],['Not entered',r.totals.unentered],['QC / grade pending',r.totals.pending]],w=IW/4;
   for(let i=0;i<stats.length;i++){rect(M+i*w,y,w,40,'#eff6f3');centered(stats[i][0],M+i*w,y-6,w,7.5,false,muted);centered(F.num(stats[i][1]),M+i*w,y-19,w,14,true,green);}y-=56;
   if(r.receipt_summary){const stock=r.receipt_summary,extra=[['Received',stock.received],['Returned',stock.returned],['Replacement received',stock.replacement_received],['Stock balance',stock.balance]];for(let i=0;i<extra.length;i++){rect(M+i*w,y,w,38,'#eff6f3');centered(extra[i][0],M+i*w,y-6,w,7.5,false,muted);centered(extra[i][1]===null?'Not recorded':F.num(extra[i][1]),M+i*w,y-18,w,14,true,green);}y-=52;}
  }
  function cellRow(lines,widths,{header=false,total=false,offset=0,take=null}={}){const n=take??Math.max(...lines.map(v=>v.length)),h=n*12+14;let x=M;for(let i=0;i<lines.length;i++){rect(x,y,widths[i],h,header?green:total?'#e7f2ec':'#ffffff');lines[i].slice(offset,offset+n).forEach((line,j)=>centered(line,x,y-7-j*12,widths[i],header?8:9,header||total||i===0,header?'#ffffff':ink));x+=widths[i];}y-=h;}
  function section(label,cols,rows,total){const numbered=/^model$/i.test(cols[0]);if(numbered){cols=['S.No',...cols];rows=rows.map((r,i)=>[String(i+1),...r]);total=['',...total];}
   const widths=numbered?[36,96,43,...Array(cols.length-3).fill((IW-175)/(cols.length-3))]:cols.length===4?[145,140,180,IW-465]:[132,43,...Array(cols.length-2).fill((IW-175)/(cols.length-2))];
   const header=cols.map((c,i)=>wrap(c,widths[i]-10,8,true));
   function heading(cont=false){if(y<140)start();text(label+(cont?' (continued)':''),M,y,13,true,green);y-=23;cellRow(header,widths,{header:true});}
   heading();
   for(const row of [...rows,...(total?[total]:[])]){const isTotal=row===total,lines=row.map((v,i)=>wrap(v,widths[i]-10,9,isTotal||i===0)),n=Math.max(...lines.map(v=>v.length));let at=0;
    if(y-(n*12+14)<62&&n*12+14<450){start();heading(true);}
    while(at<n){let fit=Math.floor((y-62-14)/12);if(fit<1){start();heading(true);fit=Math.floor((y-62-14)/12);}const take=Math.min(n-at,fit);cellRow(lines,widths,{total:isTotal,offset:at,take});at+=take;if(at<n){start();heading(true);}}
   }y-=25;
  }
  start();const cols=F.columns(r),quantity=x=>cols.map(([k])=>k==='model'?x.model:F.num(x[k])),percentage=x=>cols.map(([k])=>k==='model'?x.model:k==='qty'?F.num(x.qty):F.pct(x[k],x.qty));
  section('Grade & required work',cols.map(c=>c[1]),r.rows.map(quantity),quantity({...r.totals,model:'TOTAL'}));
  section('Percentage analysis',cols.map(c=>c[1]),r.rows.map(percentage),percentage({...r.totals,model:'TOTAL'}));
  const notes=[...(r.other_grades.length?['Other grades: '+r.other_grades.map(g=>g.grade+': '+F.num(g.qty)).join(' | ')]:[]),'Initial QC GL Grade and required work. Later Lab additions are excluded.','Percentages use entered model Qty; totals use total entered Qty. Glass and Polish can overlap.','Returned phones remain included in their original stock analysis.'];
  for(const note of notes)for(const line of wrap(note,IW,8)){if(y<62)start();text(line,M,y,8,false,muted);y-=12;}
  if(r.stocks.length>1||longScope){y-=20;section('Selected stock receipts',['Supplier','Stock / Batch','Invoice','Received Qty'],r.stocks.map(s=>[F.supplier(s,r),s.batch_number,s.invoice_number||'Not recorded',F.num(s.stock_quantity)]),null);}
  const rgb=hex=>lib.rgb(...hex.match(/[\da-f]{2}/gi).map(v=>parseInt(v,16)/255));
  for(let i=0;i<pages.length;i++){ops=pages[i];text('GREENLOOP FZC | Initial QC stock analysis',M,35,7,false,muted);const label='Page '+(i+1)+' of '+pages.length;text(label,W-M-width(label,7),24,7,false,muted);const p=doc.addPage([W,H]);let unicode=false;try{for(const op of ops)if(op.kind==='text')(op.b?bold:regular).encodeText(op.text);}catch(_){unicode=true;}
   if(!unicode){for(const op of ops){if(op.kind==='text')p.drawText(op.text,{x:op.x,y:op.top-op.n,size:op.n,font:op.b?bold:regular,color:rgb(op.color)});else if(op.kind==='logo')p.drawImage(logo,{x:op.x,y:op.top-op.h,width:op.w,height:op.h});else p.drawRectangle({x:op.x,y:op.top-op.h,width:op.w,height:op.h,color:rgb(op.fill),borderColor:rgb(border),borderWidth:.45});}}
   else{canvas.width=Math.ceil(W*2);canvas.height=Math.ceil(H*2);ctx.setTransform(2,0,0,2,0,0);ctx.fillStyle='#fff';ctx.fillRect(0,0,W,H);for(const op of ops){if(op.kind==='text'){ctx.font=(op.b?'bold ':'')+op.n+'px Arial';ctx.fillStyle=op.color;ctx.textBaseline='top';ctx.fillText(op.text,op.x,H-op.top);}else if(op.kind==='rect'){ctx.fillStyle=op.fill;ctx.fillRect(op.x,H-op.top,op.w,op.h);ctx.strokeStyle=border;ctx.lineWidth=.45;ctx.strokeRect(op.x,H-op.top,op.w,op.h);}}const img=await doc.embedPng(canvas.toDataURL('image/png'));p.drawImage(img,{x:0,y:0,width:W,height:H});if(logo){const op=ops.find(o=>o.kind==='logo');if(op)p.drawImage(logo,{x:op.x,y:op.top-op.h,width:op.w,height:op.h});}}
  }
  const scope=batches.length===1?batches[0]:'Selected-Stocks';return{bytes:await doc.save(),filename:'Greenloop-Stock-Grade-Analysis-'+scope.replace(/[^A-Za-z0-9_-]/g,'-').slice(0,65)+'.pdf',pages:pages.length};
 }
 root.GREENLOOP_STOCK_GRADE_PDF={create};
})(typeof window!=='undefined'?window:globalThis);
