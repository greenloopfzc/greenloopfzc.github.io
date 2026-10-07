/* ES5 controls; the PDF library is loaded only when a PDF is requested. */
(function () {
  'use strict';
  window.GREENLOOP_DAMAGE_EXPORT = function (api, onDenied, onOpen) {
    var get = function (id) { return document.getElementById(id); };
    var panel=get('damage-pdf-panel'),button=get('damage-pdf-toggle'),form=get('damage-pdf-form');
    var from=get('damage-pdf-from'),to=get('damage-pdf-to'),download=get('damage-pdf-download'),message=get('damage-pdf-message'),link=get('damage-pdf-file');
    var view=get('damage-pdf-view'),preview=get('damage-pdf-preview'),frame=get('damage-pdf-frame'),openLink=get('damage-pdf-open');
    var ticket=0,active=false,objectUrl=null,loadingScripts={};
    var today=new Date(new Date().getTime()+14400000),two=function(n){return n<10?'0'+n:String(n);};
    var day=today.getUTCFullYear()+'-'+two(today.getUTCMonth()+1)+'-'+two(today.getUTCDate());
    from.value=day.slice(0,8)+'01';to.value=day;
    function revoke(){preview.hidden=true;frame.textContent='';openLink.removeAttribute('href');if(objectUrl){window.URL.revokeObjectURL(objectUrl);objectUrl=null;}link.removeAttribute('href');link.style.display='none';}
    function close(){ticket++;panel.style.display='none';button.setAttribute('aria-expanded','false');download.disabled=false;view.disabled=false;from.disabled=false;to.disabled=false;revoke();message.textContent='';}
    function open(){if(!active)return;onOpen();panel.style.display='block';button.setAttribute('aria-expanded','true');from.focus();}
    function script(url,name){
      if(window[name])return Promise.resolve();
      if(loadingScripts[name])return loadingScripts[name];
      loadingScripts[name]=new Promise(function(resolve,reject){var element=document.createElement('script');element.src=url;
        element.onload=function(){if(window[name])resolve();else{loadingScripts[name]=null;reject(new Error('This browser cannot create PDFs. Open Damage Entry in an updated computer browser.'));}};
        element.onerror=function(){loadingScripts[name]=null;element.remove();reject(new Error('PDF tools could not load. Check your connection and retry.'));};document.head.appendChild(element);});
      return loadingScripts[name];
    }
    button.onclick=function(event){if(event)event.preventDefault();if(panel.style.display==='none')open();else close();};
    button.onkeydown=function(event){if(event.key===' '){event.preventDefault();button.click();}};get('damage-pdf-close').onclick=close;
    // Render the same measured PDF drawing commands as vector page previews.
    // This works even where the browser has no built-in embedded PDF viewer.
    function renderPreview(result){
      frame.textContent='';
      var ns='http://www.w3.org/2000/svg';
      function color(c){return 'rgb('+Math.round(c.red*255)+','+Math.round(c.green*255)+','+Math.round(c.blue*255)+')';}
      function node(tag,attrs){var el=document.createElementNS(ns,tag);Object.keys(attrs).forEach(function(key){el.setAttribute(key,attrs[key]);});return el;}
      result.previewPages.forEach(function(page,index){
        var svg=node('svg',{viewBox:'0 0 '+page.width+' '+page.height,role:'img','aria-label':'Damage Report PDF page '+(index+1)});
        svg.appendChild(node('rect',{x:0,y:0,width:page.width,height:page.height,fill:'white'}));
        page.ops.forEach(function(op){var el;
          if(op.kind==='text'){el=node('text',{x:op.x,y:page.height-op.y,'font-size':op.size,'font-family':'Helvetica, Arial, sans-serif','font-weight':op.bold?'bold':'normal',fill:color(op.color)});el.textContent=op.text;}
          else if(op.kind==='rect')el=node('rect',{x:op.x,y:page.height-op.y-op.height,width:op.width,height:op.height,fill:color(op.color),stroke:color(op.border),'stroke-width':.45});
          else if(op.kind==='line')el=node('line',{x1:op.x,y1:page.height-op.y,x2:op.x2,y2:page.height-op.y2,stroke:color(op.color),'stroke-width':.5});
          else if(op.kind==='logo'){el=node('image',{x:op.x,y:page.height-op.y-op.height,width:op.width,height:op.height});el.setAttributeNS('http://www.w3.org/1999/xlink','href','assets/looplogo.jpg');}
          if(el)svg.appendChild(el);
        });frame.appendChild(svg);
      });
    }
    function generate(action){
      if(!active||download.disabled)return false;
      if(!window.Promise||!window.fetch||!window.BigInt||!window.Blob||!window.URL||!window.URL.createObjectURL){message.textContent='Open Damage Entry in an updated computer browser to download the PDF.';return false;}
      if(!/^\d{4}-\d{2}-\d{2}$/.test(from.value)||!/^\d{4}-\d{2}-\d{2}$/.test(to.value)||from.value>to.value){message.textContent='Select a valid start and end date.';return false;}
      revoke();var request=++ticket;download.disabled=true;view.disabled=true;from.disabled=true;to.disabled=true;message.textContent='Preparing the complete report...';
      var start=from.value,end=to.value;
      function finish(){if(request===ticket){download.disabled=false;view.disabled=false;from.disabled=false;to.disabled=false;}}
      function failed(error){if(request!==ticket||!active)return;finish();message.textContent=error.message||'The PDF could not be created. Please retry.';}
      api.loadDamageExport(start,end,function(error,data){
        if(request!==ticket||!active)return;
        if(error){if(error.clearSession||/^(NO_SESSION|SESSION_EXPIRED|PERMISSION_DENIED)$/.test(error.code||'')){close();onDenied(error);}else failed(error);return;}
        Promise.all([script('js/vendor/pdf-lib-1.17.1.min.js','PDFLib'),script('js/damage-report-pdf.js?v=20261007-damage-pdf-view-1','GREENLOOP_DAMAGE_PDF'),
          fetch('assets/looplogo.jpg').then(function(response){if(!response.ok)throw new Error('Report logo did not load. Please retry.');return response.arrayBuffer();})])
          .then(function(results){if(request!==ticket||!active)return null;return window.GREENLOOP_DAMAGE_PDF.create(data,{logo:results[2]});})
          .then(function(result){if(!result||request!==ticket||!active)return;finish();
            objectUrl=window.URL.createObjectURL(new Blob([result.bytes],{type:'application/pdf'}));link.href=objectUrl;link.download=result.filename;link.style.display='inline-block';
            message.textContent=result.pages+' A4 '+result.orientation+' '+(result.pages===1?'page':'pages')+' ready. '+result.report.count+' entries; '+result.report.quantity+' damaged parts.'+(result.detailCount?' Long fields are included in the Full details section.':'');
            openLink.href=objectUrl;
            if(action==='view'){renderPreview(result);preview.hidden=false;preview.scrollIntoView({block:'start',behavior:'smooth'});}else link.click();
          }).catch(failed);
      });return false;
    };
    form.onsubmit=function(event){if(event)event.preventDefault();return generate('download');};
    view.onclick=function(){if(form.reportValidity())generate('view');};
    function invalidate(){ticket++;download.disabled=false;view.disabled=false;from.disabled=false;to.disabled=false;revoke();message.textContent='';}
    from.addEventListener('input',invalidate);to.addEventListener('input',invalidate);
    window.addEventListener('pagehide',close);
    return {setActive:function(value){active=value;button.disabled=!value;button.setAttribute('aria-disabled',String(!value));if(!value)close();else if(/[?&]download=1(?:&|$)/.test(window.location.search))open();}};
  };
}());
