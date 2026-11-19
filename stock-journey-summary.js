/* Compact journey presentation. Uses recorded milestones; never changes saved data. */
(function(root){
  'use strict';
  const text=v=>String(v??'').trim(), norm=v=>text(v).toLowerCase().replace(/_/g,' ');
  const field=(row,...names)=>text((row.details||[]).find(d=>names.some(n=>norm(n)===norm(d.label)))?.value);
  const stamp=r=>{const v=text(r.occurred_at);if(!/[T ]\d{2}:\d{2}/.test(v)||!/(?:Z|[+-]\d{2}(?::?\d{2})?)$/i.test(v))return null;const t=Date.parse(v);return Number.isFinite(t)?t:null;};
  const prefix=r=>text(r.id).split(':')[0];
  const titles={chaman_send:'Greenloop → Chaman — Dispatched',chaman_shop_receive:'Chaman — Stock received',chaman_return_send:'Chaman → Greenloop — Return dispatched',chaman_company_receive:'Greenloop — Return received',chaman_admin_correction:'Chaman — Transfer correction',correction:'Reports correction',stock_received:'Stock Received',imei_entry:'IMEI Entry',initial_qc:'Initial QC',parts:'Parts',qc_issuance:'Lab & Glass Issuance',laboratory:'Lab & Glass',glass:'Lab & Glass',final_qc:'Final QC',frame:'B-DEPT',ready_stock:'Ready Stock',export:'Verified Export',box_entry:'Box Entry',accounts_pending:'Accounts Pending',box_recheck:'Box Re-check',box_history:'Box Scan History (not exported)',export_history:'Verified Export History',stock_return:'Stock Return',rework:'Rework',other:'Recorded activity'};
  function place(v){
    const n=norm(v).replace(/[-–—]/g,' ').replace(/\s+/g,' ');
    if(/^(?:lab\s*(?:&|and)\s*glass issuance|qc issuance|issuance)$/.test(n))return 'qc_issuance';
    if(/^(laboratory|lab|lab & glass|lab and glass)$/.test(n))return 'laboratory';
    if(n==='glass')return 'glass';
    if(n.includes('initial qc'))return 'initial_qc';if(n.includes('final qc'))return 'final_qc';
    if(n.includes('frame')||n.includes('b dept'))return 'frame';
    if(n==='production'||n==='production department'||n.includes('ready stock'))return 'ready_stock';
    if(n==='parts'||n==='parts department')return 'parts';if(n.startsWith('rework'))return 'rework';
    if(n.startsWith('stock received'))return 'stock_received';if(n.startsWith('imei entry'))return 'imei_entry';
    if(n.startsWith('returned to supplier')||n.startsWith('stock return')||n.startsWith('supplier return'))return 'stock_return';
    if(n.startsWith('box re check')||n.startsWith('box recheck'))return 'box_recheck';
    if(n.startsWith('box entry'))return 'box_entry';if(n.startsWith('accounts pending'))return 'accounts_pending';
    if(/export|outbound/.test(n))return 'export';return '';
  }
  function recordedDestination(r){
    // Exact recorded routing events distinguish Issuance from its shared QC location.
    const name=norm(r.title).replace(/[-–—]/g,' ').replace(/\s+/g,' ');
    const reason=field(r,'Reason','Movement reason');
    const route=reason.match(/^(?:B[- ]DEPT|B Department|Frame(?: Department)?) passed to (Lab\s*(?:&|and)\s*Glass Issuance|Initial QC)$/i)
      ||name.match(/^(?:b dept|b department|frame(?: department)?) passed (?:to )?(lab\s*(?:&|and)\s*glass issuance|issuance|initial qc)$/);
    return route?place(route[1]):'';
  }
  function kind(r){
    if(prefix(r)==='chaman-event'&&['send','shop_receive','return_send','company_receive','admin_correction'].includes(text(r.status)))return 'chaman_'+text(r.status);
    if(r.report_correction===true||norm(r.stage)==='correction'||norm(r.status)==='admin correction')return 'correction';
    if(r.automatic_direct_bdept===true)return 'support';
    if(r.direct_bdept_transfer===true)return 'frame';
    const id=prefix(r),s=norm(r.stage),t=norm(r.title);
    if(s==='qc issuance'||s==='lab & glass issuance'||s==='lab and glass issuance'||t==='lab & glass issuance')return 'qc_issuance';
    if(prefix(r)==='event'&&recordedDestination(r))return recordedDestination(r);
    if(['box entry','accounts pending','box recheck','box history','export history'].includes(s))return s.replace(/ /g,'_');
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
    if(id==='frame'||s==='frame'||/^(?:frame|b-dept)/.test(t))return 'frame';
    if(id==='supplier-return'||s==='stock return')return 'stock_return';
    if(id==='export-box')return 'box_history';
    if(id==='dispatch'||s==='export')return 'export';
    if(s==='rework')return 'rework';
    if(/part|service/.test(id)||r.parts?.length||/part|service|line saved/.test(t))return 'support';
    if(/laboratory|glass/.test(s+' '+id+' '+t))return /glass/.test(s+' '+id+' '+t)?'glass':'laboratory';
    return 'other';
  }
  function target(r){return recordedDestination(r)||place(field(r,'Destination','Next department','Next step','To','Department'))||(/ready stock/i.test(field(r,'Reason'))?'ready_stock':'');}
  // actor is the subject technician on these saved snapshots, not the operator.
  function actorLabel(r){return r.stage==='assignment'?'Assigned technician':/^(?:timer-|laboratory-(?:start|complete)|glass-(?:start|complete))/.test(prefix(r))?'Technician':r.automatic_direct_bdept?'Transfer action by':'By';}
  function moment(value){
    const v=text(value),dateOnly=/^\d{4}-\d{2}-\d{2}$/.test(v);
    if(!v)return 'Not recorded';
    const t=Date.parse(dateOnly?v+'T00:00:00Z':v);
    if(!Number.isFinite(t))return 'Not recorded';
    if(dateOnly)return new Intl.DateTimeFormat('en-GB',{timeZone:'UTC',day:'2-digit',month:'short',year:'numeric'}).format(t)+' · Time: Not recorded';
    // Do not interpret an unzoned clock using the viewer laptop's timezone.
    if(!/[T ]\d{2}:\d{2}/.test(v)||!/(?:Z|[+-]\d{2}(?::?\d{2})?)$/i.test(v))return 'Not recorded';
    return new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Dubai',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:true}).format(t)+' · UAE';
  }
  function precise(r){
    const v=text(r.occurred_at),at=stamp(r);
    if(at===null)return null;
    const fraction=(v.match(/\.(\d+)(?:Z|[+-]\d{2}(?::?\d{2})?)$/i)||[])[1]||'';
    return BigInt(at)*1000000n+BigInt((fraction.padEnd(9,'0').slice(3,9))||'0');
  }
  function orderTies(items){
    // Only explicit saved From/To or inspection destination evidence supplies
    // causal edges. A department's nominal workflow rank is not a timestamp.
    const edges=items.map(()=>new Set()),indegree=items.map(()=>0);
    const edge=(a,b)=>{if(a!==b&&!edges[a].has(b)){edges[a].add(b);indegree[b]++;}};
    items.forEach((e,i)=>{
      const r=e.row,k=kind(r),job=text(r.job_number);
      if(!job)return;
      let from=k==='movement'?place(field(r,'From')):'',to=target(r);
      if(from==='frame'&&to==='initial_qc'){
        const proof=[...new Set(items.filter(x=>text(x.row.job_number)===job).map(x=>recordedDestination(x.row)).filter(Boolean))];
        if(proof.length===1)to=proof[0];
      }
      items.forEach((other,j)=>{
        if(text(other.row.job_number)!==job||other.row.automatic_direct_bdept)return;
        const otherKind=kind(other.row);
        if(k==='movement'){
          if(from&&otherKind===from)edge(j,i);
          if(/^receiving$/i.test(field(r,'From'))&&['laboratory','glass'].includes(to)&&otherKind==='initial_qc')edge(j,i);
          if(to&&otherKind===to)edge(i,j);
        }else if(to&&to!==k&&otherKind===to)edge(i,j);
        if(r.direct_bdept_transfer&&otherKind==='initial_qc')edge(j,i);
      });
    });
    const result=[],used=new Set();
    while(result.length<items.length){
      const i=items.findIndex((_,i)=>!used.has(i)&&indegree[i]===0);
      // Contradictory equal-time routes have no defensible exact sequence.
      if(i<0)return items;
      used.add(i);result.push(items[i]);for(const j of edges[i])indegree[j]--;
    }
    return result;
  }
  function activity(rows){
    const source=(Array.isArray(rows)?rows:[]).filter(r=>r&&typeof r==='object');
    const when=r=>stamp(r),same=(a,b)=>text(a.job_number)&&text(a.job_number)===text(b.job_number)&&precise(a)!==null&&precise(a)===precise(b);
    const direct=r=>r.direct_bdept_transfer===true||prefix(r)==='event'&&/^initial qc sent phone directly to (?:frame(?: department)?|b[- ]dept)$/i.test(text(r.title));
    const decorated=source.map((r,index)=>{
      const row={...r,details:(Array.isArray(r.details)?r.details:[]).map(d=>({...d}))};
      const isDirect=direct(r);
      const note=field(r,'Notes');
      // Require the explicit direct-route marker or a matching direct-transfer
      // event. A normal Final QC pass at the same time is never suppressed.
      const automatic=r.automatic_direct_bdept===true||prefix(r)==='final-qc'&&/Initial QC direct route to Frame/.test(note)
        ||source.some(d=>direct(d)&&same(d,r))&&(
          prefix(r)==='movement'&&/^(Initial QC completed\s*[-–—]\s*no repair required|Final QC routed to Frame for required work)$/.test(field(r,'Reason','Movement reason'))
          ||prefix(r)==='event'&&/^Final QC sent to (Frame|B-DEPT)$/i.test(text(r.title)));
      if(isDirect){row.direct_bdept_transfer=true;row.stage='frame';row.display_title='Initial QC — Direct transfer to B-DEPT';}
      if(automatic){
        row.automatic_direct_bdept=true;
        row.display_title=prefix(r)==='movement'?'Automatic location update — direct B-DEPT route':'Automatic routing record — direct B-DEPT route';
        if(!field(row,'Record meaning'))row.details.push({label:'Record meaning',value:'Created automatically for the direct Initial QC → B-DEPT transfer; not a separate Final QC inspection.'});
        if(!field(row,'Original recorded title'))row.details.push({label:'Original recorded title',value:text(r.title)});
      }
      return {row,index,at:when(r)};
    });
    const ordered=decorated.sort((a,b)=>{
      const x=precise(a.row),y=precise(b.row);
      return x===null?(y===null?a.index-b.index:1):y===null?-1:x<y?-1:x>y?1:a.index-b.index;
    });
    for(let start=0;start<ordered.length;){
      let end=start+1;const at=precise(ordered[start].row);
      while(at!==null&&end<ordered.length&&precise(ordered[end].row)===at)end++;
      if(at!==null&&end-start>1){
        const ties=orderTies(ordered.slice(start,end));
        ties.forEach((e,n)=>{e.row.same_time=true;ordered[start+n]=e;});
      }
      start=end;
    }
    return ordered.map(e=>e.row);
  }

  function group(rows){
    const entries=activity(rows).map((row,index)=>({row,index,at:stamp(row),kind:kind(row),job:text(row.job_number)}));
    const ordered=entries; // Same canonical order as Full activity; never re-rank stages.
    const sections=[],support=[],visits=new Map();let current=null;
    function add(e,key){
      if(!current||current.key!==key||current.job!==e.job){
        const visitKey=e.job+'|'+key,visit=(visits.get(visitKey)||0)+1;visits.set(visitKey,visit);
        const rework=e.kind==='rework'||/rework|returned for/.test(norm(field(e.row,'Reason')))||(current?.job===e.job&&current.key==='final_qc'&&current.anchors.some(r=>norm(r.status)==='fail'));
        current={key,job:e.job,at:e.at,index:e.index,visit,rework,rows:[],anchors:[]};sections.push(current);
      }
      current.rows.push(e.row);current.anchors.push(e.row);
    }
    for(const e of ordered){
      if(e.at===null||e.kind==='support'||e.kind==='other'){support.push(e);continue;}
      if(e.kind==='movement'){
        let destination=target(e.row);
        if(destination==='initial_qc'&&place(field(e.row,'From'))==='frame'){
          const proof=ordered.filter(other=>other.job&&other.job===e.job&&other.at===e.at&&prefix(other.row)==='event').map(other=>recordedDestination(other.row)).filter(Boolean);
          const destinations=[...new Set(proof)];if(destinations.length===1)destination=destinations[0];
        }
        const existing=sections.find(g=>g.job===e.job&&g.key===destination&&g.at===e.at&&precise(g.anchors[0])===precise(e.row));
        if(existing&&!['laboratory','glass'].includes(destination))existing.rows.push(e.row);
        else if(destination)add(e,destination);else if(current&&current.job===e.job)current.rows.push(e.row);else support.push(e);
      }else if(e.kind==='rework'){add(e,target(e.row)||'rework');}
      else add(e,e.kind);
    }
    for(const e of support){
      const r=e.row,id=prefix(r);
      let wanted=place(field(r,'Department'))||(/glass/.test(id+' '+norm(r.stage))?'glass':/laboratory|manual-part|part-installation|service/.test(id+' '+norm(r.stage))?'laboratory':'');
      const candidates=sections.filter(g=>g.job===e.job&&(!wanted||g.key===wanted));
      // Prefer the preceding visit. If the arrival record is absent, the first
      // completion can supply context, but never across a saved QC failure.
      const preceding=candidates.filter(g=>g.at<e.at||g.at===e.at&&g.index<=e.index);
      const next=candidates.find(g=>g.at>=e.at&&!sections.some(x=>x.job===e.job&&x.index>e.index&&x.index<g.index&&x.anchors.some(r=>norm(r.status)==='fail')));
      const nearest=e.at===null?null:preceding.at(-1)||next;
      if(nearest)nearest.rows.push(r);
      else if(e.at!==null&&wanted&&!sections.some(g=>g.job===e.job&&g.key===wanted)){
        sections.push({key:wanted,job:e.job,at:e.at,index:e.index,visit:1,rows:[r],anchors:[r]});
      }
    }
    return sections.map((section,index)=>({section,index})).sort((a,b)=>a.section.index-b.section.index||a.index-b.index).map(item=>item.section);
  }
  function render(rows,options){
    const esc=options.escape, date=options.date,money=options.money;
    const unique=values=>[...new Set(values.map(text).filter(v=>v&&v!=='Not recorded'))];
    const groups=group(rows),currentLabel=text(options.currentStage),currentKey=place(currentLabel);
    const currentNote=()=>'<p class="journey-step-current">Current stage: <strong>'+esc(currentLabel)+'</strong></p>';
    const html=groups.map((g,index)=>{
      const vals=(...names)=>unique(g.rows.map(r=>field(r,...names)));
      const inspections=g.anchors.filter(r=>/^(pass|fail)$/i.test(text(r.status)));
      const displayRows=g.anchors;
      const actors=unique(displayRows.map(r=>actorLabel(r)+': '+(text(r.actor)||'Not recorded')));
      let when=date(g.anchors[0]?.occurred_at);
      if(g.anchors.some(r=>r.same_time))when+=' · Same time';
      if(g.anchors.at(-1)?.occurred_at!==g.anchors[0]?.occurred_at)when+=' → '+date(g.anchors.at(-1)?.occurred_at);
      const results=unique(g.anchors.map(r=>/^(pass|fail)$/i.test(text(r.status))?norm(r.status):''));
      const suffix=results.length?' — '+results.map(r=>r==='pass'?'Pass':'Fail').join(' → '):'';
      const title=(g.key==='frame'&&g.anchors.some(r=>r.direct_bdept_transfer)&&!inspections.length?'B-DEPT — Direct transfer':titles[g.key]||titles.other)+(['laboratory','glass'].includes(g.key)&&g.rework?' Rework':'')+suffix+(g.visit>1?' · Visit '+g.visit:'');
      const facts=[];const add=(label,value)=>{if(value)facts.push('<span><strong>'+esc(label)+':</strong> '+esc(value)+'</span>');};
      if(g.key==='stock_received'){add('Stock/Batch No',vals('Receipt','Batch').join(', '));add('Invoice',vals('Invoice').join(', '));add('Supplier',vals('Supplier code','Supplier name').join(', '));}
      if(g.key==='initial_qc'){for(const label of ['Supplier grade (current saved)','GL grade (current saved)','Saved parts requirements','Saved service requirements'])add(label,vals(label).join('; '));add('Findings',vals('Findings','Problems').join('; '));}
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
      if(['export','export_history','box_entry','accounts_pending','box_recheck','box_history'].includes(g.key)){add('Box / dispatch',vals('Box number','Dispatch number','Shipment reference').join(', '));add('Record',vals('Stage meaning').join('; '));}
      if(['stock_return','rework','correction'].includes(g.key))add('Reason',vals('Reason').join('; '));
      return '<li class="journey-summary-step'+(g.key==='correction'?' is-report-correction':'')+'"><span class="journey-step-number">'+(index+1)+'</span><div><h3>'+esc(title)+'</h3><p class="journey-step-meta">'+esc(when)+(actors.length?' · '+esc(actors.join(', ')):'')+'</p>'+(facts.length?'<p class="journey-step-facts">'+facts.join(' · ')+'</p>':'')+(currentKey&&index===groups.length-1&&g.key===currentKey?currentNote():'')+'</div></li>';
    }).join('');
    const currentTail=currentKey&&groups.at(-1)?.key!==currentKey?'<li class="journey-summary-step journey-current-step"><span class="journey-step-number">'+(groups.length+1)+'</span><div><h3>'+esc(currentLabel)+'</h3>'+currentNote()+'</div></li>':'';
    return html||currentTail?'<ol class="stock-journey-compact">'+html+currentTail+'</ol>':'<p>No dated stages recorded yet. See Full activity for the saved records.</p>';
  }
  root.GREENLOOP_STOCK_JOURNEY={activity,group,render,moment,actorLabel};
})(typeof window==='object'?window:globalThis);
