(function(root){
 'use strict';
 async function create(report,options={}){
  const lib=options.PDFLib||root.PDFLib;if(!lib)throw new Error('PDF tools could not load. Please retry.');
  if(!report||!Array.isArray(report.rows)||!report.stats||report.total!==report.rows.length)throw new Error('The complete stock report could not be verified. Narrow the filters and retry.');
  const pdf=await lib.PDFDocument.create(),regular=await pdf.embedFont(lib.StandardFonts.Helvetica),bold=await pdf.embedFont(lib.StandardFonts.HelveticaBold);
  pdf.setTitle('Daily Production - '+options.title);pdf.setAuthor('Greenloop FZC');
  const W=595.276,H=841.89,M=30,widths=[180,48,56,70,70,60,51.276],size=9,lineHeight=12;
  const c={ink:lib.rgb(.08,.16,.20),green:lib.rgb(0,.4,.3),line:lib.rgb(.72,.79,.81),pale:lib.rgb(.93,.96,.95),white:lib.rgb(1,1,1),muted:lib.rgb(.3,.38,.42)};
  const fmt=v=>Number(v||0).toLocaleString('en-GB'),day=v=>new Intl.DateTimeFormat('en-GB',{day:'2-digit',month:'short',year:'numeric',timeZone:'UTC'}).format(new Date(v+'T12:00:00Z'));
  function text(v){const s=String(v??'').replace(/[\r\n\t]+/g,' ').trim();try{regular.encodeText(s);}catch{throw new Error('A saved name contains characters this PDF font cannot display. Use Latin characters in Model, GB and Grade names. No rows were omitted.');}return s;}
  function wrap(value,width,face=regular,fontSize=size){let lines=[],line='';for(const word of text(value).split(' ')){let candidate=(line?line+' ':'')+word;if(face.widthOfTextAtSize(candidate,fontSize)<=width){line=candidate;continue;}if(line){lines.push(line);line='';}for(const ch of word){if(line&&face.widthOfTextAtSize(line+ch,fontSize)>width){lines.push(line);line='';}line+=ch;}}if(line||!lines.length)lines.push(line);return lines;}
  const prepared=report.rows.map(r=>[r.model,r.gb,r.grade,fmt(r.previous),fmt(r.quantity),fmt(r.production),fmt(r.stock_out)].map((s,i)=>wrap(s,widths[i]-12)));
  let logo=null;if(options.logo)logo=await pdf.embedJpg(options.logo);
  let page,y,ops;const previewPages=[],title=text(options.title||'Total Stock');
  const subtitle=`${day(report.date)} | UAE (UTC+4)`;
  function draw(value,x,top,fontSize=size,face=regular,color=c.ink){const str=text(value);page.drawText(str,{x,y:top-fontSize,size:fontSize,font:face,color});ops.push({kind:'text',text:str,x,y:top-fontSize,size:fontSize,bold:face===bold,color});}
  function row(cells,isHeader=false,isTotal=false){const height=Math.max(...cells.map(x=>x.length))*lineHeight+14;if(height>H-220)throw new Error('A report row is too long for an A4 page. Shorten the saved name and retry.');if(y-height<48)newPage();let x=M;cells.forEach((lines,i)=>{const fill=isHeader||isTotal?c.pale:c.white;page.drawRectangle({x,y:y-height,width:widths[i],height,color:fill,borderColor:c.line,borderWidth:.45});ops.push({kind:'rect',x,y:y-height,width:widths[i],height,color:fill,border:c.line});lines.forEach((s,j)=>{const face=isHeader||isTotal?bold:regular;const right=i>=3&&!isHeader;const sx=right?x+widths[i]-6-face.widthOfTextAtSize(s,size):x+6;draw(s,sx,y-7-j*lineHeight,size,face,isTotal?c.green:c.ink);});x+=widths[i];});y-=height;}
  function newPage(){page=pdf.addPage([W,H]);ops=[];previewPages.push({width:W,height:H,ops});y=H-28;
   if(logo){const x=M,bottom=H-60,w=145,scale=w/1080,h=230*scale;page.pushOperators(lib.pushGraphicsState(),lib.rectangle(x,bottom,w,h),lib.clip(),lib.endPath());page.drawImage(logo,{x:x-110*scale,y:bottom-(427-100-230)*scale,width:1280*scale,height:427*scale});page.pushOperators(lib.popGraphicsState());ops.push({kind:'brand',x,y:bottom,width:w,height:h});}else draw('Greenloop FZC',M,H-28,15,bold,c.green);
   draw('Daily Production Report',M,H-76,15,bold);draw(subtitle,W-M-regular.widthOfTextAtSize(subtitle,9),H-79,9,regular,c.green);
   const heading=wrap(title,W-2*M,bold,11);heading.forEach((s,i)=>draw(s,M,H-101-i*14,11,bold));y=H-125-(heading.length-1)*14;
   if(options.query){const lines=wrap('Search: '+options.query,W-2*M,regular,9);lines.forEach((s,i)=>draw(s,M,y-i*12,9,regular,c.muted));y-=lines.length*12+8;}
   row(['Model','GB','Grade','Previous closing',report.date===report.today?'Current stock':'Closing stock','Production','Out'].map((s,i)=>wrap(s,widths[i]-12,bold)),true);
  }
  newPage();for(const cells of prepared)row(cells);
  if(!prepared.length)row(['No matching stock records','','','','','',''].map((s,i)=>wrap(s,widths[i]-12)));
  row(['Total','','',fmt(report.stats.previous),fmt(report.stats.quantity),fmt(report.stats.production),fmt(report.stats.stock_out)].map((s,i)=>wrap(s,widths[i]-12,bold)),false,true);
  const pages=pdf.getPages();pages.forEach((p,i)=>{page=p;ops=previewPages[i].ops;draw('Independent manual stock | Quantities in pcs',M,31,8,regular,c.muted);const label=`Page ${i+1} of ${pages.length}`;draw(label,W-M-regular.widthOfTextAtSize(label,8),31,8,regular,c.muted);});
  return {bytes:await pdf.save(),pages:pages.length,previewPages,filename:`Greenloop-Daily-Production-${title.replace(/[^a-z0-9]+/gi,'-')}-${report.date}.pdf`};
 }
 root.GREENLOOP_PRODUCTION_PDF={create};
})(typeof window!=='undefined'?window:globalThis);
