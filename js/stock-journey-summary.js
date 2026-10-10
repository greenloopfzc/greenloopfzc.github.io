/* Compact journey presentation. Uses recorded milestones; never changes saved data. */
(function(root){
  'use strict';
  const text=v=>String(v??'').trim(), norm=v=>text(v).toLowerCase().replace(/_/g,' ');
  const field=(row,...names)=>text((row.details||[]).find(d=>names.some(n=>norm(n)===norm(d.label)))?.value);
  const stamp=r=>{const t=Date.parse(r.occurred_at);return Number.isFinite(t)?t:null;};
  const prefix=r=>text(r.id).split(':')[0];
  const titles={stock_received:'Stock Received',imei_entry:'IMEI Entry',initial_qc:'Initial QC',laboratory:'Laboratory',glass:'Glass',final_qc:'Final QC',frame:'Frame',ready_stock:'Ready Stock',export:'Export',stock_return:'Stock Return',rework:'Rework',other:'Recorded activity'};
  function place(v){const n=norm(v);if(/^(laboratory|lab)$/.test(n))return 'laboratory';if(n==='glass')return 'glass';if(n.includes('initial qc'))return 'initial_qc';if(n.includes('final qc'))return 'final_qc';if(n.includes('frame'))return 'frame';if(n.includes('ready stock'))return 'ready_stock';if(/export|outbound/.test(n))return 'export';return '';}
  function kind(r){
    const id=prefix(r),s=norm(r.stage),t=norm(r.title);
    if(id==='assignment'||s==='assignment'||id.startsWith('timer-')||s==='technician'||/technician planned|assigned to technician/.test(t))return 'support';
    // Work-start rows and their cycle fields may be mutable snapshots. They
    // support a visit but cannot move a rework visit ahead of its QC failure.
    if(/^(laboratory|glass)-start$/.test(id))return 'support';
    if(s==='movement'||id==='movement')return 'movement';
    if(/^(receipt|individual-receipt)$/.test(id)||s==='stock received')return 'stock_received';
    if(id==='entry'||s==='imei entry')return 'imei_entry';
    if(id==='initial-qc'||s==='initial qc'||/^initial qc/.test(t))return 'initial_qc';
    if(id==='final-qc'||s==='final qc'||/^(phone received at final qc|final qc)/.test(t))return 'final_qc';
    if(s==='ready stock'||/passed.*ready stock/.test(t))return 'ready_stock';
    if(id==='frame'||s==='frame'||/^frame/.test(t))return 'frame';
    if(id==='supplier-return'||s==='stock return')return 'stock_return';
    if(/^(export-box|dispatch)$/.test(id)||s==='export')return 'export';
    if(s==='rework')return 'rework';
    if(/part|service/.test(id)||r.parts?.length||/part|service|line saved/.test(t))return 'support';
    if(/laboratory|glass/.test(s+' '+id+' '+t))return /glass/.test(s+' '+id+' '+t)?'glass':'laboratory';
    return 'other';
  }
  function target(r){return place(field(r,'To','Next department','Next step','Department'))||(/ready stock/i.test(field(r,'Reason'))?'ready_stock':'');}
  function rank(e){if(e.kind==='movement')return 80;return ({stock_received:0,imei_entry:10,initial_qc:20,laboratory:30,glass:30,final_qc:40,frame:50,ready_stock:60,export:70})[e.kind]??75;}
  function group(rows){
    const entries=(Array.isArray(rows)?rows:[]).filter(r=>r&&typeof r==='object').map((row,index)=>({row,index,at:stamp(row),kind:kind(row),job:text(row.job_number)}));
    const ordered=entries.slice().sort((a,b)=>(a.at??Infinity)-(b.at??Infinity)||(a.job===b.job?rank(a)-rank(b):0)||a.index-b.index);
    const sections=[],support=[],visits=new Map();let current=null;
    function add(e,key){
      if(!current||current.key!==key||current.job!==e.job){
        const visitKey=e.job+'|'+key,visit=(visits.get(visitKey)||0)+1;visits.set(visitKey,visit);
        const rework=e.kind==='rework'||/rework|returned for/.test(norm(field(e.row,'Reason')))||(current?.job===e.job&&current.key==='final_qc'&&current.anchors.some(r=>norm(r.status)==='fail'));
        current={key,job:e.job,at:e.at,visit,rework,rows:[],anchors:[]};sections.push(current);
      }
      current.rows.push(e.row);current.anchors.push(e.row);
    }
    for(const e of ordered){
      if(e.at===null||e.kind==='support'||e.kind==='other'){support.push(e);continue;}
      if(e.kind==='movement'){
        const destination=target(e.row);
        const existing=sections.find(g=>g.job===e.job&&g.key===destination&&g.at===e.at);
        if(existing&&!['laboratory','glass'].includes(destination))existing.rows.push(e.row);
        else if(destination)add(e,destination);else if(current&&current.job===e.job)current.rows.push(e.row);else support.push(e);
      }else if(e.kind==='rework'){add(e,target(e.row)||'rework');}
      else add(e,e.kind);
    }
    for(const e of support){
      const r=e.row,id=prefix(r);
      let wanted=place(field(r,'Department'))||(/glass/.test(id+' '+norm(r.stage))?'glass':/laboratory|manual-part|part-installation|service/.test(id+' '+norm(r.stage))?'laboratory':'');
      const candidates=sections.filter(g=>g.job===e.job&&(!wanted||g.key===wanted));
      // Supplemental history is attached to the closest recorded visit. Its
      // timestamp and cycle are retained in Full activity, not treated as a visit.
      const nearest=e.at===null?null:candidates.reduce((best,g)=>!best||Math.abs(g.at-e.at)<Math.abs(best.at-e.at)?g:best,null);
      if(nearest)nearest.rows.push(r);
      else if(e.at!==null&&wanted&&!sections.some(g=>g.job===e.job&&g.key===wanted)){
        sections.push({key:wanted,job:e.job,at:e.at,visit:1,rows:[r],anchors:[r]});
      }
    }
    return sections.map((section,index)=>({section,index})).sort((a,b)=>a.section.at-b.section.at||a.index-b.index).map(item=>item.section);
  }
  function render(rows,options){
    const esc=options.escape, date=options.date,money=options.money;
    const unique=values=>[...new Set(values.map(text).filter(v=>v&&v!=='Not recorded'))];
    const groups=group(rows);
    const html=groups.map((g,index)=>{
      const vals=(...names)=>unique(g.rows.map(r=>field(r,...names)));
      const inspections=g.anchors.filter(r=>/^(pass|fail)$/i.test(text(r.status)));
      const displayRows=inspections.length?inspections:g.anchors;
      const actors=unique(displayRows.map(r=>r.actor));
      let when=date(displayRows[0]?.occurred_at);
      if(inspections.length>1&&inspections.at(-1).occurred_at!==inspections[0].occurred_at)when+=' → '+date(inspections.at(-1).occurred_at);
      const results=unique(g.anchors.map(r=>/^(pass|fail)$/i.test(text(r.status))?norm(r.status):''));
      const suffix=results.length?' — '+results.map(r=>r==='pass'?'Pass':'Fail').join(' → '):'';
      const title=(titles[g.key]||titles.other)+(['laboratory','glass'].includes(g.key)&&g.rework?' Rework':'')+suffix;
      const facts=[];const add=(label,value)=>{if(value)facts.push('<span><strong>'+esc(label)+':</strong> '+esc(value)+'</span>');};
      if(g.key==='stock_received'){add('Invoice',vals('Invoice').join(', '));add('Supplier',vals('Supplier code','Supplier name').join(', '));}
      if(g.key==='initial_qc')add('Findings',vals('Findings','Problems').join('; '));
      if(['laboratory','glass'].includes(g.key)){
        const techs=unique(g.rows.filter(r=>prefix(r)==='assignment'||/^timer-/.test(prefix(r))).map(r=>r.actor).concat(vals('Technician','Assigned technician')));
        add('Technician',techs.join(', '));
        const parts=g.rows.flatMap(r=>(r.parts||[]).map(p=>text(p.name)+' × '+text(p.quantity)+(p.unit_cost!=null?' · AED '+money(p.unit_cost)+'/part':'')));
        add('Parts recorded',parts.join('; '));add('Services reviewed',vals('Service').join(', '));
        const completed=g.anchors.filter(r=>/complet/i.test(r.title));
        if(completed.length){const r=completed[completed.length-1];let value='Completed';if(Number.isFinite(Number(r.duration_seconds))&&r.duration_seconds!=null){const n=Math.max(0,Math.round(Number(r.duration_seconds)));value+=' · '+text(r.duration_label||'Recorded time')+': '+Math.floor(n/3600)+'h '+Math.floor(n%3600/60)+'m '+n%60+'s';}add('Work',value);}
      }
      if(['final_qc','frame'].includes(g.key)&&results.includes('fail'))add('Failure reason',unique(g.rows.filter(r=>norm(r.status)==='fail').map(r=>field(r,'Failure reason','Reason','Notes'))).join('; '));
      if(['final_qc','frame','ready_stock'].includes(g.key)){add('Grade',vals('Final grade').join(', '));add('Battery',vals('Final battery health').join(', '));}
      if(g.key==='export')add('Box / dispatch',vals('Box number','Dispatch number','Shipment reference').join(', '));
      if(g.key==='stock_return'||g.key==='rework')add('Reason',vals('Reason').join('; '));
      return '<li class="journey-summary-step"><span class="journey-step-number">'+(index+1)+'</span><div><h3>'+esc(title)+'</h3><p class="journey-step-meta">'+esc(when)+(actors.length?' · '+esc(actors.join(', ')):'')+'</p>'+(facts.length?'<p class="journey-step-facts">'+facts.join(' · ')+'</p>':'')+'</div></li>';
    }).join('');
    return html?'<ol class="stock-journey-compact">'+html+'</ol>':'<p>No dated stages recorded yet. See Full activity for the saved records.</p>';
  }
  root.GREENLOOP_STOCK_JOURNEY={group,render};
})(typeof window==='object'?window:globalThis);
