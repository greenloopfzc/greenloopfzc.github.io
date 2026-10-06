/* Damage Report PDF: measured single-line cells, native vector text, A4 portrait. */
(function (root) {
  'use strict';
  const VERSION = '20261006-damage-report-pdf-1';
  const WIDTH = 595.276, HEIGHT = 841.89, MARGIN = 24, BODY = WIDTH - 2 * MARGIN;
  const labels = ['DATE / TIME', 'MODEL', 'PART NAME', 'QTY', 'PRICE / PART', 'PART SOURCE', 'REASON'];
  const clean = value => String(value == null || value === '' ? 'Not recorded' : value).replace(/\s+/g, ' ').trim();
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const two = value => String(value).padStart(2, '0');
  function dateLabel(value, time = false) {
    const date = new Date(time ? Date.parse(value) + 14400000 : value + 'T00:00:00Z');
    if (!Number.isFinite(date.getTime())) throw new Error('A damage entry has an invalid date. Refresh the report.');
    return `${two(date.getUTCDate())} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()}` + (time ? ` ${two(date.getUTCHours())}:${two(date.getUTCMinutes())}` : '');
  }
  function validDate(value) {
    return /^\d{4}-\d{2}-\d{2}$/.test(value || '') && value >= '2000-01-01' && value <= '2100-12-31' &&
      new Date(value + 'T00:00:00Z').toISOString().slice(0,10) === value;
  }
  function priceCents(value) {
    if (value === null || value === undefined) return null;
    if (!/^\d{1,8}(?:\.\d{1,2})?$/.test(String(value))) throw new Error('A saved price is invalid. Refresh the report.');
    const [whole, fraction = ''] = String(value).split('.');
    return BigInt(whole + fraction.padEnd(2, '0'));
  }
  function money(cents) {
    const amount = cents.toString().padStart(3, '0');
    return amount.slice(0,-2).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + '.' + amount.slice(-2);
  }
  function prepare(data) {
    if (!data || data.version !== VERSION || !validDate(data.date_from) || !validDate(data.date_to) || data.date_from > data.date_to ||
      !Array.isArray(data.rows) || !Array.isArray(data.employees) || data.rows.length !== data.record_count || data.rows.length > 2000) {
      throw new Error('The complete report could not be read. Refresh and try again.');
    }
    const employees = [], byKey = new Map(), seen = new Set(), totals = new Map();
    const add = (key, name) => {
      if (typeof key !== 'string' || !key || typeof name !== 'string' || !name.trim()) throw new Error('An employee record could not be read.');
      const employee = { key, name: clean(name), rows: [], quantity: 0, totals: new Map(), unpriced: 0 };
      employees.push(employee); byKey.set(key, employee); return employee;
    };
    for (const employee of data.employees) {
      if (byKey.has(employee.key)) throw new Error('The employee list contains a duplicate. Refresh the report.');
      add(employee.key, employee.name);
    }
    let quantity = 0, unpriced = 0;
    for (const row of data.rows) {
      if (!row || typeof row.id !== 'string' || !row.id || seen.has(row.id) || !Number.isInteger(row.quantity) || row.quantity < 1 || row.quantity > 99999) throw new Error('A damage entry is missing or duplicated. Refresh the report.');
      seen.add(row.id);
      const localDate = new Date(Date.parse(row.occurred_at) + 14400000);
      if (!Number.isFinite(localDate.getTime())) throw new Error('A saved date is invalid.');
      const day = localDate.toISOString().slice(0,10);
      if (day < data.date_from || day > data.date_to) throw new Error('An entry falls outside the selected UAE dates. Refresh the report.');
      let employee = byKey.get(row.employee_key);
      // Legacy records may predate the employee catalog. Match only one exact
      // normalized name; never merge two different catalog employee IDs.
      if (!employee && String(row.employee_key).startsWith('legacy:')) {
        const matches = employees.filter(e => e.name.toLocaleLowerCase() === clean(row.employee_name).toLocaleLowerCase());
        if (matches.length === 1) employee = matches[0];
      }
      if (!employee) employee = add(row.employee_key, row.employee_name);
      const cents = priceCents(row.price_amount);
      if (cents !== null && (typeof row.currency !== 'string' || !row.currency.trim())) throw new Error('A priced part is missing its currency.');
      const currency = row.currency ? clean(row.currency) : null;
      const cells = [dateLabel(row.occurred_at, true), clean(row.model), clean(row.part_name), String(row.quantity),
        cents === null ? 'Not recorded' : money(cents) + ' ' + currency, clean(row.part_source), clean(row.reason)];
      employee.rows.push({ id: row.id, timestamp: Date.parse(row.occurred_at), cells });
      employee.quantity += row.quantity; quantity += row.quantity;
      if (cents === null) { employee.unpriced += row.quantity; unpriced += row.quantity; }
      else {
        const value = cents * BigInt(row.quantity);
        employee.totals.set(currency, (employee.totals.get(currency) || 0n) + value);
        totals.set(currency, (totals.get(currency) || 0n) + value);
      }
    }
    for (const employee of employees) employee.rows.sort((a,b) => b.timestamp-a.timestamp || b.id.localeCompare(a.id));
    const currencies = ['AED','USD', ...Array.from(totals.keys()).filter(c => c !== 'AED' && c !== 'USD').sort()];
    return { from: data.date_from, to: data.date_to, generated: data.generated_at, employees, quantity, count: data.rows.length, unpriced,
      currencies, totals, active: employees.filter(e => e.rows.length), zero: employees.filter(e => !e.rows.length) };
  }
  async function create(data, options = {}) {
    const lib = options.PDFLib || root.PDFLib;
    if (!lib) throw new Error('PDF tools did not load. Please try again.');
    const report = prepare(data), pdf = await lib.PDFDocument.create();
    const font = await pdf.embedFont(lib.StandardFonts.Helvetica), bold = await pdf.embedFont(lib.StandardFonts.HelveticaBold);
    pdf.setTitle('Damage Report'); pdf.setAuthor('Greenloop FZC'); pdf.setSubject('Employee damage report | UAE incident dates');
    pdf.catalog.getOrCreateViewerPreferences().setPrintScaling(lib.PrintScaling.None);
    pdf.catalog.getOrCreateViewerPreferences().setPickTrayByPDFSize(true);
    function measure(text, size, face = font) {
      try { return face.widthOfTextAtSize(text, size); }
      catch (_) { throw new Error('The PDF cannot render a character in this report. Use standard Latin characters in the employee and dropdown names. No entries were omitted.'); }
    }
    const widthsAt = size => labels.map((label, index) => Math.max(measure(label, 8, bold),
      ...report.active.flatMap(e => e.rows.map(r => measure(r.cells[index], size))), 10) + 8);
    let size = 10.5, widths;
    for (; size >= 8.5; size -= 0.25) { widths = widthsAt(size); if (widths.reduce((a,b) => a+b,0) <= BODY) break; }
    if (size < 8.5) throw new Error('Some details are too long for a readable, single-line A4 table. Shorten the wording in Data Correction before exporting. Nothing has been cut off.');
    const extra = BODY - widths.reduce((a,b) => a+b,0);
    widths[6] += extra;
    const zeroRows = []; let current = [], used = 0;
    for (const employee of report.zero) {
      const width = measure(employee.name, 9) + 18;
      if (width > BODY) throw new Error('An employee name is too long for one A4 cell.');
      if (used + width > BODY && current.length) { zeroRows.push(current); current = []; used = 0; }
      current.push({ name: employee.name, width }); used += width;
    }
    if (current.length) zeroRows.push(current);
    const metrics = [['DAMAGED PARTS', String(report.quantity)], ['REPORT ENTRIES', String(report.count)],
      ...report.currencies.map(cur => ['TOTAL VALUE - ' + cur, money(report.totals.get(cur) || 0n)])];
    const metricRows = Math.ceil(metrics.length/4);
    const firstTop = HEIGHT - (111 + metricRows*65 + (zeroRows.length ? 27+zeroRows.length*23 : 0) + 18);
    const laterTop = HEIGHT - 85, bottom = 49;
    if (firstTop < bottom + 65) throw new Error('Too many employee or currency cells for this four-page report. Select a smaller report scope.');
    // Densities change only row padding. Body text is never wrapped or shrunk
    // below the measured readable size, and entries are never truncated.
    let pages, rowHeight, best = null;
    for (rowHeight of [25,22,19,17]) {
      pages = [[]]; let remaining = firstTop-bottom;
      for (const employee of report.active) {
        let offset = 0;
        while (offset < employee.rows.length) {
          const full = 24+21+(employee.rows.length-offset)*rowHeight+10;
          const fresh = laterTop-bottom;
          if (full > remaining && full <= fresh && pages[pages.length-1].length) { pages.push([]); remaining=fresh; }
          let room = Math.floor((remaining-24-21-10)/rowHeight);
          if (room < 1) { pages.push([]); remaining=fresh; room=Math.floor((remaining-55)/rowHeight); }
          const rows = employee.rows.slice(offset,offset+room);
          pages[pages.length-1].push({ employee, rows, continued:offset>0 });
          remaining -= 24+21+rows.length*rowHeight+10;
          offset += rows.length;
        }
      }
      if (!best || pages.length < best.pages.length) best = {pages, rowHeight};
    }
    pages=best.pages;rowHeight=best.rowHeight;
    if (pages.length>4) throw new Error('This date range needs more than four readable A4 pages. Select a shorter date range. No entries have been left out.');
    const colors = { ink:lib.rgb(.07,.13,.17), green:lib.rgb(0,.40,.29), muted:lib.rgb(.22,.29,.33), line:lib.rgb(.66,.73,.77),
      pale:lib.rgb(.91,.94,.96), pink:lib.rgb(.99,.92,.90), white:lib.rgb(1,1,1), red:lib.rgb(.53,.17,.12) };
    let logo = null;
    if (options.logo) {
      const bytes = new Uint8Array(options.logo);
      logo = bytes[0]===137 ? await pdf.embedPng(bytes) : await pdf.embedJpg(bytes);
    }
    const drawn = [];
    function drawText(page, text, x, y, fontSize, width, face=font, color=colors.ink, alignment='left') {
      const length = measure(text,fontSize,face);
      if (length>width+.01) throw new Error('A report label is too long for its A4 cell. No text was clipped.');
      if(alignment==='right')x+=width-length;
      if(alignment==='center')x+=(width-length)/2;
      page.drawText(text,{x,y,size:fontSize,font:face,color});
      drawn.push({page:pdf.getPageCount(),text,x,y,width:length,size:fontSize});
    }
    function fitText(page,text,x,y,fontSize,width,face=font,color=colors.ink,align='left') {
      const adjusted=Math.min(fontSize,width/Math.max(measure(text,1,face),1));
      if(adjusted<8)throw new Error('A report heading is too long for a readable A4 line.');
      drawText(page,text,x,y,adjusted,width,face,color,align);
    }
    function rect(page,x,y,width,height,color) { page.drawRectangle({x,y,width,height,color,borderColor:colors.line,borderWidth:.45}); }
    for(let pi=0;pi<pages.length;pi++) {
      const page=pdf.addPage([WIDTH,HEIGHT]);
      if(logo)page.drawImage(logo,{x:MARGIN,y:HEIGHT-43,width:25,height:25});
      drawText(page,'greenloop',MARGIN+(logo?32:0),HEIGHT-35,20,200,font,colors.green);
      if(options.sample)drawText(page,'PRINT CHECK - FICTIONAL DATA',WIDTH-MARGIN-200,HEIGHT-33,8,200,bold,colors.muted,'right');
      drawText(page,'Damage Report',MARGIN,HEIGHT-69,pi===0?24:17,BODY,bold);
      drawText(page,dateLabel(report.from)+' - '+dateLabel(report.to),WIDTH-MARGIN-230,HEIGHT-67,10.5,230,bold,colors.green,'right');
      if(pi===0) {
        drawText(page,report.employees.length+' employees | UAE incident dates (UTC+4)',MARGIN,HEIGHT-90,9.5,BODY,font,colors.muted);
        const gap=8,cellWidth=(BODY-gap*3)/4;
        for(let i=0;i<metrics.length;i++) {
          const x=MARGIN+(i%4)*(cellWidth+gap),y=HEIGHT-153-Math.floor(i/4)*65;
          rect(page,x+1.5,y-1.5,cellWidth,52,colors.pale);rect(page,x,y,cellWidth,52,colors.white);
          fitText(page,metrics[i][0],x+8,y+37,8,cellWidth-16,bold,colors.muted);
          fitText(page,metrics[i][1],x+8,y+12,20,cellWidth-16,bold,colors.green);
        }
        let y=HEIGHT-111-metricRows*65;
        drawText(page,'Value = price per part x quantity; currencies kept separate. Unpriced parts: '+report.unpriced,MARGIN,y,8.5,BODY,font,colors.muted);
        if(zeroRows.length) {
          y-=23;drawText(page,'ZERO DAMAGE - '+report.zero.length+' EMPLOYEES',MARGIN,y,9,BODY,bold,colors.green);y-=27;
          for(const row of zeroRows) {
            const surplus=(BODY-row.reduce((sum,cell)=>sum+cell.width,0))/row.length; let x=MARGIN;
            for(const cell of row) { const w=cell.width+surplus;rect(page,x,y,w,23,colors.pale);drawText(page,cell.name,x+7,y+8,9,w-14,font,colors.ink,'center');x+=w; }
            y-=23;
          }
        }
      }
      let top=pi===0?firstTop:laterTop;
      if(!report.active.length)drawText(page,'No damage recorded in the selected dates.',MARGIN,top-20,12,BODY);
      for(const block of pages[pi]) {
        const employee=block.employee;
        rect(page,MARGIN,top-24,BODY,24,colors.pink);
        const name=employee.name+(block.continued?' (continued)':'');
        const value=Array.from(employee.totals).map(([cur,cents])=>cur+' '+money(cents)).join(' / ');
        const summary='Damage: '+employee.quantity+(value?' | '+value:'');
        const sw=Math.min(BODY*.64,Math.max(150,measure(summary,9,bold)+12));
        fitText(page,name,MARGIN+6,top-16,10.5,BODY-sw-14,bold);
        fitText(page,summary,WIDTH-MARGIN-sw,top-16,9,sw-6,bold,colors.red,'right');
        top-=24;let x=MARGIN;
        for(let col=0;col<labels.length;col++) {rect(page,x,top-21,widths[col],21,colors.pale);drawText(page,labels[col],x+4,top-14,8,widths[col]-8,bold);x+=widths[col];}
        top-=21;
        for(const row of block.rows) {
          x=MARGIN;
          for(let col=0;col<row.cells.length;col++) {rect(page,x,top-rowHeight,widths[col],rowHeight,colors.white);drawText(page,row.cells[col],x+4,top-rowHeight/2-size*.35,size,widths[col]-8,font,colors.ink,col===3?'center':'left');x+=widths[col];}
          top-=rowHeight;
        }
        top-=10;
      }
      page.drawLine({start:{x:MARGIN,y:35},end:{x:WIDTH-MARGIN,y:35},thickness:.5,color:colors.line});
      drawText(page,'Greenloop FZC | '+dateLabel(report.generated,true)+' UAE',MARGIN,21,8,BODY*.72,font,colors.muted);
      drawText(page,'A4 portrait | '+(pi+1)+' / '+pages.length,WIDTH-MARGIN-120,21,8,120,font,colors.muted,'right');
    }
    return {bytes:await pdf.save(),pages:pages.length,bodyFont:size,drawn,report,
      filename:'Greenloop-Damage-Report-'+report.from+'-to-'+report.to+'.pdf'};
  }
  root.GREENLOOP_DAMAGE_PDF={create,prepare,validDate,version:VERSION};
})(typeof window==='object'?window:globalThis);
