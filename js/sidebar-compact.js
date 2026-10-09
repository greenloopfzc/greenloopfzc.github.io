/* Shared sidebar layout. Existing page navigation and access rules stay in charge. */
(() => {
  'use strict';
  const root=document.documentElement,key='greenloop-sidebar-compact-v1';
  const narrow=window.matchMedia('(max-width: 800px)');
  let preference=null;
  try {const value=localStorage.getItem(key);if(value==='1'||value==='0')preference=value==='1';}catch(_){}
  function mount(){
    const sidebar=document.getElementById('sidebar'),toggle=document.getElementById('open-menu');
    if(!sidebar||!toggle)return;
    const nav=sidebar.querySelector('.sidebar-nav'),backdrop=document.getElementById('menu-backdrop');
    let compact=narrow.matches?true:(preference??false);
    function apply(){
      root.dataset.sidebar=compact?'compact':'expanded';
      sidebar.classList.toggle('is-open',!compact);
      document.body.classList.toggle('menu-open',!compact&&narrow.matches);
      if(backdrop)backdrop.hidden=compact||!narrow.matches;
      toggle.setAttribute('aria-controls',sidebar.id);
      toggle.setAttribute('aria-expanded',String(!compact));
      toggle.setAttribute('aria-label',compact?'Expand sidebar':'Show sidebar icons only');
      toggle.title=compact?'Expand sidebar':'Show icons only';
    }
    function set(value){compact=value;preference=value;try{localStorage.setItem(key,value?'1':'0');}catch(_){}apply();}
    // Capture the toggle before legacy page handlers that only open mobile menus.
    window.addEventListener('click',event=>{
      const target=event.target instanceof Element?event.target:null;
      if(target?.closest('#open-menu')){event.preventDefault();event.stopImmediatePropagation();set(!compact);}
      else if(target===backdrop){event.preventDefault();event.stopImmediatePropagation();set(true);toggle.focus();}
    },true);
    window.addEventListener('keydown',event=>{
      if(event.key==='Escape'&&!compact&&!document.querySelector('dialog[open], [aria-modal="true"]')){
        event.preventDefault();event.stopImmediatePropagation();set(true);toggle.focus();
      }
    },true);
    const colors=['blue','green','purple','red','amber','teal'];
    function labelItems(){
      if(!nav)return;
      nav.querySelectorAll('.nav-item').forEach(item=>{
        const icon=item.querySelector('.nav-icon');if(!icon)return;
        const copy=item.cloneNode(true);copy.querySelectorAll('.nav-icon,.nav-count').forEach(n=>n.remove());
        const name=copy.textContent.trim().replace(/\s+/g,' ');
        if(name){item.setAttribute('aria-label',name);item.title=name;}
        const route=item.getAttribute('href')||name;
        let hash=0;for(let i=0;i<route.length;i++)hash=(hash+route.charCodeAt(i))%colors.length;
        item.dataset.iconColor=colors[hash];
      });
    }
    labelItems();if(nav)new MutationObserver(labelItems).observe(nav,{childList:true,subtree:true,characterData:true});
    // Crossing into a phone-sized viewport closes the overlay, so resizing
    // never leaves a backdrop covering the page. Desktop choice is preserved.
    const changed=()=>{compact=narrow.matches?true:(preference??false);apply();};
    if(narrow.addEventListener)narrow.addEventListener('change',changed);else narrow.addListener(changed);
    apply();
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
