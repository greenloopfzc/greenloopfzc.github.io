(function (root) {
  'use strict';
  const labels = ['S.No', 'IMEI', 'Model', 'GB', 'Color', 'Grade', 'Stock / Batch', 'Required parts', 'Services / work required'];
  const pageWidth = 841.89, margin = 32, columnWidths = [28,92,62,36,50,40,135,150,184.89];
  const heading = report => report.issuance ? 'Lab & Glass Issuance' : 'Initial QC Handover';
  const date = value => new Intl.DateTimeFormat('en-GB', {timeZone:'Asia/Dubai', day:'2-digit', month:'short', year:'numeric'}).format(new Date(value)) + ' UAE';
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function validate(input) {
    if (!input?.rows?.length) throw new Error('Load saved inspections and choose a technician before generating the sheet.');
    const groups = new Map(), seen = new Set();
    for (const row of input.rows) {
      if (!row.jobId || seen.has(row.jobId) || !/^\d{15}$/.test(row.imei) || !Array.isArray(row.parts) || !Array.isArray(row.services)) throw new Error('The saved handover entries could not be verified. No sheet was generated.');
      seen.add(row.jobId);
      const key = row.technicianId || '', group = groups.get(key) || {name:row.technician || 'Unassigned', count:0};
      group.count++; groups.set(key, group);
    }
    if (groups.size > 1) throw new Error('This list contains different technicians: ' + [...groups.values()].map(g => `${g.name} - ${g.count} ${g.count === 1 ? 'phone' : 'phones'}`).join(', ') + '. Please check the technician assignments before generating the sheet.');
    if (groups.has('')) throw new Error('This list contains phones without an assigned technician. Please check the technician assignments before generating the sheet.');
    return {phase:input.rows.every(r=>r.issued)?'Issued':input.rows.some(r=>r.issued)?'Prepared and issued phones':'Before issuance',issuance:input.source === 'qc_issuance', technician:[...groups.values()][0].name, total:input.rows.length, generatedAt:input.generatedAt || new Date().toISOString(), rows:input.rows};
  }
  const values = (row, i) => [String(i + 1), row.imei, row.model || '-', row.storage || '-', row.color || '-', row.grade || '-', row.batch || 'Not recorded', row.parts.length ? row.parts.map(p => `${p.name} x ${p.quantity}`).join('\n') : 'None', row.services.length ? row.services.join('\n') : 'None'];

  const compactWidths=[18,64,30,22,33,24,85,130,125],compactW=595.276,compactH=841.89,compactM=32;
  function compactPlan(input,measure){
    const report=validate(input),pages=[];
    function wrap(value,width,size){const lines=[];for(const para of String(value??'').replace(/[\u2010-\u2015]/g,'-').split('\n')){let line='';for(const ch of para){if(line&&measure(line+ch,size)>width){lines.push(line);line='';}line+=ch;}lines.push(line);}return lines;}
    for(let start=0;start<report.rows.length;start+=50){const rows=report.rows.slice(start,start+50),height=Math.min(26,(compactH-97-18-52-14)/rows.length);pages.push({start,height,rows:rows.map((row,i)=>values(row,start+i).map((value,col)=>{let size=7,lines;do{lines=wrap(String(value).replace(/\n/g,'; '),compactWidths[col]-4,size);if(lines.length*size*1.12<=height-3)break;size-=.1;}while(size>.5);return {size,lines};}))});}
    return {report,pages};
  }
  function compactPrintHtml(input,options){
    const ctx=root.document?.createElement('canvas').getContext('2d'),measure=(s,n)=>{if(ctx){ctx.font=n+'pt Arial';return ctx.measureText(s).width*.75;}return String(s).length*n*.56;},plan=compactPlan(input,measure),r=plan.report;
    return '<!doctype html><html><head><meta charset="utf-8"><title>Lab &amp; Glass Issuance</title><style>@page{size:A4 portrait;margin:32pt}*{box-sizing:border-box}html,body{margin:0;padding:0;font-family:Arial,sans-serif;color:#17343a;-webkit-print-color-adjust:exact;print-color-adjust:exact}.sheet{width:531.276pt;break-after:page;page-break-after:always}.sheet:last-child{break-after:auto;page-break-after:auto}header{height:65pt;position:relative;text-align:center}header img{position:absolute;left:0;top:0;width:100pt;height:24pt;object-fit:cover;object-position:center}header h1{font-size:13pt;margin:0;padding-top:27pt}header p{font-size:7pt;margin:4pt 0}table{border-collapse:collapse;table-layout:fixed;width:100%}th,td{border:.35pt solid #bdced1;text-align:center;vertical-align:middle;padding:0 2pt;overflow-wrap:anywhere}thead th{height:18pt;background:#e5f1eb;font-size:6pt}td div{white-space:pre;line-height:1.12}tbody tr:nth-child(even){background:#f2f7f5}tfoot td{height:14pt;background:#e5f1eb;font-size:7pt;font-weight:bold}footer{font-size:6pt;padding-top:8pt;display:flex;justify-content:space-between}</style></head><body>'+plan.pages.map((p,i)=>'<section class="sheet"><header>'+(options.logoUrl?'<img src="'+escape(options.logoUrl)+'" alt="Greenloop FZC">':'<b style="position:absolute;left:0;top:0;font-size:15pt;color:#087651">GREENLOOP FZC</b>')+'<h1>Lab &amp; Glass Issuance</h1><p>Technician: <b>'+escape(r.technician)+'</b> | Total phones: '+r.total+' | '+escape(date(r.generatedAt))+'</p></header><table><colgroup>'+compactWidths.map(w=>'<col style="width:'+w+'pt">').join('')+'</colgroup><thead><tr>'+labels.map(v=>'<th>'+escape(v)+'</th>').join('')+'</tr></thead><tbody>'+p.rows.map(cells=>'<tr style="height:'+p.height+'pt">'+cells.map(cell=>'<td><div style="font-size:'+cell.size+'pt">'+cell.lines.map(escape).join('\n')+'</div></td>').join('')+'</tr>').join('')+'</tbody><tfoot><tr><td colspan="8">PHONES ON THIS PAGE</td><td>'+p.rows.length+'</td></tr></tfoot></table><footer><span>'+escape(r.phase)+' | S.No '+(p.start+1)+'-'+(p.start+p.rows.length)+'</span><span>Page '+(i+1)+' of '+plan.pages.length+'</span></footer></section>').join('')+'</body></html>';
  }
  async function compactCreate(input,options){
    const lib=options.PDFLib||root.PDFLib;if(!lib)throw Error('PDF tools could not load.');
    const doc=await lib.PDFDocument.create(),font=await doc.embedFont(lib.StandardFonts.Helvetica),bold=await doc.embedFont(lib.StandardFonts.HelveticaBold),clean=s=>String(s).replace(/[\u2010-\u2015]/g,'-'),measure=(s,n)=>font.widthOfTextAtSize(clean(s),n),plan=compactPlan(input,measure),r=plan.report,M=compactM,W=compactW,H=compactH;
    const ink=lib.rgb(.08,.18,.20),green=lib.rgb(0,.4,.29),line=lib.rgb(.73,.8,.81),pale=lib.rgb(.90,.95,.92);let logo;
    if(options.logo){const bytes=new Uint8Array(options.logo);logo=bytes[0]===137?await doc.embedPng(bytes):await doc.embedJpg(bytes);}
    doc.setTitle('Lab & Glass Issuance - '+r.technician);doc.setAuthor('Greenloop FZC');
    plan.pages.forEach((p,index)=>{const page=doc.addPage([W,H]),text=(s,x,y,n=7,face=font)=>page.drawText(clean(s),{x,y,size:n,font:face,color:ink}),center=(s,x,y,w,n=7,face=font)=>text(s,x+(w-face.widthOfTextAtSize(clean(s),n))/2,y,n,face);
      if(logo){const scale=100/1080,base=H-M-22;page.pushOperators(lib.pushGraphicsState(),lib.rectangle(M,base,100,22),lib.clip(),lib.endPath());page.drawImage(logo,{x:M-110*scale,y:base-(427-100-230)*scale,width:1280*scale,height:427*scale});page.pushOperators(lib.popGraphicsState());}else text('GREENLOOP FZC',M,H-M-15,15,bold);
      center('Lab & Glass Issuance',M,H-M-39,W-2*M,13,bold);
      const meta='Technician: '+r.technician+' | Total phones: '+r.total+' | '+date(r.generatedAt),metaSize=Math.min(7,(W-2*M)/measure(meta,1));center(meta,M,H-M-54,W-2*M,metaSize);
      let y=H-97,x=M;labels.forEach((s,i)=>{page.drawRectangle({x,y:y-18,width:compactWidths[i],height:18,color:pale,borderColor:line,borderWidth:.35});center(s,x,y-11,compactWidths[i],Math.min(6,(compactWidths[i]-3)/bold.widthOfTextAtSize(s,1)),bold);x+=compactWidths[i];});y-=18;
      p.rows.forEach((cells,row)=>{x=M;cells.forEach((cell,col)=>{page.drawRectangle({x,y:y-p.height,width:compactWidths[col],height:p.height,color:row%2?lib.rgb(.95,.97,.96):lib.rgb(1,1,1),borderColor:line,borderWidth:.35});const top=y-(p.height-cell.lines.length*cell.size*1.12)/2-cell.size;cell.lines.forEach((s,j)=>center(s,x,top-j*cell.size*1.12,compactWidths[col],cell.size));x+=compactWidths[col];});y-=p.height;});
      page.drawRectangle({x:M,y:y-14,width:W-2*M,height:14,color:pale});center('PHONES ON THIS PAGE: '+p.rows.length,M,y-10,W-2*M,7,bold);text(r.phase+' | S.No '+(p.start+1)+'-'+(p.start+p.rows.length),M,y-28,6);const label='Page '+(index+1)+' of '+plan.pages.length;text(label,W-M-measure(label,6),y-28,6);
    });
    return {bytes:await doc.save(),pages:plan.pages.length,filename:'Greenloop-Lab-Glass-Issuance-'+r.technician.replace(/[^a-z0-9]+/gi,'-')+'.pdf'};
  }

  function printHtml(input, options = {}) {
    if(input?.source==='qc_issuance')return compactPrintHtml(input,options);
    const report = validate(input), logoUrl = options.logoUrl || 'assets/greenloop-fzc-logo.jpg';
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' + escape(heading(report)) + ' - ' + escape(report.technician) + '</title><style>' +
      '@page{size:A4 landscape;margin:11.289mm}*{box-sizing:border-box}body{font:8.5pt Arial,sans-serif;color:#142d34;margin:0;-webkit-print-color-adjust:exact;print-color-adjust:exact}html,body{width:100%;max-width:100%}table{border-collapse:collapse;width:100%;table-layout:fixed}thead{display:table-header-group}th,td{border:0.5pt solid #beced2;padding:4.5pt;text-align:center;vertical-align:middle;overflow-wrap:anywhere;white-space:pre-line;line-height:1.25}tbody tr{break-inside:avoid;page-break-inside:avoid}thead .heading th{border:0;padding:0 0 10pt;background:white;font-weight:normal;white-space:normal}.brand-row{display:flex;align-items:center;justify-content:space-between;gap:16pt}.brand{flex:none;position:relative;overflow:hidden;width:160pt;height:34.074pt}.brand img{position:absolute;width:189.63pt;height:63.259pt;max-width:none;left:-16.296pt;top:-14.815pt}.document-type{min-width:0;text-align:right;overflow-wrap:anywhere;font-size:8pt;font-weight:bold;letter-spacing:1pt;color:#006d50}.title-row{display:flex;justify-content:space-between;align-items:baseline;gap:16pt;margin:13pt 0 10pt;padding-bottom:10pt;border-bottom:1pt solid #bacdce}.title{min-width:0;overflow-wrap:anywhere;font-size:16pt;font-weight:bold;margin:0}.meta{flex:none;max-width:45%;overflow-wrap:anywhere;font-size:8pt;color:#50666b;text-align:right}.summary{display:flex;gap:8pt}.summary-card{border:0.5pt solid #c0d0d4;background:#f7faf9;padding:9pt 11pt}.technician{flex:1;min-width:0}.summary-label{display:block;font-size:8pt;font-weight:bold;color:#50666b;letter-spacing:.4pt;margin-bottom:6pt}.technician-name{font-size:11pt;font-weight:bold;color:#173d35;overflow-wrap:anywhere}.phone-total{width:30%;background:#e6f2eb}.phone-total strong{font-size:18pt;color:#006d50}.columns th{background:#e5f1eb;color:#173d35;font-size:8pt;font-weight:bold;vertical-align:middle;border-bottom:1pt solid #087451}tbody tr:nth-child(even){background:#f3f7f7}.total td{font-weight:bold;background:#e5f1eb;padding:9pt}.total td:last-child{text-align:right;color:#006d50}tfoot td{border:0;padding:10pt 0 0;font-size:7.5pt;color:#50666b}</style></head><body>' +
      '<table><colgroup>' + columnWidths.map(width => '<col style="width:' + (100*width/(pageWidth-2*margin)).toFixed(6) + '%">').join('') + '</colgroup><thead><tr class="heading"><th colspan="9"><div class="brand-row"><div class="brand"><img src="' + escape(logoUrl) + '" alt="Greenloop FZC"></div><span class="document-type">' + (report.issuance ? 'LAB &amp; GLASS / HANDOVER' : 'INITIAL QC / HANDOVER') + '</span></div><div class="title-row"><h1 class="title">' + escape(heading(report)) + '</h1><span class="meta">Prepared: ' + escape(date(report.generatedAt)) + '</span></div><div class="summary"><div class="summary-card technician"><span class="summary-label">TECHNICIAN</span><span class="technician-name">' + escape(report.technician) + '</span></div><div class="summary-card phone-total"><span class="summary-label">TOTAL PHONES</span><strong>' + report.total + '</strong></div></div></th></tr><tr class="columns">' + labels.map(l => '<th>' + escape(l) + '</th>').join('') + '</tr></thead><tbody>' +
      report.rows.map((r, i) => '<tr>' + values(r, i).map(v => '<td>' + escape(v) + '</td>').join('') + '</tr>').join('') + '<tr class="total"><td colspan="8">TOTAL PHONES</td><td>' + report.total + '</td></tr></tbody><tfoot><tr><td colspan="9">Greenloop FZC - ' + escape(heading(report)) + ' technician handover. Prepared from saved inspections and confirmed transfers in this page session.</td></tr></tfoot></table></body></html>';
  }
  async function create(input, options = {}) {
    if(input?.source==='qc_issuance')return compactCreate(input,options);
    const report = validate(input), lib = options.PDFLib || root.PDFLib;
    if (!lib) throw new Error('PDF tools could not load. Please try again.');
    const pdf = await lib.PDFDocument.create(), regular = await pdf.embedFont(lib.StandardFonts.Helvetica), bold = await pdf.embedFont(lib.StandardFonts.HelveticaBold);
    pdf.setTitle(heading(report) + ' - ' + report.technician); pdf.setAuthor('Greenloop FZC');
    const W = pageWidth, H = 595.276, M = margin, widths = columnWidths, size = 8.5, leading = 11, bottom = 44;
    const ink = lib.rgb(.08,.18,.20), green = lib.rgb(0,.40,.29), muted = lib.rgb(.30,.40,.43), line = lib.rgb(.73,.80,.81), pale = lib.rgb(.95,.97,.96), white = lib.rgb(1,1,1);
    function text(value) {
      const s = String(value ?? '').replace(/[\u2010-\u2015]/g, '-').replace(/\r/g, '').replace(/\t/g, ' ');
      try { regular.encodeText(s.replace(/\n/g, '')); } catch (_) { throw new Error('A saved name contains characters the PDF font cannot display. Use Print for this sheet. No phones were omitted.'); }
      return s;
    }
    function wrap(value, width, face = regular, fontSize = size) {
      const lines = [];
      for (const paragraph of text(value).split('\n')) {
        let row = '';
        for (const word of paragraph.split(/ +/)) {
          const candidate = row ? row + ' ' + word : word;
          if (face.widthOfTextAtSize(candidate, fontSize) <= width) { row = candidate; continue; }
          if (row) { lines.push(row); row = ''; }
          for (const c of word) { if (row && face.widthOfTextAtSize(row + c, fontSize) > width) { lines.push(row); row = ''; } row += c; }
        }
        lines.push(row);
      }
      return lines;
    }
    const technicianWidth=355, nameLines=wrap(report.technician,technicianWidth-22,bold,11), metaHeight=Math.max(49,27+nameLines.length*14), tableTop=H-110-metaHeight-14;
    let logo=null;if(options.logo){const bytes=new Uint8Array(options.logo);logo=bytes[0]===137?await pdf.embedPng(bytes):await pdf.embedJpg(bytes);}
    if (tableTop < 180) throw new Error('The technician name is too long for the PDF heading. Use Print for this sheet.');
    const prepared = report.rows.map((r, i) => values(r, i).map((v, col) => wrap(v, widths[col] - 12)));
    let page, y;
    const draw = (s,x,py,fontSize=size,face=regular,color=ink) => page.drawText(text(s), {x,y:py,size:fontSize,font:face,color});
    function newPage() {
      page = pdf.addPage([W,H]);
      if(logo){
        const crop={x:110,y:100,width:1080,height:230},scale=160/crop.width,height=crop.height*scale,base=H-55;
        page.pushOperators(lib.pushGraphicsState(),lib.rectangle(M,base,160,height),lib.clip(),lib.endPath());
        page.drawImage(logo,{x:M-crop.x*scale,y:base-(427-crop.y-crop.height)*scale,width:1280*scale,height:427*scale});page.pushOperators(lib.popGraphicsState());
      }else draw('GREENLOOP FZC',M,H-47,24,bold,green);
      const type=report.issuance?'LAB & GLASS / HANDOVER':'INITIAL QC / HANDOVER';draw(type,W-M-bold.widthOfTextAtSize(type,8),H-38,8,bold,green);
      draw(heading(report),M,H-80,16,bold);
      const stamp='Prepared: '+date(report.generatedAt);draw(stamp,W-M-regular.widthOfTextAtSize(stamp,8),H-80,8,regular,muted);
      page.drawLine({start:{x:M,y:H-94},end:{x:W-M,y:H-94},thickness:.75,color:line});
      const top=H-106, gap=8, countX=M+technicianWidth+gap,countWidth=W-2*M-technicianWidth-gap;
      page.drawRectangle({x:M,y:top-metaHeight,width:technicianWidth,height:metaHeight,color:lib.rgb(.97,.98,.98),borderColor:line,borderWidth:.5});
      page.drawRectangle({x:countX,y:top-metaHeight,width:countWidth,height:metaHeight,color:lib.rgb(.90,.95,.92),borderColor:line,borderWidth:.5});
      draw('TECHNICIAN',M+11,top-15,8,bold,muted);nameLines.forEach((s,i)=>draw(s,M+11,top-32-i*14,11,bold,ink));
      draw('TOTAL PHONES',countX+11,top-15,8,bold,muted);draw(String(report.total),countX+11,top-37,18,bold,green);
      page.drawRectangle({x:M,y:tableTop-24,width:W-2*M,height:24,color:lib.rgb(.90,.95,.92),borderColor:line,borderWidth:.5});
      page.drawLine({start:{x:M,y:tableTop-24},end:{x:W-M,y:tableTop-24},thickness:.8,color:green});
      let x = M; labels.forEach((label,i) => { draw(label,x+(widths[i]-bold.widthOfTextAtSize(label,8))/2,tableTop-15,8,bold,ink); x += widths[i]; }); y = tableTop-24;
    }
    function row(cells, index, continued = false) {
      const height = Math.max(28, Math.max(...cells.map(a => a.length))*leading+12);
      page.drawRectangle({x:M,y:y-height,width:W-2*M,height,color:index%2 ? pale:white,borderColor:line,borderWidth:.5});
      let x = M;
      cells.forEach((lines,col) => { if(col)page.drawLine({start:{x,y},end:{x,y:y-height},thickness:.4,color:line});lines.forEach((s,i)=>draw(s,x+(widths[col]-(col===1?bold:regular).widthOfTextAtSize(s,size))/2,y-(height-lines.length*leading)/2-size-i*leading,size,col===1?bold:regular));x += widths[col]; });
      y -= height;
    }
    newPage();
    for (let index=0; index<prepared.length; index++) {
      const cells = prepared[index], height = Math.max(28,Math.max(...cells.map(a=>a.length))*leading+12), fresh = tableTop-24-bottom;
      const reserve = index===prepared.length-1 ? 28 : 0;
      if (height <= fresh) { if(y-height-reserve<bottom && height+reserve<=fresh)newPage();else if(y-height<bottom)newPage();row(cells,index);continue; }
      let offset = 0; const count = Math.max(...cells.map(a=>a.length));
      while(offset<count) {
        if(y-45-reserve<bottom)newPage();
        const capacity = Math.floor((y-bottom-12-reserve)/leading), chunk = cells.map((a,col)=>col<2 ? a : a.slice(offset,offset+capacity));
        if(offset)chunk[1]=[...cells[1],'(continued)'];
        const required = Math.max(...chunk.map(a=>a.length))*leading+12;
        if(required>y-bottom){newPage();continue;}
        row(chunk,index,offset>0);offset+=capacity;if(offset<count)newPage();
      }
    }
    if(y-28<bottom)newPage();
    page.drawRectangle({x:M,y:y-28,width:W-2*M,height:28,color:lib.rgb(.88,.94,.90)});draw('TOTAL PHONES',M+8,y-18,9,bold,green);const totalText=String(report.total);draw(totalText,W-M-8-bold.widthOfTextAtSize(totalText,12),y-19,12,bold,green);
    const pages = pdf.getPages();pages.forEach((p,i)=>{page=p;draw((options.sample?'SAMPLE - FICTIONAL DATA | ':'')+heading(report)+(report.issuance?' - '+report.phase:''),M,23,8,regular,muted);const s=`Page ${i+1} of ${pages.length}`;draw(s,W-M-regular.widthOfTextAtSize(s,8),23,8,regular,muted);});
    const day = new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(report.generatedAt)).replace(/[^0-9-]/g,'-');
    return {bytes:await pdf.save(), pages:pages.length, filename:'Greenloop-'+(report.issuance?'Lab-Glass-Issuance':'Initial-QC-Handover')+'-'+report.technician.replace(/[^a-z0-9]+/gi,'-')+'-'+day+'.pdf'};
  }
  root.GREENLOOP_QC_HANDOVER_PDF = {version:'20261112-issuance-50-per-sheet-1',validate, create, printHtml};
})(typeof window !== 'undefined' ? window : globalThis);
