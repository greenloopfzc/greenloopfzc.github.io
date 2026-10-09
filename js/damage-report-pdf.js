/* Damage Report PDF: A4 portrait only, wrapped cells, native vector text. */
(function (root) {
  'use strict';
  const VERSION = '20261007-damage-payable-1';
  const MARGIN = 24;
  const labels = ['DATE / TIME', 'MODEL', 'PART NAME', 'QTY', 'PRICE / PART', 'PART SOURCE', 'REASON'];
  const clean = value => String(value == null || value === '' ? 'Not recorded' : value).replace(/\s+/g, ' ').trim();
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const two = value => String(value).padStart(2, '0');
  function dateLabel(value, time = false) {
    const date = new Date(time ? Date.parse(value) + 14400000 : value + 'T00:00:00Z');
    if (!Number.isFinite(date.getTime())) throw new Error('A damage entry has an invalid date. Refresh the report.');
    return `${two(date.getUTCDate())} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()}` + (time ? ` ${two(date.getUTCHours() % 12 || 12)}:${two(date.getUTCMinutes())} ${date.getUTCHours() < 12 ? 'AM' : 'PM'}` : '');
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
    if (data.date_from.slice(8) !== '01') throw new Error('Start on the first day of a month to calculate the monthly allowance correctly.');
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
      if (row.department != null && !['glass','other'].includes(row.department)) throw new Error('An entry has an invalid department.');
      if (typeof row.is_lcd !== 'boolean') throw new Error('LCD classification is missing. Refresh the report.');
      employee.rows.push({ id: row.id, timestamp: Date.parse(row.occurred_at), cells, month:day.slice(0,7),
        department:row.department || null, isLcd:row.is_lcd, quantity:row.quantity, cents, currency });
      employee.quantity += row.quantity; quantity += row.quantity;
      if (cents === null) { employee.unpriced += row.quantity; unpriced += row.quantity; }
      else {
        const value = cents * BigInt(row.quantity);
        employee.totals.set(currency, (employee.totals.get(currency) || 0n) + value);
        totals.set(currency, (totals.get(currency) || 0n) + value);
      }
    }
    for (const employee of employees) employee.rows.sort((a,b) => b.timestamp-a.timestamp || b.id.localeCompare(a.id));
    const active = [], pending = [];
    let payable = 0n;
    for (const employee of employees) {
      const monthly = new Map();
      for (const row of employee.rows) {
        if (!monthly.has(row.month)) monthly.set(row.month, []);
        monthly.get(row.month).push(row);
      }
      for (const [month, rows] of [...monthly].sort((a,b)=>a[0].localeCompare(b[0]))) {
        const group = {key:employee.key, name:employee.name, month, rows, quantity:0, totals:new Map(), unpriced:0,
          lcdQuantity:0, lcdValue:0n, department:null, waived:0, average:0n, waiver:0n, payable:null, pending:''};
        const departments = new Set(rows.map(row=>row.department));
        if (departments.has(null)) group.pending = 'Department pending';
        else if (departments.size !== 1) group.pending = 'Department conflict';
        else group.department = [...departments][0];
        for (const row of rows) {
          group.quantity += row.quantity;
          if(row.cents === null) { group.unpriced += row.quantity; group.pending ||= 'Price pending'; }
          else {
            const value = row.cents*BigInt(row.quantity);
            group.totals.set(row.currency,(group.totals.get(row.currency)||0n)+value);
            if(row.currency !== 'AED') group.pending ||= 'AED settlement pending';
            if(row.isLcd) group.lcdValue += value;
          }
          if(row.isLcd) group.lcdQuantity += row.quantity;
        }
        group.waived = Math.min(group.lcdQuantity,group.department === 'glass' ? 4 : 1);
        const denominator = BigInt(group.lcdQuantity || 1);
        // Rational cents retain the exact quantity-weighted average until the
        // final payable is rounded. Display rounding never changes settlement.
        const waiverNumerator = group.lcdValue*BigInt(group.waived);
        const rounded = (n,d) => (n+d/2n)/d;
        group.average = rounded(group.lcdValue,denominator);
        group.waiver = rounded(waiverNumerator,denominator);
        if(!group.pending) {
          const remaining = ((group.totals.get('AED')||0n)-10000n)*denominator-waiverNumerator;
          group.payable = remaining > 0n ? rounded(remaining,denominator*2n) : 0n;
          payable += group.payable;
        } else pending.push(group);
        active.push(group);
      }
    }
    const currencies = ['AED', ...Array.from(totals.keys()).filter(c => c !== 'AED').sort()];
    return { from: data.date_from, to: data.date_to, generated: data.generated_at, employees, quantity, count: data.rows.length, unpriced,
      currencies, totals, active, zero: employees.filter(e => !e.rows.length), payable, pending };
  }

  async function create(data, options = {}) {
    const lib = options.PDFLib || root.PDFLib;
    if (!lib) throw new Error('PDF tools did not load. Please try again.');
    const report = prepare(data), pdf = await lib.PDFDocument.create();
    const WIDTH = 595.276, HEIGHT = 841.89, BODY = WIDTH - 2 * MARGIN;
    const orientation = "portrait";
    const font = await pdf.embedFont(lib.StandardFonts.Helvetica), bold = await pdf.embedFont(lib.StandardFonts.HelveticaBold);
    pdf.setTitle('Damage Report'); pdf.setAuthor('Greenloop FZC'); pdf.setSubject('Employee damage report | UAE incident dates');
    pdf.catalog.getOrCreateViewerPreferences().setPrintScaling(lib.PrintScaling.None);
    pdf.catalog.getOrCreateViewerPreferences().setPickTrayByPDFSize(true);
    function measure(text, size, face = font) {
      try { return face.widthOfTextAtSize(text, size); }
      catch (_) { throw new Error('The PDF cannot render a character in this report. Use standard Latin characters in the employee and dropdown names. No entries were omitted.'); }
    }
    // A4 portrait is fixed. Content wraps inside its own cell; orientation
    // never changes in response to text length or number of records.
    const size = 9.5, lineHeight = 11.5;
    const widths = [86,78,75,26,70,66,BODY-401];
    function cellLines(text,width) {
      const lines=[];let line='';
      for(const word of text.split(' ')) {
        const candidate=(line?line+' ':'')+word;
        if(measure(candidate,size)<=width){line=candidate;continue;}
        if(line){lines.push(line);line='';}
        let piece='';
        for(const char of word) {
          if(piece&&measure(piece+char,size)>width){lines.push(piece);piece='';}
          piece+=char;
        }
        line=piece;
      }
      if(line)lines.push(line);
      return lines.length?lines:[''];
    }
    for(const employee of report.active) for(const row of employee.rows)
      row.lines=row.cells.map((cell,col)=>cellLines(cell,widths[col]-8));
    const zeroRows = []; let current = [], used = 0;
    for (const employee of report.zero) {
      const width = measure(employee.name, 9) + 18;
      if (width > BODY) throw new Error('An employee name is too long for one A4 cell.');
      if (used + width > BODY && current.length) { zeroRows.push(current); current = []; used = 0; }
      current.push({ name: employee.name, width }); used += width;
    }
    if (current.length) zeroRows.push(current);
    const metrics = [['DAMAGED PARTS', String(report.quantity)], ['REPORT ENTRIES', String(report.count)],
      ['TOTAL VALUE - AED', money(report.totals.get('AED') || 0n)],
      ['PAYABLE - AED', report.pending.length ? 'Pending' : money(report.payable)],
      ...report.currencies.filter(cur=>cur!=='AED').map(cur => ['TOTAL VALUE - ' + cur, money(report.totals.get(cur) || 0n)])];
    const metricRows = Math.ceil(metrics.length/4);
    const firstTop = HEIGHT - (91 + metricRows*65 + (zeroRows.length ? 27+zeroRows.length*23 : 0) + 18);
    const laterTop = HEIGHT - 85, bottom = 49;
    if (firstTop < bottom + 65) throw new Error('Too many employee or currency cells for this four-page report. Select a smaller report scope.');
    // Paginate measured, variable-height rows. Repeat the employee band and
    // column headings on each continuation page. Exceptionally tall entries
    // split into readable fragments without dropping any cell text.
    let pages, best=null;
    for(const padding of [10,7,4]) {
      pages=[[]];let remaining=firstTop-bottom;
      const fresh=laterTop-bottom;
      const maxLines=Math.max(1,Math.floor((fresh-99-padding)/lineHeight));
      for(const employee of report.active) {
        const fragments=[];
        for(const row of employee.rows) {
          const count=Math.max(...row.lines.map(lines=>lines.length));
          for(let start=0;start<count;start+=maxLines) {
            const lines=row.lines.map(cell=>cell.length<=maxLines?cell:cell.slice(start,start+maxLines));
            fragments.push({...row,lines,height:Math.max(23,Math.max(...lines.map(cell=>cell.length))*lineHeight+padding)});
          }
        }
        let offset=0;
        while(offset<fragments.length) {
          const full=99+fragments.slice(offset).reduce((n,row)=>n+row.height,0);
          if(full>remaining&&full<=fresh&&pages[pages.length-1].length){pages.push([]);remaining=fresh;}
          if(remaining<99+fragments[offset].height){pages.push([]);remaining=fresh;}
          const rows=[];let used=99;
          while(offset+rows.length<fragments.length&&used+fragments[offset+rows.length].height<=remaining) {
            const row=fragments[offset+rows.length];rows.push(row);used+=row.height;
          }
          if(!rows.length)throw new Error('An entry could not fit on an A4 portrait page. No text was omitted.');
          pages[pages.length-1].push({employee,rows,continued:offset>0});
          remaining-=used;offset+=rows.length;
        }
      }
      if(!best||pages.length<best.length)best=pages;
    }
    pages=best;
    if (pages.length>4) throw new Error('This date range needs more than four readable A4 pages. Select a shorter date range. No entries have been left out.');
    const colors = { ink:lib.rgb(.07,.13,.17), green:lib.rgb(0,.40,.29), muted:lib.rgb(.22,.29,.33), line:lib.rgb(.66,.73,.77),
      pale:lib.rgb(.91,.94,.96), pink:lib.rgb(.99,.92,.90), white:lib.rgb(1,1,1), red:lib.rgb(.53,.17,.12) };
    let logo = null;
    if (options.logo) {
      const bytes = new Uint8Array(options.logo);
      logo = bytes[0]===137 ? await pdf.embedPng(bytes) : await pdf.embedJpg(bytes);
    }
    const drawn = [], previewPages = [];
    let previewOps;
    function drawText(page, text, x, y, fontSize, width, face=font, color=colors.ink, alignment='left') {
      const cellX = x;
      const length = measure(text,fontSize,face);
      if (length>width+.01) throw new Error('A report label is too long for its A4 cell. No text was clipped.');
      if(alignment==='right')x+=width-length;
      if(alignment==='center')x+=(width-length)/2;
      page.drawText(text,{x,y,size:fontSize,font:face,color});
      previewOps.push({kind:'text',text,x,y,size:fontSize,bold:face===bold,color});
      drawn.push({page:pdf.getPageCount(),text,x,y,width:length,size:fontSize,alignment,cellX,cellWidth:width});
    }
    function fitText(page,text,x,y,fontSize,width,face=font,color=colors.ink,align='left') {
      const adjusted=Math.min(fontSize,width/Math.max(measure(text,1,face),1));
      if(adjusted<8)throw new Error('A report heading is too long for a readable A4 line.');
      drawText(page,text,x,y,adjusted,width,face,color,align);
    }
    function rect(page,x,y,width,height,color) { previewOps.push({kind:'rect',x,y,width,height,color,border:colors.line});page.drawRectangle({x,y,width,height,color,borderColor:colors.line,borderWidth:.45}); }
    function drawBrand(page,x,y,width) {
      if(!logo) {drawText(page,'Greenloop FZC',x,y+5,Math.min(14,width/8),width,bold,colors.green);return;}
      const crop={x:110,y:100,width:1080,height:230};
      const scale=width/crop.width,height=crop.height*scale;
      previewOps.push({kind:'brand',x,y,width,height,crop});
      page.pushOperators(lib.pushGraphicsState(),lib.rectangle(x,y,width,height),lib.clip(),lib.endPath());
      page.drawImage(logo,{x:x-crop.x*scale,y:y-(427-crop.y-crop.height)*scale,width:1280*scale,height:427*scale});
      page.pushOperators(lib.popGraphicsState());
    }
    for(let pi=0;pi<pages.length;pi++) {
      const page=pdf.addPage([WIDTH,HEIGHT]);
      previewOps=[];previewPages.push({width:WIDTH,height:HEIGHT,ops:previewOps});
      drawBrand(page,MARGIN,HEIGHT-45,140);
      if(options.sample)drawText(page,'PRINT CHECK - FICTIONAL DATA',WIDTH-MARGIN-200,HEIGHT-33,8,200,bold,colors.muted,'right');
      drawText(page,'Damage Report',MARGIN,HEIGHT-67,12,100,bold);
      drawText(page,'| '+report.employees.length+' employees',MARGIN+100,HEIGHT-67,9.5,115,font,colors.muted);
      drawText(page,dateLabel(report.from)+' - '+dateLabel(report.to)+' | UAE (UTC+4)',WIDTH-MARGIN-238,HEIGHT-67,9.5,238,font,colors.green,'right');
      if(pi===0) {
        const gap=8,cellWidth=(BODY-gap*3)/4;
        for(let i=0;i<metrics.length;i++) {
          const x=MARGIN+(i%4)*(cellWidth+gap),y=HEIGHT-133-Math.floor(i/4)*65;
          rect(page,x+1.5,y-1.5,cellWidth,52,colors.pale);rect(page,x,y,cellWidth,52,colors.white);
          fitText(page,metrics[i][0],x+8,y+37,8,cellWidth-16,bold,colors.muted,'center');
          fitText(page,metrics[i][1],x+8,y+12,20,cellWidth-16,bold,colors.green,'center');
        }
        let y=HEIGHT-91-metricRows*65;
        drawText(page,'Monthly AED settlement | LCD allowance only | Unpriced parts: '+report.unpriced+' | Pending: '+report.pending.length,MARGIN,y,8.5,BODY,font,colors.muted);
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
        const name=employee.name+(block.continued?' (continued)':'');
        const department=employee.department==='glass'?'Glass Department':employee.department==='other'?'Other Department':'Department pending';
        const month=months[Number(employee.month.slice(5))-1]+' '+employee.month.slice(0,4);
        const value=Array.from(employee.totals).map(([cur,cents])=>cur+' '+money(cents)).join(' / ') || 'Not priced';
        const cells=[{w:BODY*.40,label:name,value:department+' | '+month,color:colors.pale},
          {w:BODY*.30,label:'TOTAL DAMAGE VALUE',value,color:colors.pink},
          {w:BODY*.30,label:'TECHNICIAN PAYABLE',value:employee.pending || 'AED '+money(employee.payable),color:colors.pale}];
        let hx=MARGIN;
        for(const cell of cells) {
          rect(page,hx,top-42,cell.w,42,cell.color);
          fitText(page,cell.label,hx+5,top-15,9.5,cell.w-10,bold,colors.ink,'center');
          fitText(page,cell.value,hx+5,top-32,10,cell.w-10,bold,colors.green,'center');
          hx+=cell.w;
        }
        const allowance=employee.pending ? employee.pending+' - correct this employee/month in Data Correction.' :
          'LCD '+employee.lcdQuantity+' | Average AED '+money(employee.average)+' | Waived '+employee.waived+' = AED '+money(employee.waiver)+' | Less AED 100 | Balance / 2';
        rect(page,MARGIN,top-68,BODY,26,colors.white);
        fitText(page,allowance,MARGIN+5,top-59,8.5,BODY-10,font,colors.muted,'center');
        top-=68;let x=MARGIN;
        for(let col=0;col<labels.length;col++) {rect(page,x,top-21,widths[col],21,colors.pale);drawText(page,labels[col],x+4,top-14,8,widths[col]-8,bold,colors.ink,'center');x+=widths[col];}
        top-=21;
        for(const row of block.rows) {
          x=MARGIN;
          for(let col=0;col<row.cells.length;col++) {
            rect(page,x,top-row.height,widths[col],row.height,colors.white);
            const lines=row.lines[col],textHeight=(lines.length-1)*lineHeight+size;
            const baseline=top-(row.height-textHeight)/2-size;
            for(let i=0;i<lines.length;i++) drawText(page,lines[i],x+4,baseline-i*lineHeight,size,widths[col]-8,font,colors.ink,'center');
            x+=widths[col];
          }
          top-=row.height;
        }
        top-=10;
      }
      previewOps.push({kind:'line',x:MARGIN,y:35,x2:WIDTH-MARGIN,y2:35,color:colors.line});
      page.drawLine({start:{x:MARGIN,y:35},end:{x:WIDTH-MARGIN,y:35},thickness:.5,color:colors.line});
      drawBrand(page,MARGIN,17,65);
      drawText(page,dateLabel(report.generated,true)+' UAE',MARGIN+74,21,8,BODY*.60,font,colors.muted);
      drawText(page,'A4 '+orientation+' | '+(pi+1)+' / '+pages.length,WIDTH-MARGIN-120,21,8,120,font,colors.muted,'right');
    }
    return {bytes:await pdf.save(),pages:pages.length,bodyFont:size,drawn,previewPages,report,orientation,width:WIDTH,height:HEIGHT,detailCount:0,
      filename:'Greenloop-Damage-Report-'+report.from+'-to-'+report.to+'.pdf'};
  }
  root.GREENLOOP_DAMAGE_PDF={create,prepare,validDate,version:VERSION};
})(typeof window==='object'?window:globalThis);
