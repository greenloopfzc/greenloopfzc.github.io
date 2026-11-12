/* Full Stock Exported source-detail sheet. The packing-sheet renderer remains separate. */
(function(root){
 'use strict';
 const W=595.276,H=841.89,M=22,BODY=W-2*M;
 const clean=v=>String(v??'').replace(/[\u0000-\u001f\u007f]/g,' ').replace(/[–—‑]/g,'-').replace(/\s+/g,' ').trim();
 const label=v=>clean(v)||'-';
 const columns=[['S.NO','serial_no',22],['IMEI','imei',64],['MODEL','model',40],['GB','storage_gb',24],['GRADE','final_grade',30],['COLOR','color',45],['SUPPLIER','supplier_name',36],['SUPPLIER CODE','supplier_code',46],['STOCK RECEIVED · UAE','received_at',64],['INVOICE','invoice_number',54],['STOCK/BATCH NO','batch_number',84]];
 let libraryPromise;
 function library(){if(root.PDFLib)return Promise.resolve(root.PDFLib);if(!root.document)return Promise.reject(Error('PDF tools are unavailable.'));if(!libraryPromise)libraryPromise=new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='js/vendor/pdf-lib-1.17.1.min.js';s.onload=()=>root.PDFLib?resolve(root.PDFLib):(libraryPromise=null,reject(Error('PDF tools did not load. Retry printing.')));s.onerror=()=>{libraryPromise=null;s.remove();reject(Error('PDF tools could not load. Retry printing.'));};document.head.append(s);});return libraryPromise;}
 function date(value){if(!value)return '-';const d=new Date(value);if(!Number.isFinite(d.getTime()))return label(value);return d.toLocaleString('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric'});}
 function prepare(data,{namesAllowed=root.GREENLOOP_CAN_VIEW_PARTNER_NAMES===true}={}){
  if(!data?.box||!clean(data.box.box_number)||!Array.isArray(data.lines)||!data.lines.length)throw Error('A non-empty box is required for printing.');
  const seen=new Set(),serials=new Set();const rows=data.lines.map((row,i)=>{
   const imei=clean(row.imei),serial=Number(row.serial_no??i+1);
   if(!/^\d{15}$/.test(imei)||seen.has(imei)||!Number.isSafeInteger(serial)||serial<1||serials.has(serial))throw Error('A phone IMEI or serial number is invalid or duplicated. Reload this box.');seen.add(imei);serials.add(serial);
   return columns.map(([,key])=>key==='serial_no'?String(serial):key==='received_at'?date(row[key]):key==='supplier_name'&&!namesAllowed?'-':label(row[key]));
  });
  return{boxNumber:clean(data.box.box_number),customer:label(namesAllowed?data.box.customer_name||data.box.customer_code:data.box.customer_code),validCount:rows.length,issueCount:0,rows,heads:columns.map(c=>c[0])};
 }
 async function create(data,options={}){
  const report=prepare(data,options),lib=options.PDFLib||await library(),pdf=await lib.PDFDocument.create(),font=await pdf.embedFont(lib.StandardFonts.Helvetica),bold=await pdf.embedFont(lib.StandardFonts.HelveticaBold);
  let bytes=options.logo;if(!bytes){const response=await fetch('assets/greenloop-fzc-logo.jpg');if(!response.ok)throw Error('The Greenloop logo could not load. Retry printing.');bytes=await response.arrayBuffer();}const logoBytes=new Uint8Array(bytes),logoType=logoBytes[0]===137?'image/png':'image/jpeg',logo=logoType==='image/png'?await pdf.embedPng(logoBytes):await pdf.embedJpg(logoBytes);
  const colors={ink:lib.rgb(.07,.13,.17),green:lib.rgb(0,.40,.29),muted:lib.rgb(.30,.37,.41),line:lib.rgb(.70,.76,.80),heading:lib.rgb(.91,.94,.96),pale:lib.rgb(.97,.98,.98),white:lib.rgb(1,1,1)};
  const widths=columns.map(c=>BODY*c[2]/columns.reduce((n,c)=>n+c[2],0));
  const measure=(v,n,face=font)=>{try{return face.widthOfTextAtSize(v,n)}catch(_){throw Error('A report detail contains an unsupported character. No data was left out.');}};
  function wrap(value,width,size,face=font){const result=[];let line='';for(const word of value.split(' ')){if(line&&measure(line+' '+word,size,face)>width){result.push(line);line='';}let part='';for(const c of word){if(part&&measure(part+c,size,face)>width){if(line){result.push(line);line='';}result.push(part);part='';}part+=c;}line+=(line?' ':'')+part;}if(line)result.push(line);return result.length?result:[''];}
  const tableTop=H-96,headHeight=25,bottom=M+23,capacity=tableTop-headHeight-bottom;
  let measured,size;
  // Fit complete cells and complete rows, never hide a column or crop text.
  for(size=6.4;size>=5.99;size-=.2){measured=report.rows.map(cells=>{const lines=cells.map((v,i)=>wrap(v,widths[i]-4,size,i===1?bold:font));return{lines,height:Math.max(size+1,...lines.map(v=>v.length*(size)+1))};});if(measured.reduce((n,r)=>n+r.height,0)<=capacity+.01)break;}
  if(size<5.99)throw Error('These full box details exceed one readable A4 portrait page. No columns or phones were omitted.');
  const used=measured.reduce((n,r)=>n+r.height,0),rowExtra=Math.min(1.4,(capacity-used)/measured.length);for(const r of measured)r.height+=rowExtra;
  pdf.setTitle('Greenloop Stock Exported - '+report.boxNumber);pdf.setAuthor('Greenloop FZC');pdf.setSubject('Full Stock Exported details | A4 Portrait');pdf.catalog.getOrCreateViewerPreferences().setPrintScaling(lib.PrintScaling.None);pdf.catalog.getOrCreateViewerPreferences().setPickTrayByPDFSize(true);
  const page=pdf.addPage([W,H]),ops=[],drawn=[];
  function text(value,x,y,n,width,face=font,color=colors.ink,align='left'){
   const length=measure(value,n,face);if(length>width+.05||x<M-.1||y<M-.1||x+width>W-M+.1||y+n>H-M+.1)throw Error('A detail exceeds the print margins. No data was clipped.');
   if(align==='center')x+=(width-length)/2;if(align==='right')x+=width-length;page.drawText(value,{x,y,size:n,font:face,color});ops.push({kind:'text',text:value,x,y,size:n,bold:face===bold,color});drawn.push({text:value,x,y,size:n,width:length});
  }
  function rect(x,y,width,height,color){if(x<M-.1||y<M-.1||x+width>W-M+.1||y+height>H-M+.1)throw Error('A table cell exceeds the print margins.');page.drawRectangle({x,y,width,height,color,borderColor:colors.line,borderWidth:.4});ops.push({kind:'rect',x,y,width,height,color,border:colors.line});}
  function line(x,y,x2,y2,color=colors.line){page.drawLine({start:{x,y},end:{x:x2,y:y2},thickness:.5,color});ops.push({kind:'line',x,y,x2,y2,color});}
  function fitted(value,x,y,n,width,face=font,color=colors.ink,align='left'){const actual=Math.min(n,width/Math.max(measure(value,1,face),1));if(actual<5.6)throw Error('A heading is too long to fit this page clearly.');text(value,x,y,actual,width,face,color,align);}
  const crop={x:110,y:100,width:1080,height:230},brandWidth=140,scale=brandWidth/crop.width,brandHeight=crop.height*scale,brandY=H-M-brandHeight;
  page.pushOperators(lib.pushGraphicsState(),lib.rectangle(M,brandY,brandWidth,brandHeight),lib.clip(),lib.endPath());page.drawImage(logo,{x:M-crop.x*scale,y:brandY-(427-crop.y-crop.height)*scale,width:1280*scale,height:427*scale});page.pushOperators(lib.popGraphicsState());ops.push({kind:'brand',x:M,y:brandY,width:brandWidth,height:brandHeight,crop});
  fitted(report.boxNumber,W-M-280,H-M-15,14,280,bold,colors.green,'right');text('STOCK EXPORTED',M,H-74,10.5,BODY/2,bold);
  fitted('Customer: '+report.customer,M+BODY/2,H-59,8,BODY/2,font,colors.muted,'right');text('TOTAL PHONES: '+report.validCount,M+BODY/2,H-74,8.5,BODY/2,bold,colors.green,'right');line(M,H-86,W-M,H-86,colors.green);
  let top=tableTop,x=M;report.heads.forEach((h,i)=>{rect(x,top-headHeight,widths[i],headHeight,colors.heading);const parts=wrap(h,widths[i]-4,6,bold),baseline=top-(headHeight-(parts.length*6.5))/2-6;for(let j=0;j<parts.length;j++)text(parts[j],x+2,baseline-j*6.5,6,widths[i]-4,bold,colors.ink,'center');x+=widths[i];});top-=headHeight;
  measured.forEach((row,ri)=>{x=M;row.lines.forEach((parts,i)=>{rect(x,top-row.height,widths[i],row.height,ri%2?colors.pale:colors.white);const height=size+(parts.length-1)*(size),baseline=top-(row.height-height)/2-size;parts.forEach((value,j)=>text(value,x+2,baseline-j*(size),size,widths[i]-4,i===1?bold:font,colors.ink,'center'));x+=widths[i];});top-=row.height;});
  line(M,M+15,W-M,M+15);text('Total: '+report.validCount+' phones',M,M+2,7.5,180,bold,colors.green);text('A4 Portrait | Page 1 of 1',M+140,M+2,6.5,BODY-330,font,colors.muted,'center');text('Checked by: Quality Control Team',W-M-190,M+2,6.8,190,font,colors.muted,'right');
  return{bytes:await pdf.save(),previewPages:[{width:W,height:H,ops}],drawn,pages:1,report,title:'Stock Exported print preview',paperLabel:'A4 Portrait',orientation:'portrait',width:W,height:H,margin:M,filename:'Greenloop-Stock-Exported-'+report.boxNumber.replace(/[^a-z0-9_-]/gi,'-')+'.pdf',logoBytes,logoType};
 }
 root.GREENLOOP_STOCK_EXPORTED_PDF={create,prepare};if(typeof module!=='undefined'&&module.exports)module.exports=root.GREENLOOP_STOCK_EXPORTED_PDF;
})(typeof window!=='undefined'?window:globalThis);
