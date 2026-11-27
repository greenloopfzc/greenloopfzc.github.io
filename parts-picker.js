/* Search the available options in each existing parts select. */
(() => {
  'use strict';

  const fields = {
    initial_qc: 'select[data-requirement="part"]',
    qc_issuance: 'select[data-work-choice="part"]',
    lab_glass: '[data-choice="part"] select'
  };
  let anchor, popup, search, list, empty, observer;
  let activeIndex = -1;
  let matches = [];

  function field(target) {
    const page = window.GREENLOOP_PAGE_ACCESS?.pageKey;
    return fields[page] && target.closest?.(fields[page]);
  }

  function usable(select) {
    const page = window.GREENLOOP_PAGE_ACCESS?.pageKey;
    return select?.isConnected && !select.matches(':disabled, [aria-disabled="true"]')
      && field(select) === select && window.GREENLOOP_CAN?.('entry',page) === true;
  }

  function close(restoreFocus = false) {
    if (!popup) return;
    const previous = anchor;
    observer.disconnect();
    popup.remove();
    popup = anchor = null;
    matches = [];
    if (restoreFocus && usable(previous)) previous.focus({preventScroll:true});
  }

  function position() {
    if (!popup) return;
    if (!usable(anchor) || !anchor.getClientRects().length) { close(); return; }
    const bounds = anchor.getBoundingClientRect();
    const viewport = window.visualViewport;
    const left = viewport?.offsetLeft ?? 0, top = viewport?.offsetTop ?? 0;
    const right = left + (viewport?.width ?? document.documentElement.clientWidth);
    const bottom = top + (viewport?.height ?? window.innerHeight);
    if (bounds.bottom <= top || bounds.top >= bottom || bounds.right <= left || bounds.left >= right) {
      close();
      return;
    }
    const gap = 6;
    const below = bottom - bounds.bottom - gap, above = bounds.top - top - gap;
    const opensAbove = below < 240 && above > below;
    const width = Math.min(Math.max(bounds.width,240),right-left-2*gap);
    popup.style.width = width + 'px';
    popup.style.left = Math.min(Math.max(bounds.left,left+gap),right-width-gap) + 'px';
    popup.style.maxHeight = Math.min(340,Math.max(0,(opensAbove?above:below)-gap)) + 'px';
    popup.style.top = (opensAbove ? bounds.top-gap-popup.offsetHeight : bounds.bottom+gap) + 'px';
  }

  function highlight(index, scroll = false) {
    list.children[activeIndex]?.classList.remove('is-highlighted');
    activeIndex = index;
    const option = list.children[index];
    if (!option) { search.removeAttribute('aria-activedescendant'); return; }
    option.classList.add('is-highlighted');
    search.setAttribute('aria-activedescendant',option.id);
    if (scroll) option.scrollIntoView({block:'nearest'});
  }

  function render() {
    if (!usable(anchor)) { close(); return; }
    const terms = search.value.toLowerCase().trim().split(/\s+/).filter(Boolean);
    matches = Array.from(anchor.options).filter(option => !option.disabled && !option.closest('optgroup')?.disabled
      && terms.every(term=>option.label.toLowerCase().includes(term))
      && (!terms.length || option.value));
    list.replaceChildren(...matches.map((option,index)=>{
      const item=document.createElement('li');
      item.id='parts-picker-option-'+index;
      item.dataset.index=index;
      item.setAttribute('role','option');
      item.setAttribute('aria-selected',String(option.selected));
      item.textContent=option.label;
      return item;
    }));
    empty.hidden=Boolean(matches.length);
    activeIndex=-1;
    highlight(terms.length ? (matches.length?0:-1) : matches.findIndex(option=>option.selected));
    position();
  }

  function choose(index) {
    const option = matches[index], select = anchor;
    if (!usable(select) || !option || !select.contains(option) || option.disabled || option.closest('optgroup')?.disabled) return;
    const previous = select.value;
    select.value = option.value;
    close(true);
    if (select.value!==previous) {
      select.dispatchEvent(new Event('input',{bubbles:true}));
      select.dispatchEvent(new Event('change',{bubbles:true}));
    }
  }

  function open(select, initialText = '') {
    close();
    if (!usable(select)) return;
    // Focus hydrates deferred options through the tray's existing handlers.
    select.focus({preventScroll:true});
    if (!usable(select)) return;
    anchor=select;
    popup=document.createElement('div');
    popup.className='parts-picker';
    popup.dataset.capability='entry';
    popup.dataset.capabilityPage=window.GREENLOOP_PAGE_ACCESS.pageKey;
    popup.innerHTML='<input type="search" role="combobox" aria-label="Search parts" placeholder="Search parts" autocomplete="off" aria-expanded="true" aria-autocomplete="list" aria-controls="parts-picker-options"><ul id="parts-picker-options" role="listbox" aria-label="Parts"></ul><p class="parts-picker-empty" role="status" hidden>No matching parts</p>';
    [search,list,empty]=popup.children;
    search.value=initialText;
    search.addEventListener('input',render);
    search.addEventListener('keydown',event=>{
      if (event.isComposing) return;
      if (event.key==='Tab') { close(true); return; }
      if (!['ArrowDown','ArrowUp','Escape','Enter'].includes(event.key)) return;
      event.preventDefault();
      if (event.key==='Escape') close(true);
      else if (event.key==='Enter') choose(activeIndex);
      else if (matches.length) {
        const next=event.key==='ArrowDown'?Math.min(activeIndex+1,matches.length-1):Math.max(activeIndex-1,0);
        highlight(next,true);
      }
    });
    list.addEventListener('pointerdown',event=>{if(event.pointerType==='mouse')event.preventDefault();});
    list.addEventListener('click',event=>{
      const option=event.target.closest('[role="option"]');
      if (option) choose(Number(option.dataset.index));
    });
    document.body.append(popup);
    observer=new MutationObserver(records=>{
      if (!usable(anchor)) close();
      else if (records.some(record=>anchor.contains(record.target))) render();
    });
    observer.observe(document.body,{childList:true,subtree:true});
    observer.observe(anchor,{attributes:true,subtree:true,attributeFilter:['disabled','aria-disabled','label','value','selected']});
    render();
    if (popup) search.focus({preventScroll:true});
  }

  document.addEventListener('pointerdown',event=>{
    if (event.button!==0 || popup?.contains(event.target)) return;
    const select=field(event.target);
    if (!usable(select)) { close(); return; }
    event.preventDefault();
    if (select===anchor) close(true);
    else open(select);
  });
  document.addEventListener('keydown',event=>{
    const select=field(event.target);
    if (event.defaultPrevented || event.isComposing || event.ctrlKey || event.metaKey || !usable(select)) return;
    const key=event.key;
    if (!['Enter','ArrowDown','ArrowUp'].includes(key) && key.length!==1) return;
    event.preventDefault();
    open(select,key.length===1 && key!==' ' ? key : '');
  });
  document.addEventListener('focusin',event=>{
    if (popup && event.target!==anchor && !popup.contains(event.target)) close();
  });
  window.addEventListener('scroll',event=>{if(popup && !(event.target instanceof Node && popup.contains(event.target)))position();},true);
  window.addEventListener('resize',position);
  window.visualViewport?.addEventListener('resize',position);
  window.visualViewport?.addEventListener('scroll',position);
  for (const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed','pagehide']) {
    window.addEventListener(event,()=>close());
  }
  window.GREENLOOP_PARTS_PICKER={activeWithin:container=>Boolean(anchor && container.contains(anchor))};
})();
