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
  function printHtml(input) {
    const report = validate(input);
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Initial QC Handover - ' + escape(report.technician) + '</title><style>' +
      '@page{size:A4 portrait;margin:10mm}*{box-sizing:border-box}body{font:12px Arial,sans-serif;color:#17343a;margin:0}table{border-collapse:collapse;width:100%;table-layout:fixed}thead{display:table-header-group}th,td{border:1px solid #bdcdce;padding:9px 7px;text-align:left;vertical-align:top;overflow-wrap:anywhere;white-space:pre-line}tr{break-inside:avoid;page-break-inside:avoid}thead .heading th{border:0;padding:0 0 16px;background:white;color:#17343a}.brand{font-size:14px;color:#006d50;letter-spacing:1px}.title{font-size:20px;margin:6px 0}.meta{font-size:11px;color:#50666b}.technician{font-size:23px;font-weight:bold;display:flex;justify-content:space-between;gap:20px;margin-top:15px}.technician small{font-size:15px;white-space:nowrap}thead .columns th{background:#006d50;color:white;font-size:11px}tbody tr:nth-child(even){background:#f2f7f5}.total{font-weight:bold;background:#e5f1eb}tfoot td{border:0;padding:12px 0;font-size:10px;color:#50666b}col:nth-child(1){width:5.5%}col:nth-child(2){width:18.5%}col:nth-child(3){width:13%}col:nth-child(4){width:8%}col:nth-child(5){width:9.5%}col:nth-child(6){width:21.5%}col:nth-child(7){width:24%}</style></head><body>' +
      '<table><colgroup>' + labels.map(() => '<col>').join('') + '</colgroup><thead><tr class="heading"><th colspan="7"><div class="brand">GREENLOOP FZC</div><div class="title">Initial QC Handover</div><div class="meta">Prepared: ' + escape(date(report.generatedAt)) + '</div><div class="technician"><span>Technician: ' + escape(report.technician) + '</span><small>Total phones: ' + report.total + '</small></div></th></tr><tr class="columns">' + labels.map(l => '<th>' + escape(l) + '</th>').join('') + '</tr></thead><tbody>' +
      report.rows.map((r, i) => '<tr>' + values(r, i).map(v => '<td>' + escape(v) + '</td>').join('') + '</tr>').join('') + '<tr class="total"><td colspan="6">Total phones</td><td>' + report.total + '</td></tr></tbody><tfoot><tr><td colspan="7">Successfully saved Initial QC entries from this page session.</td></tr></tfoot></table></body></html>';
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
    const nameLines = wrap('Technician: ' + report.technician, W - 2*M - 165, bold, 17), tableTop = H - 90 - (nameLines.length - 1)*20;
    if (tableTop < 180) throw new Error('The technician name is too long for the PDF heading. Use Print for this sheet.');
    const prepared = report.rows.map((r, i) => values(r, i).map((v, col) => wrap(v, widths[col] - 12)));
    let page, y;
    const draw = (s,x,py,fontSize=size,face=regular,color=ink) => page.drawText(text(s), {x,y:py,size:fontSize,font:face,color});
    function newPage() {
      page = pdf.addPage([W,H]);
      draw('GREENLOOP FZC', M, H-29, 10, bold, green); draw('Initial QC Handover', M, H-48, 15, bold);
      const stamp = 'Prepared: ' + date(report.generatedAt); draw(stamp, W-M-regular.widthOfTextAtSize(stamp,8), H-29, 8, regular, muted);
      nameLines.forEach((s,i) => draw(s, M, H-74-i*20, 17, bold, green));
      const total = 'Total phones: ' + report.total; draw(total, W-M-bold.widthOfTextAtSize(total,11), H-74, 11, bold);
      page.drawRectangle({x:M,y:tableTop-24,width:W-2*M,height:24,color:green});
      let x = M; labels.forEach((label,i) => { draw(label,x+6,tableTop-15,8,bold,white); x += widths[i]; }); y = tableTop-24;
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
    page.drawRectangle({x:M,y:y-28,width:W-2*M,height:28,color:lib.rgb(.88,.94,.90)});draw('Total phones: '+report.total,M+8,y-18,10,bold,green);
    const pages = pdf.getPages();pages.forEach((p,i)=>{page=p;draw('Initial QC handover',M,23,8,regular,muted);const s=`Page ${i+1} of ${pages.length}`;draw(s,W-M-regular.widthOfTextAtSize(s,8),23,8,regular,muted);});
    const day = new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dubai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(report.generatedAt)).replace(/[^0-9-]/g,'-');
    return {bytes:await pdf.save(), pages:pages.length, filename:'Greenloop-Initial-QC-Handover-'+report.technician.replace(/[^a-z0-9]+/gi,'-')+'-'+day+'.pdf'};
  }
  root.GREENLOOP_QC_HANDOVER_PDF = {validate, create, printHtml};
})(typeof window !== 'undefined' ? window : globalThis);
