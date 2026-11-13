(function(root) {
  'use strict';
  const loads=new Map(),clean=v=>String(v??'').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g,'').replace(/[–—‑]/g,'-');
  const display=v=>clean(root.GREENLOOP_BATCH_TEXT?root.GREENLOOP_BATCH_TEXT(v):v);
  const xml=v=>display(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
  const date=v=>v?new Date(v).toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'Not recorded';
  const gb=n=>n==null?'Not recorded':Number(n)>=1024&&Number(n)%1024===0?Number(n)/1024+' TB':n+' GB';
  const receivedDate=v=>v?new Date(v).toLocaleDateString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'}):'Not recorded';
  const names=r=>r.names_allowed===true&&root.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true;
  const supplier=(row,r)=>root.GREENLOOP_STOCK?.labelRow(row)||root.GREENLOOP_SUPPLIER_RECEIPT_LABEL(row.supplier_code,row.receipt_quantity,names(r)?row.supplier_name:null,'Not recorded');
  const file=(r,ext)=>'Greenloop-IMEI-DATA-'+(r.selection?.batch_number||'Selected-Stock').replace(/[^A-Za-z0-9_-]+/g,'-').slice(0,65)+'-'+new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(r.generated_at))+'.'+ext;
  const linkedStage=p=>[p.stage||'Not recorded',(p.linked_replacements||[]).length?'Replacement: '+p.linked_replacements.map(x=>x.new_imei+(x.entered?'':' (entry pending)')).join(', '):p.replacement_details?'Returned: '+(p.replacement_details.old_imei||'Not recorded'):p.returned?'No linked replacement':''].filter(Boolean).join(' | ');
  function pairReport(r){return {...r,accounts_pairs:true,selection_label:'Accounts IMEI DATA - Returned | '+(r.selection_label||''),summary:{returned:r.total,received:r.exchange_rows.filter(p=>p.replacement).length,pending:r.exchange_rows.filter(p=>!p.replacement).length}};}
  function verify(r) {
    if(!r||!Array.isArray(r.rows)||!Number.isSafeInteger(r.total)||r.rows.length!==r.total||r.summary?.total_records!==r.total||new Set(r.rows.map(x=>x.record_key)).size!==r.total||!Number.isFinite(Date.parse(r.generated_at))||r.rows.filter(x=>x.returned).length!==r.summary.returned)throw Error('The complete selected stock is required. No partial file was created.');
  }
  function library(name,path){if(root[name])return Promise.resolve(root[name]);if(!loads.has(name))loads.set(name,new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=path;s.onload=()=>{if(root[name])resolve(root[name]);else{loads.delete(name);s.remove();reject(Error('Export library unavailable. Retry.'));}};s.onerror=()=>{loads.delete(name);s.remove();reject(Error('Export library could not load. Check the connection and retry.'));};document.head.append(s);}));return loads.get(name);}
  function scope(r){return r.selection_label||[r.selection?.supplier_code,r.selection?.batch_number,r.selection?.invoice_number].filter(Boolean).join(' | ')||'All selected stock records';}
  function summary(r){const s=r.summary;return root.GREENLOOP_ACCOUNTS_CARDS.stockText(r.stock_summary)+' | '+(root.GREENLOOP_STOCK?.chamanText(r.chaman_summary)||'')+' | Recorded unit rows: '+r.total;}

  async function pdf(r) {
    if(r.metric==='returned')return root.GREENLOOP_STOCK_REPLACEMENT_EXPORT.pdf(pairReport(r));
    verify(r);r={...r,rows:r.rows.map((p,i)=>({...p,serial_no:i+1}))};
    const lib=await library('PDFLib','js/vendor/pdf-lib-1.17.1.min.js'),doc=await lib.PDFDocument.create(),regular=await doc.embedFont(lib.StandardFonts.Helvetica),bold=await doc.embedFont(lib.StandardFonts.HelveticaBold);
    doc.setTitle('IMEI DATA');doc.setAuthor('Greenloop FZC');doc.setSubject('Selected stock IMEIs and supplier returns');
    let logo;try{const response=await fetch('assets/greenloop-fzc-logo.jpg');if(response.ok)logo=await doc.embedJpg(await response.arrayBuffer());}catch(_){}
    const W=595.28,H=841.89,M=28,cols=[26,72,42,28,42,62,68,55,49,95.28],size=7,line=10.5,ink='#233b40',green='#087651',muted='#536a76',red='#9c332b',border='#cad8df',pages=[];
    const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');let page,y,tableTop;
    const width=(s,n=size,b=false)=>{try{return(b?bold:regular).widthOfTextAtSize(s,n);}catch(_){ctx.font=(b?'bold ':'')+n+'px Arial';return ctx.measureText(s).width;}};
    function wrap(value,max,n=size,b=false){const out=[];for(const paragraph of display(value).replace(/(BATCH-[A-Za-z0-9_-]+)(-\(\d+\))/g,(all,batch,qty)=>width(all,n,b)>max?batch+'\n'+qty:all).replace(/\r/g,'').split('\n')){let current='';for(const word of paragraph.split(/\s+/)){if(!word)continue;if(current&&width(current+' '+word,n,b)>max){out.push(current);current='';}let piece='';for(const char of word){if(piece&&width(piece+char,n,b)>max){if(current){out.push(current);current='';}out.push(piece);piece='';}piece+=char;}current+=(current?' ':'')+piece;}out.push(current);}return out.length?out:[''];}
    function text(value,x,top,n=size,b=false,color=ink){page.push({kind:'text',text:clean(value),x,top,n,b,color});}
    function rect(x,top,w,h,fill){page.push({kind:'rect',x,top,w,h,fill});}
    function cells(values,{header=false,returned=false,pending=false,replacement=false}={}){const height=Math.max(1,...values.map(v=>v.length))*line+12;let x=M;for(let i=0;i<values.length;i++){rect(x,y,cols[i],height,header?green:returned?'#f7d9d6':replacement?'#dceee2':pending?'#fff9eb':'#ffffff');values[i].forEach((s,j)=>text(s,x+(cols[i]-width(s,size,header||i===0))/2,y-(height-values[i].length*line)/2-j*line,size,header||i===0,header?'#ffffff':ink));x+=cols[i];}y-=height;}
    function start(){page=[];pages.push(page);if(logo)page.push({kind:'logo',x:M,top:H-24,w:166,h:55.38});else text('GREENLOOP FZC',M,H-31,22,true,green);
      text('IMEI DATA',M,H-94,20,true);text(r.total+' stock records',W-M-width(r.total+' stock records',10,true),H-102,10,true,green);
      text('Generated '+date(r.generated_at)+' | UAE (UTC+4)',M,H-123,8,false,muted);y=H-145;
      for(const s of wrap(scope(r),W-2*M,8)){text(s,M,y,8,false,muted);y-=11;}y-=7;
      const stats=root.GREENLOOP_ACCOUNTS_CARDS.stockFields.map(([label,,key])=>[label,r.stock_summary?.[key]]),w=(W-2*M)/4;
      stats.forEach(([label,n],i)=>{const x=M+(i%4)*w,top=y-Math.floor(i/4)*38;rect(x,top,w,38,'#eff6f3');text(label,x+6,top-5,7,false,muted);text(n??'Not recorded',x+6,top-18,12,true,green);});y-=88;
      if(r.chaman_summary){for(const s of wrap(root.GREENLOOP_STOCK?.chamanText(r.chaman_summary)||'',W-2*M,7)){text(s,M,y,7,false,muted);y-=11;}y-=7;}
      cells(['S.No','IMEI','Model','GB','Color','Supplier','Stock / Batch No.','Invoice No.','Date Received','Stage / Location'].map((s,i)=>wrap(s,cols[i]-10,size,true)),{header:true});tableTop=y;
    }
    function row(values,r){const lines=values.map((v,i)=>wrap(v,cols[i]-10));const n=Math.max(...lines.map(v=>v.length));let at=0;if(n*line+12<=tableTop-54&&n*line+12>y-54)start();while(at<n){let fit=Math.floor((y-54-12)/line);if(fit<1){start();fit=Math.floor((y-54-12)/line);}const take=Math.min(fit,n-at),part=lines.map(v=>v.slice(at,at+take));if(at>0){part[0]=wrap(String(r.serial_no||'')+' (cont.)',cols[0]-10).slice(0,take);}cells(part,{returned:r.returned,pending:r.return_pending&&!r.returned,replacement:r.is_replacement&&!r.returned});at+=take;if(at<n)start();}}
    start();
    r.rows.forEach((p,i)=>row([String(p.serial_no||i+1),p.imei||'Not recorded',p.model||'Not recorded',gb(p.storage_gb),p.color||'Not recorded',supplier(p,r),root.GREENLOOP_BATCH_LABEL(p.batch_number,p,'Not recorded'),p.invoice_number||'Not recorded',receivedDate(p.received_at),linkedStage(p)],p));
    if(!r.rows.length)row(['No records','','','','','','','','',''],{});
    pages.forEach((ops,i)=>{page=ops;text('Red rows: supplier returns. Green rows: entered replacements. S.No follows this report.',M,36,7,false,muted);const label='Page '+(i+1)+' of '+pages.length;text(label,W-M-width(label,7),23,7,false,muted);});
    const rgb=hex=>lib.rgb(...hex.match(/[\da-f]{2}/gi).map(v=>parseInt(v,16)/255));
    for(const ops of pages){const p=doc.addPage([W,H]);let unicode=false;try{for(const op of ops)if(op.kind==='text')(op.b?bold:regular).encodeText(op.text);}catch(_){unicode=true;}
      if(!unicode){for(const op of ops){if(op.kind==='text')p.drawText(op.text,{x:op.x,y:op.top-op.n,size:op.n,font:op.b?bold:regular,color:rgb(op.color)});else if(op.kind==='logo')p.drawImage(logo,{x:op.x,y:op.top-op.h,width:op.w,height:op.h});else p.drawRectangle({x:op.x,y:op.top-op.h,width:op.w,height:op.h,color:rgb(op.fill),borderColor:rgb(border),borderWidth:.4});}}
      else{canvas.width=Math.ceil(W*2);canvas.height=Math.ceil(H*2);ctx.setTransform(2,0,0,2,0,0);ctx.fillStyle='#ffffff';ctx.fillRect(0,0,W,H);for(const op of ops){if(op.kind==='text'){ctx.font=(op.b?'bold ':'')+op.n+'px Arial';ctx.fillStyle=op.color;ctx.textBaseline='top';ctx.fillText(op.text,op.x,H-op.top);}else if(op.kind==='rect'){ctx.fillStyle=op.fill;ctx.fillRect(op.x,H-op.top,op.w,op.h);ctx.strokeStyle=border;ctx.lineWidth=.4;ctx.strokeRect(op.x,H-op.top,op.w,op.h);}}
        const image=await doc.embedPng(canvas.toDataURL('image/png'));p.drawImage(image,{x:0,y:0,width:W,height:H});if(logo){const op=ops.find(v=>v.kind==='logo');if(op)p.drawImage(logo,{x:op.x,y:op.top-op.h,width:op.w,height:op.h});}}
    }
    return {bytes:await doc.save(),filename:file(r,'pdf'),pages:pages.length};
  }

  async function excel(r){
    if(r.metric==='returned')return root.GREENLOOP_STOCK_REPLACEMENT_EXPORT.excel(pairReport(r));
    verify(r);r={...r,rows:r.rows.map((p,i)=>({...p,serial_no:i+1}))};const JSZip=await library('JSZip','js/vendor/jszip-3.10.1.min.js'),zip=new JSZip();
    const headers=['S.No','IMEI','Model','GB','Color','Supplier','Stock / Batch No.','Invoice No.','Date Received','Stage / Location'];
    const letter=n=>{let v='';for(n++;n;n=Math.floor((n-1)/26))v=String.fromCharCode(65+(n-1)%26)+v;return v;},last=letter(headers.length-1),lastRow=7+r.total;
    const str=(ref,value,style=0)=>`<c r="${ref}" t="inlineStr" s="${style}"><is><t xml:space="preserve">${xml(value)}</t></is></c>`;
    const merged=(n,value,style,height)=>`<row r="${n}" ht="${height}" customHeight="1">${str('A'+n,value,style)}</row>`;
    let rows=merged(1,'GREENLOOP FZC',1,30)+merged(2,'IMEI DATA',1,28)+merged(3,scope(r),0,42)+merged(4,'Generated '+date(r.generated_at)+' | UAE (UTC+4)',0,24)+merged(5,summary(r),0,30)+`<row r="7" ht="36" customHeight="1">${headers.map((h,i)=>str(letter(i)+'7',h,2)).join('')}</row>`;
    r.rows.forEach((p,i)=>{const n=i+8,style=p.returned?3:p.is_replacement?5:p.return_pending?4:0,values=[String(p.serial_no||i+1),p.imei||'Not recorded',p.model||'Not recorded',gb(p.storage_gb),p.color||'Not recorded',supplier(p,r),root.GREENLOOP_BATCH_LABEL(p.batch_number,p,'Not recorded'),p.invoice_number||'Not recorded',receivedDate(p.received_at),linkedStage(p)];
      const height=Math.min(409,Math.max(32,Math.max(Math.ceil(String(values[1]).length/24),Math.ceil(String(values[3]).length/24),Math.ceil(String(values[4]).length/36),Math.ceil(String(values[5]).length/23))*14+12));rows+=`<row r="${n}" ht="${height}" customHeight="1">${values.map((v,j)=>str(letter(j)+n,v,style)).join('')}</row>`;});
    rows+=merged(lastRow+2,'Total records: '+r.total+' | Recorded IMEIs: '+r.summary.imeis+' | Returned: '+r.summary.returned+'\nRed rows: supplier returns. Green rows: entered replacements. S.No follows this report.',1,45);
    const ns='http://schemas.openxmlformats.org/';
    zip.file('[Content_Types].xml',`<?xml version="1.0" encoding="UTF-8"?><Types xmlns="${ns}package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>`);
    zip.file('_rels/.rels',`<?xml version="1.0"?><Relationships xmlns="${ns}package/2006/relationships"><Relationship Id="rId1" Type="${ns}officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`);
    zip.file('xl/workbook.xml',`<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="${ns}spreadsheetml/2006/main" xmlns:r="${ns}officeDocument/2006/relationships"><sheets><sheet name="IMEI DATA" sheetId="1" r:id="rId1"/></sheets></workbook>`);
    zip.file('xl/_rels/workbook.xml.rels',`<?xml version="1.0"?><Relationships xmlns="${ns}package/2006/relationships"><Relationship Id="rId1" Type="${ns}officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="${ns}officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`);
    zip.file('xl/styles.xml',`<?xml version="1.0"?><styleSheet xmlns="${ns}spreadsheetml/2006/main"><fonts count="4"><font><sz val="11"/><name val="Arial"/><color rgb="FF233B40"/></font><font><b/><sz val="18"/><name val="Arial"/><color rgb="FF087651"/></font><font><b/><sz val="11"/><name val="Arial"/><color rgb="FFFFFFFF"/></font><font><sz val="11"/><name val="Arial"/><color rgb="FF9C332B"/></font></fonts><fills count="6"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF087651"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF1EE"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF9EB"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCEEE2"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6">${[[0,0],[1,0],[2,2],[0,3],[0,4],[0,5]].map(([font,fill])=>`<xf numFmtId="0" fontId="${font}" fillId="${fill}" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" horizontal="center" vertical="center"/></xf>`).join('')}</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`);
    const widths=headers.map((h,i)=>`<col min="${i+1}" max="${i+1}" width="${[9,23,26,14,24,38,25,25,22,38][i]}" customWidth="1"/>`).join('');
    zip.file('xl/worksheets/sheet1.xml',`<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="${ns}spreadsheetml/2006/main"><dimension ref="A1:${last}${lastRow+2}"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="7" topLeftCell="A8" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="26"/><cols>${widths}</cols><sheetData>${rows}</sheetData><autoFilter ref="A7:${last}${Math.max(7,lastRow)}"/><mergeCells count="6">${[1,2,3,4,5,lastRow+2].map(n=>`<mergeCell ref="A${n}:${last}${n}"/>`).join('')}</mergeCells></worksheet>`);
    return {bytes:await zip.generateAsync({type:'uint8array',compression:'DEFLATE'}),filename:file(r,'xlsx')};
  }
  root.GREENLOOP_ACCOUNTS_IMEI_EXPORT={pdf,excel};
})(typeof window!=='undefined'?window:globalThis);
