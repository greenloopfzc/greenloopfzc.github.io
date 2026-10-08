/* Explicit 12-hour input; the underlying wall-time value stays ISO for existing APIs. */
(function () {
  'use strict';
  const two = n => String(n).padStart(2, '0');
  function mount(source) {
    if (source._ampm) return source._ampm;
    const required = source.required;
    const container = document.createElement('div');
    container.className = 'gl-ampm-input';
    container.setAttribute('role', 'group');
    const controls = {};
    function field(key, title, type, values) {
      const label = document.createElement('label');
      label.className = 'gl-ampm-' + key;
      const caption = document.createElement('span');caption.textContent = title;
      const input = document.createElement(values ? 'select' : 'input');
      input.id = source.id + '-' + key;
      if (values) {
        for (const value of ['', ...values]) {
          const option = document.createElement('option');option.value = value;option.textContent = value || '—';input.appendChild(option);
        }
      } else input.type = type;
      input.required = required;
      input.disabled = source.disabled;
      if (source.getAttribute('aria-describedby')) input.setAttribute('aria-describedby',source.getAttribute('aria-describedby'));
      label.append(caption, input);container.appendChild(label);controls[key] = input;
      return input;
    }
    field('date','Date','date');
    field('hour','Hour',null,Array.from({length:12},(_,i)=>two(i+1)));
    field('minute','Minute',null,Array.from({length:60},(_,i)=>two(i)));
    field('period','AM / PM',null,['AM','PM']);
    const outerLabel = document.querySelector('label[for="'+source.id+'"]');
    if (outerLabel) { outerLabel.htmlFor = controls.date.id;outerLabel.id ||= source.id+'-label';container.setAttribute('aria-labelledby',outerLabel.id); }
    const initial=source.value;
    source.type='hidden';source.required=false;source.value=initial;
    source.after(container);
    function sync() {
      const match=/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/.exec(source.value);
      controls.date.value=match?match[1]:'';
      const hour=match?Number(match[2]):0;
      controls.hour.value=match?two(hour%12||12):'';
      controls.minute.value=match?match[3]:'';
      controls.period.value=match?(hour<12?'AM':'PM'):'';
      for (const control of Object.values(controls)) {control.setCustomValidity('');control.disabled=source.disabled;}
    }
    function update() {
      for (const control of Object.values(controls)) control.setCustomValidity('');
      const {date,hour,minute,period}=controls;
      source.value=date.value&&hour.value&&minute.value&&period.value ? date.value+'T'+two(Number(hour.value)%12+(period.value==='PM'?12:0))+':'+minute.value : '';
      source.dispatchEvent(new Event('input',{bubbles:true}));
      source.dispatchEvent(new Event('change',{bubbles:true}));
    }
    for (const control of Object.values(controls)) {control.addEventListener('input',update);control.addEventListener('change',update);}
    source._ampm={sync,controls};sync();
    return source._ampm;
  }
  window.GREENLOOP_AMPM_INPUT = {
    sync(source) {mount(source).sync();},
    mountAll(host) {host.querySelectorAll('input[type="datetime-local"]').forEach(mount);},
    validity(source,message) {const widget=mount(source);source.setCustomValidity(message);widget.controls.date.setCustomValidity(message);}
  };
})();
