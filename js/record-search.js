(() => {
  "use strict";
  const clean = value => value == null ? "" : String(value).trim();
  const widgets = new WeakMap();
  let sequence = 0;
  function fields(item) {
    return [item.identifier,item.device_number,item.imei_1,item.imei_2,item.serial_number,item.job_number,
      item.invoice_number,item.batch_number,item.supplier_code,
      window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? item.supplier_name : "",item.brand,item.model,item.color,item.storage_gb,item.region,item.specification_region,item.current_status,
      ...(Array.isArray(item.search_values)?item.search_values:[])];
  }
  function localLookup(items, query) {
    const term = clean(query).toLocaleLowerCase();
    if (!term) return {items:[],has_more:false,exact_match:false};
    const ranked = items.map((item,index) => {
      const values = fields(item).map(value=>clean(value).toLocaleLowerCase()).filter(Boolean);
      return {item,index,rank:values.includes(term)?0:values.some(value=>value.startsWith(term))?1:values.some(value=>value.includes(term))?2:3};
    }).filter(row=>row.rank<3).sort((a,b)=>a.rank-b.rank || a.index-b.index);
    const exact = ranked.some(row=>row.rank===0);
    return {items:ranked.filter(row=>!exact || row.rank===0).map(row=>row.item),has_more:false,exact_match:exact};
  }
  async function rpc(name,args) {
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_CAN_SEARCH === false) throw new Error("Your account does not have IMEI Search permission.");
    let timeout;
    try {
      const response = await Promise.race([
        window.GREENLOOP_GET_CLIENT().rpc(name,args),
        new Promise((_,reject)=>{ timeout=setTimeout(()=>reject(new Error("Search is taking too long. Please try again.")),20000); })
      ]);
      if (response.error) {
        if (["PGRST202","42883"].includes(response.error.code)) throw new Error("The Search update needs to be installed. Contact your administrator.");
        throw new Error(response.error.message || "Search could not be loaded.");
      }
      const raw=response.data;
      return (Array.isArray(raw) ? raw[0]?.[name] || raw[0] : raw) || {};
    } finally { clearTimeout(timeout); }
  }
  const lookup = (query,offset=0) => rpc("search_greenloop_records_v1",{p_query:clean(query),p_offset:offset,p_limit:12});
  function openRecord(item) {
    const target=item.kind==="receipt" ? `receipt=${encodeURIComponent(item.id)}` : `q=${encodeURIComponent(item.identifier || item.device_number || item.imei_1)}`;
    window.location.assign(`imei-search.html?${target}`);
  }
  function textElement(tag,className,value) {
    const element=document.createElement(tag); element.className=className; element.textContent=clean(value); return element;
  }
  function describe(item) {
    const receipt=item.kind==="receipt";
    return {
      title:item.title || (receipt ? item.invoice_number || item.batch_number || item.identifier : item.imei_1 || item.device_number || item.identifier),
      meta:[receipt ? "Stock Received" : item.kind==="return" ? "Stock Return" : "Device",receipt ? item.batch_number : item.device_number,
        [item.brand,item.model,item.storage_gb ? `${item.storage_gb} GB` : "",item.color].filter(Boolean).join(" · ")].filter(Boolean).join(" · "),
      detail:[!receipt ? item.invoice_number : "",!receipt && item.serial_number ? `SN ${item.serial_number}` : "",item.job_number,item.supplier_code,window.GREENLOOP_CAN_VIEW_PARTNER_NAMES ? item.supplier_name : ""].filter(Boolean).join(" · ")
    };
  }
  function attach(input,options={}) {
    if (!input) return null;
    if (widgets.has(input)) return widgets.get(input);
    const id=`gl-record-search-${++sequence}`;
    const panel=textElement("div","gl-record-search-list",""); panel.id=id; panel.hidden=true;
    const list=textElement("div","gl-record-search-options",""); list.id=`${id}-options`; list.setAttribute("role","listbox"); list.setAttribute("aria-label","Matching records");
    const status=textElement("div","gl-record-search-status",""); status.setAttribute("role","status"); status.setAttribute("aria-live","polite");
    const more=textElement("button","gl-record-search-more","Show more matches"); more.type="button"; more.dataset.searchReadOnly="true"; more.hidden=true;
    panel.append(status,list,more); document.body.append(panel);
    input.setAttribute("role","combobox"); input.setAttribute("aria-autocomplete","list"); input.setAttribute("aria-controls",list.id); input.setAttribute("aria-expanded","false"); input.autocomplete="off";
    let timer,version=0,active=-1,items=[],nextOffset=0,lastQuery="",busy=false,destroyed=false;
    const listeners=[];
    const listen=(target,event,handler,settings)=>{target.addEventListener(event,handler,settings);listeners.push(()=>target.removeEventListener(event,handler,settings));};
    function position() {
      if(panel.hidden)return;
      const rect=input.getBoundingClientRect();
      const width=Math.min(Math.max(rect.width,360),window.innerWidth-24);
      panel.style.width=`${width}px`; panel.style.left=`${Math.max(12,Math.min(rect.left,window.innerWidth-width-12))}px`;
      const below=window.innerHeight-rect.bottom-12,above=rect.top-12;
      const up=below<230 && above>below;
      panel.style.maxHeight=`${Math.max(100,Math.min(410,up?above:below))}px`;
      panel.style.top=up ? "auto" : `${rect.bottom+6}px`;
      panel.style.bottom=up ? `${window.innerHeight-rect.top+6}px` : "auto";
    }
    function show() {panel.hidden=false;input.setAttribute("aria-expanded","true");position();}
    function close() {++version;clearTimeout(timer);busy=false;panel.hidden=true;input.setAttribute("aria-expanded","false");input.removeAttribute("aria-activedescendant");active=-1;}
    function select(index) {
      const item=items[index]; if(!item)return;
      ++version;clearTimeout(timer);busy=false;close();
      (options.onSelect || openRecord)(item);
    }
    function highlight(index) {
      active=index;
      [...list.children].forEach((element,i)=>element.setAttribute("aria-selected",String(i===active)));
      const element=list.children[active];
      if(element){input.setAttribute("aria-activedescendant",element.id);element.scrollIntoView({block:"nearest"});}
      else input.removeAttribute("aria-activedescendant");
    }
    function render() {
      list.replaceChildren();active=-1;input.removeAttribute("aria-activedescendant");
      items.forEach((item,index)=>{
        const row=textElement("div","gl-record-search-option","");row.id=`${id}-${index}`;row.setAttribute("role","option");row.setAttribute("aria-selected","false");
        const info=describe(item);
        row.append(textElement("strong","",info.title),textElement("span","",info.meta));
        if(info.detail)row.append(textElement("small","",info.detail));
        row.addEventListener("mousedown",event=>event.preventDefault());row.addEventListener("click",()=>select(index));list.append(row);
      });
    }
    async function search({append=false,selectExact=false}={}) {
      clearTimeout(timer);
      const term=clean(input.value); if(!term){++version;close();return;}
      const currentVersion=++version;
      if(!append){items=[];list.replaceChildren();active=-1;input.removeAttribute("aria-activedescendant");nextOffset=0;}
      lastQuery=term;busy=true;more.hidden=true;status.textContent="Searching…";show();
      try {
        const data=await (options.lookup || lookup)(term,append?nextOffset:0);
        if(destroyed || currentVersion!==version || clean(input.value)!==term)return;
        const incoming=Array.isArray(data?.items)?data.items:[];
        items=append ? [...items,...incoming] : incoming;
        // Duplicates can occur if the underlying records change between pages.
        items=items.filter((item,i,all)=>all.findIndex(other=>`${other.kind}:${other.id || other.identifier}`===`${item.kind}:${item.id || item.identifier}`)===i);
        nextOffset=Number(data.next_offset) || items.length;
        busy=false;render();more.hidden=!data.has_more;
        status.textContent=items.length ? `${items.length}${data.has_more?"+":""} matching record${items.length===1 && !data.has_more?"":"s"} · choose one to open` : "No matching records found.";
        if(selectExact && data.exact_match && items.length===1){select(0);return items[0];}
        show();return data;
      } catch(error) {
        if(destroyed || currentVersion!==version || clean(input.value)!==term)return;
        busy=false;items=[];render();more.hidden=true;status.textContent=error.message || "Search failed. Please try again.";show();
      }
    }
    listen(input,"input",()=>{++version;clearTimeout(timer);busy=false;items=[];close();if(clean(input.value))timer=setTimeout(()=>search(),250);});
    listen(input,"keydown",event=>{
      if(event.key==="Escape"){++version;clearTimeout(timer);close();return;}
      if(event.key==="Tab"){++version;clearTimeout(timer);close();return;}
      if(event.key==="ArrowDown" || event.key==="ArrowUp") {
        event.preventDefault();if(panel.hidden){search();return;}
        if(items.length)highlight(active<0 ? (event.key==="ArrowDown"?0:items.length-1) : (active+(event.key==="ArrowDown"?1:-1)+items.length)%items.length);return;
      }
      if(event.key==="Enter") {
        event.preventDefault();event.stopImmediatePropagation();
        if(!panel.hidden && active>=0 && !busy)select(active);
        else search({selectExact:true});
      }
    },true);
    listen(more,"click",()=>{if(!busy && clean(input.value)===lastQuery)search({append:true});});
    listen(document,"pointerdown",event=>{if(event.target!==input && !panel.contains(event.target)){++version;clearTimeout(timer);close();}});
    listen(window,"resize",position);listen(window,"scroll",position,true);
    const removalObserver=new MutationObserver(()=>{if(!input.isConnected)api.destroy();});
    const api={search,close,destroy(){if(destroyed)return;destroyed=true;++version;clearTimeout(timer);removalObserver.disconnect();listeners.forEach(remove=>remove());panel.remove();widgets.delete(input);["role","aria-autocomplete","aria-controls","aria-expanded","aria-activedescendant"].forEach(name=>input.removeAttribute(name));}};
    removalObserver.observe(document.body,{childList:true,subtree:true});
    widgets.set(input,api);return api;
  }
  window.GREENLOOP_RECORD_SEARCH={attach,lookup,localLookup,openRecord,rpc,describe};
  window.dispatchEvent(new CustomEvent("greenloop:record-search-ready"));
})();
