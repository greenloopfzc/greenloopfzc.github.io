(function (root) {
  'use strict';
  const labels = ['#', 'IMEI', 'Model', 'GB', 'Color', 'Required parts', 'Services / work required'];
  const date = value => new Intl.DateTimeFormat('en-GB', {timeZone:'Asia/Dubai', day:'2-digit', month:'short', year:'numeric', hour:'2-digit', minute:'2-digit', hour12:false}).format(new Date(value)) + ' UAE';
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function validate(input) {
    if (!input?.rows?.length) throw new Error('No phones have been saved in this page session. Save Initial QC entries before generating the sheet.');
    const groups = new Map(), seen = new Set();
    for (const row of input.rows) {
      if (!row.jobId || seen.has(row.jobId) || !/^\d{15}$/.test(row.imei) || !Array.isArray(row.parts) || !Array.isArray(row.services)) throw new Error('The saved handover entries could not be verified. No sheet was generated.');
      seen.add(row.jobId);
      const key = row.technicianId || '', group = groups.get(key) || {name:row.technician || 'Unassigned', count:0};
      group.count++; groups.set(key, group);
    }
    if (groups.size > 1) throw new Error('This list contains different technicians: ' + [...groups.values()].map(g => `${g.name} - ${g.count} ${g.count === 1 ? 'phone' : 'phones'}`).join(', ') + '. Please check the technician assignments before generating the sheet.');
    if (groups.has('')) throw new Error('This list contains phones without an assigned technician. Please check the technician assignments before generating the sheet.');
    return {technician:[...groups.values()][0].name, total:input.rows.length, generatedAt:input.generatedAt || new Date().toISOString(), rows:input.rows};
  }
  const values = (row, i) => [String(i + 1), row.imei, row.model || '-', row.storage || '-', row.color || '-', row.parts.length ? row.parts.map(p => `${p.name} x ${p.quantity}`).join('\n') : 'None', row.services.length ? row.services.join('\n') : 'None'];
  function printHtml(input, options = {}) {
    const report = validate(input), logoUrl = options.logoUrl || 'assets/greenloop-fzc-logo.jpg';
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Initial QC Handover - ' + escape(report.technician) + '</title><style>' +
      '@page{size:A4 portrait;margin:10mm}*{box-sizing:border-box}body{font:8.5pt Arial,sans-serif;color:#142d34;margin:0;-webkit-print-color-adjust:exact;print-color-adjust:exact}table{border-collapse:collapse;width:100%;table-layout:fixed}thead{display:table-header-group}th,td{border:0.5pt solid #beced2;padding:6pt;text-align:left;vertical-align:top;overflow-wrap:anywhere;white-space:pre-line;line-height:1.3}tbody tr{break-inside:avoid;page-break-inside:avoid}thead .heading th{border:0;padding:0 0 10pt;background:white;font-weight:normal;white-space:normal}.brand-row{display:flex;align-items:center;justify-content:space-between;gap:16pt}.brand{position:relative;overflow:hidden;width:160pt;height:34.074pt}.brand img{position:absolute;width:189.63pt;height:63.259pt;max-width:none;left:-16.296pt;top:-14.815pt}.document-type{font-size:8pt;font-weight:bold;letter-spacing:1pt;color:#006d50}.title-row{display:flex;justify-content:space-between;align-items:baseline;gap:16pt;margin:13pt 0 10pt;padding-bottom:10pt;border-bottom:1pt solid #bacdce}.title{font-size:16pt;font-weight:bold;margin:0}.meta{font-size:8pt;color:#50666b;text-align:right}.summary{display:flex;gap:8pt}.summary-card{border:0.5pt solid #c0d0d4;background:#f7faf9;padding:9pt 11pt}.technician{flex:1;min-width:0}.summary-label{display:block;font-size:8pt;font-weight:bold;color:#50666b;letter-spacing:.4pt;margin-bottom:6pt}.technician-name{font-size:11pt;font-weight:bold;color:#173d35;overflow-wrap:anywhere}.phone-total{width:30%;background:#e6f2eb}.phone-total strong{font-size:18pt;color:#006d50}.columns th{background:#e5f1eb;color:#173d35;font-size:8pt;font-weight:bold;vertical-align:middle;border-bottom:1pt solid #087451}tbody tr:nth-child(even){background:#f3f7f7}.total td{font-weight:bold;background:#e5f1eb;padding:9pt}.total td:last-child{text-align:right;color:#006d50}tfoot td{border:0;padding:10pt 0 0;font-size:7.5pt;color:#50666b}col:nth-child(1){width:5.2%}col:nth-child(2){width:18.5%}col:nth-child(3){width:13%}col:nth-child(4){width:8.2%}col:nth-child(5){width:9.5%}col:nth-child(6){width:21.6%}col:nth-child(7){width:24%}</style></head><body>' +
      '<table><colgroup>' + labels.map(() => '<col>').join('') + '</colgroup><thead><tr class="heading"><th colspan="7"><div class="brand-row"><div class="brand"><img src="' + escape(logoUrl) + '" alt="Greenloop FZC"></div><span class="document-type">INITIAL QC / HANDOVER</span></div><div class="title-row"><h1 class="title">Initial QC Handover</h1><span class="meta">Prepared: ' + escape(date(report.generatedAt)) + '</span></div><div class="summary"><div class="summary-card technician"><span class="summary-label">TECHNICIAN</span><span class="technician-name">' + escape(report.technician) + '</span></div><div class="summary-card phone-total"><span class="summary-label">TOTAL PHONES</span><strong>' + report.total + '</strong></div></div></th></tr><tr class="columns">' + labels.map(l => '<th>' + escape(l) + '</th>').join('') + '</tr></thead><tbody>' +
      report.rows.map((r, i) => '<tr>' + values(r, i).map(v => '<td>' + escape(v) + '</td>').join('') + '</tr>').join('') + '<tr class="total"><td colspan="6">TOTAL PHONES</td><td>' + report.total + '</td></tr></tbody><tfoot><tr><td colspan="7">Greenloop FZC - Initial QC technician handover. Successfully saved entries from this page session.</td></tr></tfoot></table></body></html>';
  }
  async function create(input, options = {}) {
    const report = validate(input), lib = options.PDFLib || root.PDFLib;
    if (!lib) throw new Error('PDF tools could not load. Please try again.');
    const pdf = await lib.PDFDocument.create(), regular = await pdf.embedFont(lib.StandardFonts.Helvetica), bold = await pdf.embedFont(lib.StandardFonts.HelveticaBold);
    pdf.setTitle('Initial QC Handover - ' + report.technician); pdf.setAuthor('Greenloop FZC');
    const W = 595.276, H = 841.89, M = 28, widths = [28,100,70,44,51,117,129.276], size = 8.5, leading = 11, bottom = 44;
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
      const type='INITIAL QC / HANDOVER';draw(type,W-M-bold.widthOfTextAtSize(type,8),H-38,8,bold,green);
      draw('Initial QC Handover',M,H-80,16,bold);
      const stamp='Prepared: '+date(report.generatedAt);draw(stamp,W-M-regular.widthOfTextAtSize(stamp,8),H-80,8,regular,muted);
      page.drawLine({start:{x:M,y:H-94},end:{x:W-M,y:H-94},thickness:.75,color:line});
      const top=H-106, gap=8, countX=M+technicianWidth+gap,countWidth=W-2*M-technicianWidth-gap;
      page.drawRectangle({x:M,y:top-metaHeight,width:technicianWidth,height:metaHeight,color:lib.rgb(.97,.98,.98),borderColor:line,borderWidth:.5});
      page.drawRectangle({x:countX,y:top-metaHeight,width:countWidth,height:metaHeight,color:lib.rgb(.90,.95,.92),borderColor:line,borderWidth:.5});
      draw('TECHNICIAN',M+11,top-15,8,bold,muted);nameLines.forEach((s,i)=>draw(s,M+11,top-32-i*14,11,bold,ink));
      draw('TOTAL PHONES',countX+11,top-15,8,bold,muted);draw(String(report.total),countX+11,top-37,18,bold,green);
      page.drawRectangle({x:M,y:tableTop-24,width:W-2*M,height:24,color:lib.rgb(.90,.95,.92),borderColor:line,borderWidth:.5});
      page.drawLine({start:{x:M,y:tableTop-24},end:{x:W-M,y:tableTop-24},thickness:.8,color:green});
      let x = M; labels.forEach((label,i) => { draw(label,x+6,tableTop-15,8,bold,ink); x += widths[i]; }); y = tableTop-24;
    }
    function row(cells, index, continued = false) {
      const height = Math.max(28, Math.max(...cells.map(a => a.length))*leading+12);
      page.drawRectangle({x:M,y:y-height,width:W-2*M,height,color:index%2 ? pale:white,borderColor:line,borderWidth:.5});
      let x = M;
      cells.forEach((lines,col) => { if(col)page.drawLine({start:{x,y},end:{x,y:y-height},thickness:.4,color:line});lines.forEach((s,i)=>draw(s,x+6,y-12-i*leading,size,col===1?bold:regular));x += widths[col]; });
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
    const pages = pdf.getPages();pages.forEach((p,i)=>{page=p;draw(options.sample?'SAMPLE - FICTIONAL DATA | Initial QC handover':'Initial QC handover',M,23,8,regular,muted);const s=`Page ${i+1} of ${pages.length}`;draw(s,W-M-regular.widthOfTextAtSize(s,8),23,8,regular,muted);});
    const day = new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(report.generatedAt)).replace(/[^0-9-]/g,'-');
    return {bytes:await pdf.save(), pages:pages.length, filename:'Greenloop-Initial-QC-Handover-'+report.technician.replace(/[^a-z0-9]+/gi,'-')+'-'+day+'.pdf'};
  }
  root.GREENLOOP_QC_HANDOVER_PDF = {version:'20261030-qc-pdf-design-1',validate, create, printHtml};
})(typeof window !== 'undefined' ? window : globalThis);
