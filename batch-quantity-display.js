/* Display-only receipt quantities. Canonical batch IDs, values and records stay raw. */
(() => {
 'use strict';
 const valid=n=>(typeof n==='number'||typeof n==='string'&&/^\d+$/.test(n))&&Number.isSafeInteger(Number(n))&&Number(n)>=0;
 const raw=v=>String(v??'').trim().replace(/-\(\d+\)$/,'');
 const hints=new Map();let catalogue=null,index=new Map(),pattern=null,scheduled=false;
 const targets=new Set();
 function quantity(row,key){return valid(row?.[key])?Number(row[key]):null;}
 function rebuild(){
  const rows=window.GREENLOOP_STOCK?.rows||[];
  if(catalogue===rows)return;catalogue=rows;index=new Map(hints);
  const grouped=new Map();
  for(const row of rows){const key=raw(row.batch_number);if(!key||!valid(row.received_quantity))continue;
   const old=grouped.get(key);grouped.set(key,old&&old.quantity!==Number(row.received_quantity)?{ambiguous:true}:{quantity:Number(row.received_quantity),ambiguous:old?.ambiguous||false});
  }
  for(const[key,row]of grouped)if(row.ambiguous)index.delete(key);else index.set(key,row.quantity);
  const keys=[...index.keys()].sort((a,b)=>b.length-a.length).map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'));
  pattern=keys.length?new RegExp('(^|[^A-Za-z0-9_-])('+keys.join('|')+')(?:-\\(\\d+\\))?(?![A-Za-z0-9_-])','g'):null;
 }
 function batchLabel(value,receipt=null,fallback='—'){
  const number=raw(typeof value==='object'&&value?value.batch_number:value);
  if(!number)return fallback;rebuild();
  let qty=index.get(number);
  // A caller may supply an explicit receipt quantity, never a model subgroup total.
  if(qty===undefined&&raw(receipt?.batch_number)===number)qty=quantity(receipt,'receipt_quantity');
  return qty===undefined||qty===null?number:number+'-('+qty+')';
 }
 function text(value){
  const valueText=String(value??'');if(!valueText.includes('BATCH')&&!valueText.includes('batch')){
   // Custom historical batch names are still supported after the index is built.
   rebuild();if(!pattern)return valueText;
  }else rebuild();
  if(!pattern)return valueText;pattern.lastIndex=0;
  return valueText.replace(pattern,(_,prefix,number)=>prefix+number+'-('+index.get(number)+')');
 }
 function rawText(value){
  const valueText=String(value??'');rebuild();if(!pattern)return valueText;pattern.lastIndex=0;
  return valueText.replace(pattern,(_,prefix,number)=>prefix+number);
 }
 function readArgs(args){
  if(!args||typeof args!=='object'||Array.isArray(args))return args;
  const result={...args};
  for(const key of ['p_identifier','p_query','p_search','p_batch_number'])if(typeof result[key]==='string')result[key]=rawText(result[key]);
  if(args.p_filters&&typeof args.p_filters==='object'&&!Array.isArray(args.p_filters)){
   result.p_filters={...args.p_filters};for(const key of ['_search','query','batch_number'])if(typeof result.p_filters[key]==='string')result.p_filters[key]=rawText(result.p_filters[key]);
  }
  return result;
 }
 function remember(data){
  const seen=new WeakSet();let changed=false;
  function visit(value,parent=''){
   if(!value||typeof value!=='object'||seen.has(value))return;seen.add(value);
   if(Array.isArray(value)){value.forEach(v=>visit(v,parent));return;}
   const number=raw(value.batch_number);
   if(number){let qty=quantity(value,'receipt_quantity');
    if(qty===null&&['stocks','batches','receiving_batches','receiving_batch'].includes(parent)){
     qty=quantity(value,'received_quantity')??quantity(value,'stock_quantity')??quantity(value,'planned_quantity');
    }
    // Received replacement receipt documents carry their own original quantity.
    if(qty===null&&parent==='receipts'&&value.batch_id&&value.received_at&&value.invoice_number)qty=quantity(value,'quantity');
    if(qty!==null&&hints.get(number)!==qty){hints.set(number,qty);changed=true;}
   }
   for(const[key,child]of Object.entries(value))visit(child,key);
  }
  visit(data);if(changed){catalogue=null;queue(document.body);}
 }
 function skipped(node){return node.parentElement?.closest('script,style,textarea,input,code,pre,mark[data-greenloop-match],[contenteditable]:not([contenteditable="false"]),[data-batch-raw]');}
 function decorateNode(node){
  if(node.nodeType!==3||!node.nodeValue||skipped(node))return;
  const before=node.nodeValue,after=text(before);if(after===before)return;
  const option=node.parentElement?.closest('option');
  // Options without a value attribute normally derive their value from the text.
  // Preserve that original value before decorating the label.
  if(option&&!option.hasAttribute('value'))option.setAttribute('value',option.value);
  node.nodeValue=after;
 }
 function refresh(root=document.body){
  if(!root)return;if(root.nodeType===3){decorateNode(root);return;}
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let node;
  while((node=walker.nextNode()))decorateNode(node);
  const elements=root.nodeType===1?[root,...root.querySelectorAll('[title],[aria-label]')]:[];
  for(const el of elements){if(el.closest('script,style,textarea,input,[contenteditable]:not([contenteditable="false"]),[data-batch-raw]'))continue;
   for(const name of ['title','aria-label']){const before=el.getAttribute(name);if(before){const after=text(before);if(after!==before)el.setAttribute(name,after);}}
  }
 }
 function queue(root){if(!root)return;targets.add(root);if(scheduled)return;scheduled=true;queueMicrotask(()=>{
  scheduled=false;const work=[...targets];targets.clear();for(const root of work)if(root.isConnected)refresh(root);
 });}
 function start(){
  if(!document.body)return;queue(document.body);
  new MutationObserver(records=>{for(const r of records){if(r.type==='childList')r.addedNodes.forEach(queue);else queue(r.target);}})
   .observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['title','aria-label']});
 }
 function clear(){hints.clear();catalogue=null;index.clear();pattern=null;}
 window.GREENLOOP_BATCH_LABEL=batchLabel;window.GREENLOOP_BATCH_TEXT=text;
 window.GREENLOOP_BATCH_DISPLAY={refresh,remember,clear,readArgs};
 window.addEventListener('beforeprint',()=>refresh());
 for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,clear);
 if(document.body)start();else document.addEventListener('DOMContentLoaded',start,{once:true});
})();
