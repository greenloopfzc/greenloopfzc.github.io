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

  const compactW=595.276, compactH=841.89, compactM=30;
  const issuanceWidths=[25,81,58,39,52,30,43,110,97];
  const issuanceLabels=['S.No','IMEI','Model','GB','Color','Grade','Batch Qty','Required Parts','Required Services'];
  const issuanceWidth=issuanceWidths.reduce((sum,width)=>sum+width,0);
  const tableOffset=97, headerHeight=22, footerReserve=44;
  const rowsHeight=compactH-compactM-tableOffset-headerHeight-footerReserve;
  const workStart=7;
  const phonesTotalHeight=16, partsGap=14, partsTitleHeight=22;
  const partsWidths=[35,122,118,186,74];
  const partsLabels=['S.No','Model','Color','Part','Required Qty'];
  const partsHeadingHeight=partsTitleHeight+headerHeight;
  const compare=new Intl.Collator('en',{numeric:true,sensitivity:'base'}).compare;
  const colorSpecificPart=/\bhousing\b|\b(?:back|rear)[\s-]+(?:glass|cover)\b/i;
  const emphasis=col=>col===1||col===5||col===6;
  const clean=value=>String(value??'').replace(/[\u2010-\u2015]/g,'-');

  function batchQty(row){
    const quantity=row.batchQuantity??String(row.batch??'').match(/-\((\d+)\)$/)?.[1];
    return /^\d+$/.test(String(quantity))&&Number.isSafeInteger(Number(quantity))?String(Number(quantity)):'-';
  }

  function wrapIssuanceText(value,width,measure){
    const lines=[];
    let line='';
    for(const word of clean(value).trim().split(/\s+/)){
      const next=line?line+' '+word:word;
      if(measure(next)<=width){line=next;continue;}
      if(line){lines.push(line);line='';}
      if(measure(word)<=width){line=word;continue;}
      for(const letter of word){
        if(line&&measure(line+letter)>width){lines.push(line);line='';}
        line+=letter;
      }
    }
    return [...lines,line];
  }

  function groupRequiredParts(phones){
    const groups=new Map();
    for(const phone of phones){
      const model=String(phone.model??'').trim()||'Not recorded';
      const savedColor=String(phone.color??'').trim();
      for(const part of phone.parts){
        const name=String(part?.name??'').trim();
        const quantity=Number(part?.quantity);
        if(!name||!['number','string'].includes(typeof part?.quantity)||!Number.isSafeInteger(quantity)||quantity<1){
          throw new Error('A saved required part has an invalid name or quantity. Check the issuance row before generating the sheet.');
        }
        const color=colorSpecificPart.test(name)
          ? (!savedColor||/^(?:[-–—]+|not recorded)$/i.test(savedColor)?'Not recorded':savedColor)
          : '-';
        const fields=[model,color,name];
        const key=JSON.stringify(fields.map(value=>value.toLowerCase()));
        const group=groups.get(key)||{fields,quantity:0};
        group.quantity+=quantity;
        if(!Number.isSafeInteger(group.quantity))throw new Error('A required parts total could not be verified.');
        groups.set(key,group);
      }
    }
    return [...groups.values()].sort((a,b)=>
      compare(a.fields[0],b.fields[0])||compare(a.fields[2],b.fields[2])||compare(a.fields[1],b.fields[1]));
  }

  function workLines(items,width,measure,inline){
    const lines=[];
    for(const item of items){
      const wrapped=wrapIssuanceText(item,width,measure);
      const previous=lines.at(-1);
      if(inline&&previous?.bullet&&wrapped.length===1){
        const joined=previous.text+'  •  '+wrapped[0];
        if(measure(joined)<=width){
          previous.text=joined;
          continue;
        }
      }
      lines.push(...wrapped.map((text,index)=>({text,bullet:index===0})));
    }
    return lines.length?lines:[{text:'None',muted:true}];
  }

  function compactPlan(input,measure){
    const report=validate(input);
    const groups=groupRequiredParts(report.rows);
    const fields=report.rows.map((phone,index)=>
      [String(index+1),phone.imei,phone.model||'-',phone.storage||'-',phone.color||'-',phone.grade||'-',batchQty(phone)]);
    const fieldValues=issuanceLabels.slice(0,workStart).map((_,col)=>new Set(fields.map(row=>row[col])));
    const comfortable={size:8.7,leading:12,padding:12,minRow:31,partsSize:9,partsLeading:12,partsPadding:10,partsMinRow:24,dense:false};
    const compact={size:8.1,leading:9,padding:1.4,minRow:10.4,partsSize:8.7,partsLeading:10,partsPadding:3,partsMinRow:14,dense:true};

    function layout(style,scale=1){
      const size=style.size*scale,leading=style.leading*scale,padding=style.padding*scale;
      const partsSize=style.partsSize*scale,partsLeading=style.partsLeading*scale;
      const widths=issuanceWidths.slice();
      if(style.dense){
        let available=0;
        for(const [col,values] of fieldValues.entries()){
          let widest=measure(issuanceLabels[col],7.8,true);
          for(const value of values)widest=Math.max(widest,measure(value,size,emphasis(col)));
          const width=Math.min(widths[col],Math.ceil(widest+7));
          available+=widths[col]-width;
          widths[col]=width;
        }
        const partsShare=Math.round(available*.6);
        widths[workStart]+=partsShare;
        widths[workStart+1]+=available-partsShare;
      }
      const rows=report.rows.map((phone,index)=>{
        const serial=index+1;
        const cells=fields[index].map((value,col)=>wrapIssuanceText(value,widths[col]-6,text=>measure(text,size,emphasis(col))).map(text=>({text})));
        const measureLine=text=>measure(text,size);
        const parts=phone.parts.map(part=>part.name+' × '+part.quantity);
        cells.push(workLines(parts,widths[workStart]-18,measureLine,false));
        cells.push(workLines(phone.services,widths[workStart+1]-18,measureLine,style.dense));
        const height=Math.max(style.minRow*scale,Math.max(...cells.map(cell=>cell.length))*leading+padding);
        return {serial,cells,height};
      });
      const parts=groups.map(({fields,quantity},index)=>{
        const serial=index+1;
        const cells=[String(serial),...fields,String(quantity)].map((value,col)=>
          wrapIssuanceText(value,partsWidths[col]-12,text=>measure(text,partsSize,col===4)));
        const height=Math.max(style.partsMinRow*scale,Math.max(...cells.map(cell=>cell.length))*partsLeading+style.partsPadding*scale);
        return {serial,cells,height};
      });
      const emptyPartsHeight=style.partsMinRow*scale;
      const height=rows.reduce((sum,row)=>sum+row.height,0)+
        (parts.length?parts.reduce((sum,row)=>sum+row.height,0):emptyPartsHeight);
      return {size,leading,padding,partsSize,partsLeading,emptyPartsHeight,rows,parts,height,widths};
    }

    // Keep the page title and table headers readable. Fit the table bodies in the remaining space.
    const bodyHeight=rowsHeight-partsGap-partsHeadingHeight-6;
    let fitted=layout(comfortable);
    if(fitted.height>bodyHeight){
      fitted=layout({...comfortable,padding:5,minRow:24,partsPadding:7,partsMinRow:21});
    }
    if(fitted.height>bodyHeight){
      fitted=layout(compact);
      if(fitted.height>bodyHeight){
        let lower=0,upper=1;
        for(let step=0;step<16;step++){
          const scale=(lower+upper)/2,candidate=layout(compact,scale);
          if(candidate.height<=bodyHeight){
            fitted=candidate;
            lower=scale;
          }else upper=scale;
        }
      }
    }
    const headers=issuanceLabels.map((label,col)=>wrapIssuanceText(label,fitted.widths[col]-6,text=>measure(text,7.8,true)));
    const meta='Technician: '+report.technician+' | Total phones: '+report.total+' | '+date(report.generatedAt);
    const metaSize=Math.min(9,9*issuanceWidth/measure(meta,9));
    return {...fitted,report,headers,meta,metaSize};
  }

  function partsSummaryHtml(plan){
    const body=plan.parts.length?plan.parts.map(row=>'<tr style="height:'+row.height+'pt">'+
      row.cells.map(lines=>'<td>'+lines.map(value=>'<div class="sheet-line">'+escape(value)+'</div>').join('')+'</td>').join('')+'</tr>').join('')
      : '<tr style="height:'+plan.emptyPartsHeight+'pt"><td colspan="5" class="parts-empty">No parts required.</td></tr>';
    return '<section class="parts-summary"><h2>Parts Summary</h2>'+
      '<table><colgroup>'+partsWidths.map(width=>'<col style="width:'+width+'pt">').join('')+'</colgroup>'+
      '<thead><tr>'+partsLabels.map(label=>'<th scope="col">'+label+'</th>').join('')+'</tr></thead><tbody>'+body+'</tbody></table></section>';
  }

  function compactPrintHtml(input,options){
    const ctx=root.document?.createElement('canvas').getContext('2d');
    const measure=(text,size,bold)=>{
      if(!ctx)return text.length*size*.58;
      ctx.font=(bold?'bold ':'')+size+'pt Arial';
      return ctx.measureText(text).width*.75;
    };
    const plan=compactPlan(input,measure);
    const rows=plan.rows.map(row=>{
      const cells=row.cells.map((cell,col)=>{
        const work=col>=workStart;
        const content=cell.map(entry=>'<div class="sheet-line'+(entry.bullet?' has-bullet':'')+(entry.muted?' is-muted':'')+'">'+escape(entry.text)+'</div>').join('');
        return '<td'+(work?' class="work-cell"':emphasis(col)?' class="emphasis"':'')+'>'+content+'</td>';
      }).join('');
      return '<tr style="height:'+row.height+'pt">'+cells+'</tr>';
    }).join('');
    const brand=options.logoUrl?'<div class="sheet-logo"><img src="'+escape(options.logoUrl)+'" alt="Greenloop FZC"></div>':'<b class="sheet-logo">GREENLOOP FZC</b>';
    const phoneTable='<table class="phone-details" style="font-size:'+plan.size+'pt;line-height:'+plan.leading+'pt;--row-padding:'+plan.padding+'pt;--bullet-size:'+(plan.size*.27)+'pt"><colgroup>'+
      plan.widths.map(width=>'<col style="width:'+width+'pt">').join('')+'</colgroup><thead><tr>'+
      plan.headers.map(lines=>'<th scope="col">'+lines.map(escape).join('<br>')+'</th>').join('')+'</tr></thead><tbody>'+rows+
      '</tbody><tfoot><tr><td colspan="9">PHONES ON THIS PAGE: '+plan.rows.length+'</td></tr></tfoot></table>';
    const sheet='<section class="sheet"><header>'+brand+'<h1>Lab &amp; Glass Issuance</h1><p style="font-size:'+plan.metaSize+'pt">'+escape(plan.meta)+'</p></header>'+
      phoneTable+partsSummaryHtml(plan)+
      '<footer><span>'+escape(plan.report.phase)+' | S.No 1-'+plan.rows.length+'</span><span>Page 1 of 1</span></footer></section>';
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Lab &amp; Glass Issuance</title><style>'+
      '@page{size:A4 portrait;margin:30pt}*{box-sizing:border-box}html,body{margin:0;padding:0;font-family:Arial,sans-serif;color:#17342e;-webkit-print-color-adjust:exact;print-color-adjust:exact}'+
      '.sheet{width:535pt;margin-inline:auto}header{height:67pt;position:relative;text-align:center}'+
      '.sheet-logo{position:absolute;left:0;top:0;width:100pt;height:22pt;overflow:hidden;text-align:left;color:#146448}.sheet-logo img{position:absolute;width:118.519pt;height:39.537pt;left:-10.185pt;top:-9.26pt}'+
      'header h1{font-size:17pt;margin:0;padding-top:24pt}header p{margin:4pt 0;white-space:nowrap;color:#4c615d}'+
      'table{width:535pt;border-collapse:collapse;table-layout:fixed}th,td{border:.35pt solid #bdcfc7;text-align:center;vertical-align:middle;padding:0 3pt}'+
      'thead th{height:22pt;background:#e1f0e8;font-size:7.8pt;line-height:9pt;padding-inline:2pt;white-space:nowrap}tbody tr{break-inside:avoid}tbody td{border-block:0;box-shadow:inset 0 -.5pt #bdcfc7}tbody tr:nth-child(even){background:#f5f8f6}.sheet-line{white-space:pre}.emphasis{font-weight:bold}'+
      '.work-cell{text-align:left;vertical-align:top;padding:max(0pt,calc(var(--row-padding) / 2 - .3pt)) 3pt 0 15pt}.work-cell .sheet-line{position:relative}'+
      '.has-bullet::before{content:"";position:absolute;left:-7.5pt;top:50%;width:var(--bullet-size);height:var(--bullet-size);border-radius:50%;background:#146448;transform:translateY(-50%)}'+
      '.is-muted{color:#4c615d}tfoot td{height:16pt;background:#e1f0e8;font-size:8pt;line-height:9pt;font-weight:bold}footer{font-size:7pt;padding-top:7pt;display:flex;justify-content:space-between}'+
      '.parts-summary{margin-top:'+partsGap+'pt}.parts-summary h2{height:'+partsTitleHeight+'pt;line-height:19pt;font-size:12pt;margin:0;color:#146448}'+
      '.parts-summary td{font-size:'+plan.partsSize+'pt;line-height:'+plan.partsLeading+'pt;padding-inline:6pt}.parts-summary td:nth-child(n+2):nth-child(-n+4){text-align:left}.parts-summary td:last-child{font-weight:bold}.parts-summary td.parts-empty{font-weight:normal;text-align:left}'+
      '</style></head><body>'+sheet+'</body></html>';
  }

  async function compactCreate(input,options){
    const lib=options.PDFLib||root.PDFLib;
    if(!lib)throw Error('PDF tools could not load.');
    const doc=await lib.PDFDocument.create();
    const font=await doc.embedFont(lib.StandardFonts.Helvetica),bold=await doc.embedFont(lib.StandardFonts.HelveticaBold);
    const measure=(text,size,heavy)=>{
      try{return (heavy?bold:font).widthOfTextAtSize(clean(text),size);}
      catch(_){throw Error('A saved name contains characters the PDF font cannot display. Use Print for this sheet.');}
    };
    const plan=compactPlan(input,measure),r=plan.report;
    const M=compactM,W=compactW,H=compactH,tableX=(W-issuanceWidth)/2;
    const ink=lib.rgb(.09,.20,.18),green=lib.rgb(.08,.39,.28),line=lib.rgb(.74,.81,.78),pale=lib.rgb(.88,.94,.91);
    const white=lib.rgb(1,1,1),muted=lib.rgb(.30,.38,.36),stripe=lib.rgb(.96,.97,.96);
    let logo;
    if(options.logo){
      const bytes=new Uint8Array(options.logo);
      logo=bytes[0]===137?await doc.embedPng(bytes):await doc.embedJpg(bytes);
    }
    doc.setTitle('Lab & Glass Issuance - '+r.technician);
    doc.setAuthor('Greenloop FZC');
    const page=doc.addPage([W,H]);
    const text=(value,x,y,size,heavy=false,color=ink)=>page.drawText(clean(value),{x,y,size,font:heavy?bold:font,color});
    const center=(value,x,y,width,size,heavy=false)=>text(value,x+(width-measure(value,size,heavy))/2,y,size,heavy);
    if(logo){
      const scale=100/1080,base=H-M-22;
      page.pushOperators(lib.pushGraphicsState(),lib.rectangle(M,base,100,22),lib.clip(),lib.endPath());
      page.drawImage(logo,{x:M-110*scale,y:base-(427-100-230)*scale,width:1280*scale,height:427*scale});
      page.pushOperators(lib.popGraphicsState());
    }else text('GREENLOOP FZC',M,H-M-15,15,true,green);
    center('Lab & Glass Issuance',M,H-M-40,W-2*M,17,true);
    center(plan.meta,M,H-M-54,W-2*M,plan.metaSize);
    let y=H-tableOffset,x=tableX;
    plan.headers.forEach((lines,col)=>{
      const width=plan.widths[col];
      page.drawRectangle({x,y:y-headerHeight,width,height:headerHeight,color:pale,borderColor:line,borderWidth:.35});
      const top=y-(headerHeight-lines.length*9)/2-7.8;
      lines.forEach((value,index)=>center(value,x,top-index*9,width,7.8,true));
      x+=width;
    });
    y-=headerHeight;
    for(const row of plan.rows){
      x=tableX;
      row.cells.forEach((cell,col)=>{
        const width=plan.widths[col],work=col>=workStart;
        page.drawRectangle({x,y:y-row.height,width,height:row.height,color:row.serial%2?white:stripe,borderColor:line,borderWidth:.35});
        const top=y-(work?plan.padding/2:(row.height-cell.length*plan.leading)/2)-plan.size;
        cell.forEach((entry,i)=>{
          const baseline=top-i*plan.leading;
          if(work){
            if(entry.bullet)page.drawCircle({x:x+8.5,y:baseline+plan.size*.32,size:plan.size*.135,color:green});
            text(entry.text,x+15,baseline,plan.size,false,entry.muted?muted:ink);
          }else center(entry.text,x,baseline,width,plan.size,emphasis(col));
        });
        x+=width;
      });
      y-=row.height;
    }
    page.drawRectangle({x:tableX,y:y-phonesTotalHeight,width:issuanceWidth,height:phonesTotalHeight,color:pale});
    center('PHONES ON THIS PAGE: '+plan.rows.length,M,y-11,W-2*M,8,true);
    y-=phonesTotalHeight;
    y-=partsGap;
    text('Parts Summary',tableX,y-14,12,true,green);
    y-=partsTitleHeight;
    x=tableX;
    partsLabels.forEach((label,col)=>{
      const width=partsWidths[col];
      page.drawRectangle({x,y:y-headerHeight,width,height:headerHeight,color:pale,borderColor:line,borderWidth:.35});
      center(label,x,y-14,width,7.8,true);
      x+=width;
    });
    y-=headerHeight;
    if(!plan.parts.length){
      page.drawRectangle({x:tableX,y:y-plan.emptyPartsHeight,width:issuanceWidth,height:plan.emptyPartsHeight,color:white,borderColor:line,borderWidth:.35});
      text('No parts required.',tableX+6,y-(plan.emptyPartsHeight-plan.partsLeading)/2-plan.partsSize,plan.partsSize,false,muted);
      y-=plan.emptyPartsHeight;
    }
    for(const row of plan.parts){
      x=tableX;
      row.cells.forEach((cell,col)=>{
        const width=partsWidths[col];
        page.drawRectangle({x,y:y-row.height,width,height:row.height,color:row.serial%2?white:stripe,borderColor:line,borderWidth:.35});
        const top=y-(row.height-cell.length*plan.partsLeading)/2-plan.partsSize;
        cell.forEach((value,index)=>{
          const baseline=top-index*plan.partsLeading;
          if(col===0||col===4)center(value,x,baseline,width,plan.partsSize,col===4);
          else text(value,x+6,baseline,plan.partsSize);
        });
        x+=width;
      });
      y-=row.height;
    }
    text(r.phase+' | S.No 1-'+plan.rows.length,M,y-14,7);
    const label='Page 1 of 1';
    text(label,W-M-measure(label,7),y-14,7);
    return {bytes:await doc.save(),pages:1,filename:'Greenloop-Lab-Glass-Issuance-'+r.technician.replace(/[^a-z0-9]+/gi,'-')+'.pdf'};
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
  root.GREENLOOP_QC_HANDOVER_PDF = {version:'20261121-issuance-separate-parts-1',validate, create, printHtml};
})(typeof window !== 'undefined' ? window : globalThis);
