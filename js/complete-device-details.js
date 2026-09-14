(() => {
  'use strict';
  const endpoint = 'http://127.0.0.1:51892';
  const unknown = 'Not available from this phone/reader. This is not a pass or a clean result.';
  const partsNote = 'Not read over this USB interface. Check Settings > General > About > Parts and Service History on the phone.';
  const groups = [
    ['01', 'Phone identity', [
      ['phoneName', 'Phone Name'], ['model', 'Model'], ['storageGb', 'Storage / GB'], ['color', 'Colour'],
      ['serialNumber', 'Serial Number'], ['region', 'Region'], ['imei1', 'IMEI 1'], ['imei2', 'IMEI 2']
    ]],
    ['02', 'Battery & power', [
      ['batteryHealth', 'Battery Health'], ['batteryCycleCount', 'Battery Cycle Count'],
      ['chargingStatus', 'Charging Status'], ['rawCapacity', 'Raw Capacity', 'AppleRawMaxCapacity, when provided, in mAh. Not the current charge percentage.'],
      ['designCapacity', 'Design Capacity']
    ]],
    ['03', 'Software & connection', [
      ['iosVersion', 'iOS Version'], ['bootFirmware', 'Boot Firmware'], ['baseband', 'Baseband'],
      ['appVersion', 'App Version', 'Greenloop PC reader extension version. No diagnostic iPhone app is installed.'],
      ['usbConnectionStatus', 'USB Connection Status']
    ]],
    ['04', 'SIM & carrier checks', [
      ['simLock', 'SIM Lock', 'Not verified. SIM presence or activation state does not prove SIM lock status.'],
      ['carrierLock', 'Carrier Lock', 'Not verified automatically. Inspect Carrier Lock in iPhone Settings > General > About.'],
      ['esimState', 'eSIM State', 'An IMEI 2 or EID does not prove an active eSIM plan.'],
      ['esimHardware', 'eSIM Hardware', 'An EID can confirm hardware. Missing data does not mean unsupported.'],
      ['blacklist', 'ESN / Blacklist', 'No verified blacklist service is connected. USB data cannot confirm a clean blacklist result.'],
      ['tmo', 'TMO', 'T-Mobile (US). No verified carrier-specific lookup is connected.'],
      ['att', 'ATT', 'AT&T (US). No verified carrier-specific lookup is connected.'],
      ['cce', 'CCE', 'Meaning is not verified in this project. No result is assumed.'],
      ['vrz', 'VRZ', 'Possibly Verizon; mapping is not confirmed in this project. No verified lookup is connected.'],
      ['carrierLockManual', 'Carrier Lock — Manual', 'Optional observation for this connection only. Not saved to the database.']
    ]],
    ['05', 'Security & management', [
      ['fmip', 'FMIP', 'Find My status is not verified by this reader. ActivationState is not a Find My check.'],
      ['icloudLock', 'iCloud Lock', 'Activation Lock is not verified by this read-only report. Activated does not mean lock-free.'],
      ['mdm', 'MDM', 'MDM enrolment is not verified. Not supervised does not prove no MDM.'],
      ['supervised', 'Supervised'], ['profiles', 'Profiles', 'Configuration profiles have not been queried. Missing data does not mean no profiles.']
    ]],
    ['06', 'Panics & parts history', [
      ['panics', 'Panics', 'Panic logs have not been collected. This is not a zero-panic result.'],
      ['parts', 'Parts', partsNote], ['batteryPartsMessage', 'Battery Parts Message', partsNote],
      ['displayPartsMessage', 'Display Parts Message', partsNote], ['cameraPartsMessage', 'Camera Parts Message', partsNote],
      ['frontCameraPartsMessage', 'Front Camera / Face ID Message', partsNote], ['logicBoardPartsMessage', 'Logic Board Parts Message', partsNote]
    ]]
  ];
  const definitions = groups.flatMap(group => group[2]);
  const manualOptions = ['Not checked', 'No SIM restrictions', 'SIM locked', 'Unable to verify'];
  const verificationKeys = new Set(['simLock', 'carrierLock', 'blacklist', 'tmo', 'att', 'cce', 'vrz', 'fmip', 'icloudLock', 'mdm', 'profiles', 'panics', 'parts', 'batteryPartsMessage', 'displayPartsMessage', 'cameraPartsMessage', 'frontCameraPartsMessage', 'logicBoardPartsMessage', 'esimState']);
  let host = null;
  let timer = 0;
  let controller = null;
  let generation = 0;
  let fields = {};
  let deviceKey = '';
  let lastRead = 0;
  let legacy = false;
  let manualValue = 'Not checked';
  let readOnly = true;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function regionName(value) {
    const names = { 'VC/A': 'Canada', 'LL/A': 'United States', 'CH/A': 'Mainland China', 'J/A': 'Japan', 'AB/A': 'United Arab Emirates', 'B/A': 'United Kingdom / Ireland' };
    const code = String(value).trim().toUpperCase();
    return names[code] ? `${code} - ${names[code]}` : String(value);
  }
  function connection(state, text) {
    if (!host) return;
    host.dataset.connection = state;
    host.querySelector('.cdd-state').textContent = text;
  }
  function paint(connected = Boolean(deviceKey)) {
    if (!host) return;
    let readCount = 0;
    for (const [key, , note] of definitions) {
      const row = host.querySelector(`[data-detail="${key}"]`);
      if (key === 'carrierLockManual') {
        const select = row.querySelector('select');
        select.disabled = readOnly || !connected;
        select.value = manualValue;
        row.querySelector('.cdd-source').textContent = readOnly ? 'View-only access. Manual entry is disabled.' : note;
        continue;
      }
      const field = fields[key];
      const available = field && ['read', 'calculated'].includes(field.status) && ['string', 'number', 'boolean'].includes(typeof field.value) && String(field.value).trim() !== '';
      row.dataset.available = available ? 'yes' : 'no';
      const label = row.querySelector('.cdd-badge');
      row.querySelector('.cdd-value').textContent = available
        ? (key === 'region' ? regionName(field.value) : String(field.value))
        : (!connected ? 'Waiting for phone' : verificationKeys.has(key) ? 'Not verified' : 'Not available');
      label.textContent = available ? field.status === 'calculated' ? 'Calculated' : 'Read' : '—';
      row.querySelector('.cdd-source').textContent = available ? String(field.source || 'Connected reader') : (note || unknown);
      if (available) readCount++;
    }
    host.querySelector('.cdd-count').textContent = `${readCount} / ${definitions.length - 1} automatic fields available`;
    host.querySelector('.cdd-time').textContent = lastRead ? `Last read ${new Date(lastRead).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true })}` : 'No phone data retained';
    const title = fields.model?.value || 'Connect one iPhone';
    host.querySelector('.cdd-device-title').textContent = String(title);
    host.querySelector('.cdd-device-subtitle').textContent = fields.imei1?.value ? `IMEI ${fields.imei1.value}` : 'Unlock the phone and accept Trust This Computer.';
  }
  function clear() { fields = {}; deviceKey = ''; lastRead = 0; manualValue = 'Not checked'; paint(false); }
  async function request(path, signal, timeout = 20000) {
    const response = await fetch(`${endpoint}${path}`, { cache: 'no-store', signal: AbortSignal.any([signal, AbortSignal.timeout(timeout)]) });
    if (response.status === 404) return { unsupported: true };
    const data = await response.json();
    if (!response.ok || data.ok !== true) throw new Error(data.message || 'The connected phone could not be read.');
    return data;
  }
  function legacyFields(payload) {
    const source = payload.device;
    if (!source || typeof source !== 'object') throw new Error('The reader returned an invalid device response.');
    const key = source.serialNumber || source.imei;
    if (!key) throw new Error('The reader did not return a phone identity.');
    const output = {};
    for (const [name, from] of Object.entries({ phoneName: 'phoneName', model: 'model', storageGb: 'storageGb', color: 'color', serialNumber: 'serialNumber', region: 'phoneRegion', imei1: 'imei', imei2: 'imei2', batteryHealth: 'batteryHealth' })) {
      const value = source[from];
      if (value === null || value === undefined || String(value).trim() === '') continue;
      if (['batteryHealth', 'storageGb'].includes(name) && (!Number.isFinite(Number(value)) || Number(value) <= 0)) continue;
      const estimated = name === 'batteryHealth' && source.batteryHealthSource === 'capacity-estimate';
      output[name] = { value: `${value}${name === 'storageGb' ? ' GB' : name === 'batteryHealth' ? '%' : ''}${estimated ? ' (estimated)' : ''}`, status: estimated ? 'calculated' : 'read', source: estimated ? 'Existing cable reader: capacity estimate, not an iOS Settings reading' : 'Existing cable reader (basic details only)' };
    }
    output.usbConnectionStatus = { value: 'Connected', status: 'read', source: 'Successful local cable reader response' };
    return { deviceKey: String(key), fields: output };
  }
  async function poll(force = false) {
    if (!host || document.hidden || controller) return;
    const current = generation;
    const abort = new AbortController();
    controller = abort;
    const button = host.querySelector('.cdd-retry');
    button.disabled = true;
    try {
      let result;
      if (!legacy) {
        const probe = await request('/v1/details/probe', abort.signal, 5000);
        if (current !== generation) return;
        legacy = probe.unsupported === true;
        if (!legacy) {
          if (typeof probe.connected !== 'boolean') throw new Error('Invalid reader connection response.');
          if (!probe.connected) { clear(); connection('waiting', 'Waiting for a connected iPhone'); return; }
          if (!probe.deviceKey) throw new Error('Reader connection identity is missing.');
          if (deviceKey !== probe.deviceKey) { clear(); connection('reading', 'Phone connected - reading details...'); }
          if (!force && deviceKey === probe.deviceKey && Date.now() - lastRead < 30000) return;
          result = await request('/v1/details', abort.signal);
          if (result.unsupported) { legacy = true; }
          else {
            if (result.connected === false) { clear(); connection('waiting', 'Phone disconnected'); return; }
            if (result.schemaVersion !== 1 || !result.fields || typeof result.fields !== 'object' || Array.isArray(result.fields) || result.deviceKey !== probe.deviceKey) {
              throw new Error('Phone changed during reading or reader response is invalid. Please retry.');
            }
          }
        }
      }
      if (legacy) result = legacyFields(await request('/v1/device', abort.signal, 22000));
      if (current !== generation || !host) return;
      if (deviceKey !== result.deviceKey) manualValue = 'Not checked';
      deviceKey = result.deviceKey;
      // Replace snapshots. Never carry missing data across phones or read failures.
      fields = result.fields;
      lastRead = Date.now();
      paint(true);
      connection('connected', legacy ? 'Connected - basic reader only; install the Details extension for more fields.' : 'Connected - automatic reading is on');
    } catch (error) {
      if (current !== generation || !host) return;
      clear();
      connection('error', error.name === 'TimeoutError' ? 'Reader timed out. Keep the phone unlocked; automatic retry is on.' : error.message === 'Failed to fetch' ? 'Start Greenloop Cable Reader and allow local-network access if your browser asks.' : error.message);
    } finally {
      if (controller === abort) controller = null;
      if (current === generation && host) {
        button.disabled = false;
        clearTimeout(timer);
        timer = window.setTimeout(poll, legacy ? 5000 : 2500);
      }
    }
  }
  function unmount() {
    generation++;
    clearTimeout(timer);
    controller?.abort(); controller = null;
    host = null; fields = {}; deviceKey = ''; lastRead = 0; manualValue = 'Not checked'; legacy = false;
  }
  function mount(container) {
    if (host?.isConnected && host.parentElement === container) return;
    unmount();
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== 'reports') return;
    readOnly = window.GREENLOOP_PAGE_ACCESS.canEdit !== true;
    host = element('div', 'complete-device-details');
    const toolbar = element('div', 'cdd-toolbar');
    const heading = element('div');
    heading.append(element('p', 'cdd-eyebrow', 'LIVE USB REPORT'), element('h3', 'cdd-device-title', 'Connect one iPhone'), element('p', 'cdd-device-subtitle', 'Unlock the phone and accept Trust This Computer.'));
    const retry = element('button', 'secondary-button cdd-retry', 'Read again');
    retry.type = 'button'; retry.addEventListener('click', () => { clearTimeout(timer); poll(true); });
    toolbar.append(heading, retry);
    const status = element('div', 'cdd-status');
    const state = element('strong', 'cdd-state', 'Waiting for a connected iPhone');
    state.setAttribute('role', 'status');
    status.append(state, element('span', 'cdd-count'), element('span', 'cdd-time'));
    host.append(toolbar, status, element('p', 'cdd-notice', 'Live connected-phone details, not historical database records. Unavailable is not Clean, Unlocked or Genuine. No phone settings or stock records are changed. Date filters do not apply to this tab.'));
    const grid = element('div', 'cdd-grid');
    for (const [number, title, rows] of groups) {
      const card = element('section', 'cdd-card');
      const cardHeading = element('h4');
      cardHeading.append(element('span', 'cdd-section-number', number), document.createTextNode(title));
      card.append(cardHeading);
      const list = element('dl', 'cdd-fields');
      for (const [key, label] of rows) {
        const row = element('div', 'cdd-row'); row.dataset.detail = key;
        const term = element('dt', '', label);
        const detail = element('dd');
        if (key === 'carrierLockManual') {
          const select = element('select'); select.id = 'cdd-carrier-manual'; select.setAttribute('aria-label', label);
          manualOptions.forEach(value => { const option = element('option', '', value); option.value = value; select.append(option); });
          select.addEventListener('change', () => { if (!readOnly && deviceKey && manualOptions.includes(select.value)) manualValue = select.value; });
          detail.append(select, element('span', 'cdd-badge', 'Manual'));
        } else { detail.append(element('strong', 'cdd-value', 'Waiting for phone'), element('span', 'cdd-badge', '—')); }
        detail.append(element('small', 'cdd-source'));
        row.append(term, detail); list.append(row);
      }
      card.append(list); grid.append(card);
    }
    host.append(grid);
    container.replaceChildren(host);
    paint(false);
    poll();
  }
  document.addEventListener('visibilitychange', () => {
    if (!host) return;
    if (document.hidden) {
      generation++; clearTimeout(timer); controller?.abort(); controller = null; clear();
      connection('waiting', 'Paused while this page is hidden');
    } else poll(true);
  });
  window.addEventListener('beforeunload', unmount);
  window.GREENLOOP_COMPLETE_DEVICE_DETAILS = { mount, unmount };
})();
