/* GreenLoop 60 x 40 mm phone label. Code 128 symbol widths follow ISO/IEC 15417;
 * widths cross-checked against the installed ReportLab Code128 encoder. */
(() => {
  'use strict';
  const patterns=["212222","222122","222221","121223","121322","131222","122213","122312","132212","221213","221312","231212","112232","122132","122231","113222","123122","123221","223211","221132","221231","213212","223112","312131","311222","321122","321221","312212","322112","322211","212123","212321","232121","111323","131123","131321","112313","132113","132311","211313","231113","231311","112133","112331","132131","113123","113321","133121","313121","211331","231131","213113","213311","213131","311123","311321","331121","312113","312311","332111","314111","221411","431111","111224","111422","121124","121421","141122","141221","112214","112412","122114","122411","142112","142211","241211","221114","413111","241112","134111","111242","121142","121241","114212","124112","124211","411212","421112","421211","212141","214121","412121","111143","111341","131141","114113","114311","411113","411311","113141","114131","311141","411131","211412","211214","211232","2331112"];
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function symbols(imei){
    if(!/^\d{15}$/.test(String(imei)))throw Error('A 15-digit IMEI 1 is required for the label.');
    const codes=[105];for(let i=0;i<14;i+=2)codes.push(Number(imei.slice(i,i+2)));
    codes.push(100,imei.charCodeAt(14)-32);
    codes.push(codes.reduce((sum,n,i)=>sum+n*(i||1),0)%103,106);return codes;
  }
  function barcode(imei){
    const codes=symbols(imei),unit=.254,quiet=2.54;
    const width=codes.reduce((n,code)=>n+[...patterns[code]].reduce((s,w)=>s+Number(w),0)*unit,quiet*2);
    let x=(60-width)/2+quiet;let bars='';for(const code of codes){[...patterns[code]].forEach((n,i)=>{const w=Number(n)*unit;if(i%2===0)bars+=`<rect x="${x.toFixed(4)}" y="17.2" width="${w.toFixed(4)}" height="6.4"/>`;x+=w;});}
    if(width>56)throw Error('The IMEI barcode exceeds the label width.');return bars;
  }
  const measure=document.createElement('canvas').getContext('2d');
  function text(x,y,value,size,bold=false,anchor='start',width=56){
    const s=String(value??'').trim();measure.font=`${bold?'bold ':''}${size}px Arial`;
    const available=width*72/25.4;const fitted=Math.min(size,available/Math.max(1,measure.measureText(s).width)*size);
    return `<text x="${x}" y="${y}" font-family="Arial,Helvetica,sans-serif" font-size="${(fitted*25.4/72).toFixed(4)}" font-weight="${bold?'700':'400'}" text-anchor="${anchor}">${esc(s)}</text>`;
  }
  function svg(entry){
    const d={...entry};const bars=barcode(String(d.imei||''));
    const storage=window.GREENLOOP_STORAGE?.label(d.storageGb)||`${d.storageGb} GB`;
    let grid='<rect x="2" y="28.4" width="56" height="9.6" fill="none"/><path d="M2 33.2H58';
    for(let i=0;i<6;i++){const x=14+i*44/6;grid+=`M${x.toFixed(4)} 28.4V38`;}grid+='"/>';
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40" width="60mm" height="40mm" role="img" aria-label="Phone label for IMEI ${esc(d.imei)}"><rect width="60" height="40" fill="white"/><g fill="black">`+
      text(2,4.6,'GREENLOOP',9.4,true,'start',26)+text(58,4.4,'FZC / DEVICE LABEL',4.2,false,'end',27)+
      '<path d="M2 6.1H58" stroke="black" stroke-width=".106"/>'+
      text(2,9.7,d.model,8.8,true)+text(2,12.8,storage,6.5,true,'start',17)+text(58,12.8,d.color,6.4,false,'end',36)+
      text(2,15.8,'SN: '+(d.serialNumber||'Not recorded'),5.4,false,'start',26)+text(58,15.8,'REGION: '+(d.phoneRegion||'Not recorded'),5.3,false,'end',28)+bars+
      text(30,26,'IMEI 1: '+d.imei,6.6,true,'middle')+
      `<g stroke="black" stroke-width=".141" fill="none">${grid}</g>`+
      text(8,31.43,'PARTS',5.2,true,'middle',11)+text(8,36.23,'SERVICE',5.2,true,'middle',11)+'</g></svg>';
  }
  function openWindow(){
    const w=window.open('','_blank','width=760,height=650');if(!w)return null;
    w.opener=null;w.document.open();w.document.write('<!doctype html><title>Preparing phone label</title><p style="font:16px Arial;padding:24px">Waiting for the phone to save. No label has been printed.</p>');w.document.close();return w;
  }
  function print(entry,w=openWindow()){
    if(!w||w.closed)throw Error('The phone is saved. Allow pop-ups, then use Reprint Last Label.');
    const label=svg(entry);w.document.open();w.document.write(`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>GreenLoop label - ${esc(entry.imei)}</title><style>@page{size:60mm 40mm;margin:0}*{box-sizing:border-box}html,body{margin:0;padding:0;background:white;color:black}.phone-label{width:60mm;height:40mm;line-height:0}.phone-label svg{display:block;width:60mm;height:40mm}.tools{padding:20px;font:14px Arial;max-width:650px}.tools button{padding:10px 18px;cursor:pointer} @media screen{body{padding:24px;background:#e6edef}.phone-label{box-shadow:0 4px 16px #0002}}@media print{html,body{width:60mm;height:40mm;overflow:hidden}.tools{display:none} .phone-label{break-inside:avoid;break-after:avoid}}</style></head><body><div class="phone-label">${label}</div><div class="tools"><p>Phone saved to Initial QC. Label: 60 x 40 mm. Choose your label printer, paper 60 x 40 mm, Actual size / 100%, no margins or headers.</p><button id="print-label" type="button">Print label</button></div></body></html>`);w.document.close();
    const run=()=>{if(!w.closed){w.focus();w.print();}};w.document.getElementById('print-label').onclick=run;
    Promise.resolve(w.document.fonts?.ready).then(()=>w.requestAnimationFrame(()=>w.requestAnimationFrame(run)));return w;
  }
  window.GREENLOOP_PHONE_LABEL={svg,symbols,openWindow,print};
})();
