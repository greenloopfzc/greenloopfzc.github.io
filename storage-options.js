/* Storage labels and order; database/intake values remain whole GB. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.GREENLOOP_STORAGE=api;})(typeof window==='undefined'?globalThis:window,()=>{
 'use strict';
 function parse(value){const m=String(value??'').trim().toUpperCase().replace(/\s+/g,'').match(/^([0-9]+)(GB|TB)?$/);if(!m)return null;const n=Number(m[1])*(m[2]==='TB'?1024:1);return Number.isSafeInteger(n)&&n>0&&n<=2147483647?n:null;}
 function label(value){const n=parse(value);return n===null?String(value??'').trim():n>=1024&&n%1024===0?`${n/1024} TB`:`${n} GB`;}
 function compare(a,b){const x=parse(a),y=parse(b);if(x!==null&&y!==null)return x-y||String(a).localeCompare(String(b),'en',{numeric:true});if(x!==null)return -1;if(y!==null)return 1;return String(a).localeCompare(String(b),'en',{numeric:true});}
 return Object.freeze({parse,label,compare});
});
