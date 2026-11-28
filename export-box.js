(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#export-box-app");
  const permissionMessage = document.querySelector("#permission-message");
  const imeiInput = document.querySelector("#export-imei");
  const message = document.querySelector("#export-message");
  const boxNumber = document.querySelector("#export-box-number");
  const boxStatus = document.querySelector("#export-box-status");
  const boxCount = document.querySelector("#export-box-count");
  const boxRemaining = document.querySelector("#export-box-remaining");
  const boxTabs = document.querySelector("#export-box-tabs");
  const newBoxButton = document.querySelector("#export-new-box");
  const progressBar = document.querySelector("#export-progress-bar");
  const startNextButton = document.querySelector("#start-next-box");
  const printButton = document.querySelector("#print-box-sheet");
  const tableBody = document.querySelector("#export-box-lines");
  const sortButtons = app.querySelectorAll("[data-box-sort]");
  const collator = new Intl.Collator("en", { numeric: true, sensitivity: "base" });
  const sheetTitle = document.querySelector("#export-sheet-title");
  const sheetTotal = document.querySelector("#export-sheet-total");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  const toast = document.querySelector("#toast");

  const confirmPrintButton=document.querySelector("#confirm-box-print");
  let printedSnapshot=null;
  let workflow=null;
  let client;
  let currentBox;
  let openDrafts = [];
  let createRequestId;
  let renderedTabs = "";
  let lines = [];
  let sortField = "", descending = false;
  let issueBoxId=null;
  let scanTimer;
  let toastTimer;
  let scanning = false;
  let boxBusy = false;
  let scannerLocked=false,scanFocusFrame=0,scanErrorDialog,lastScanFinishedAt=0;
  const can = capability => window.GREENLOOP_CAN?.(capability,"export_boxes") === true;

  // Disabled identifier mirrors settle on the next animation frame. Restore
  // scanner focus after that display update, without stealing it from a dialog.
  function focusScanner() {
    cancelAnimationFrame(scanFocusFrame);
    const focus=()=>{
      if(scannerLocked || document.hidden || !can("scan") || imeiInput.disabled || scanning || boxBusy ||
        !currentBox || currentBox.box_status!=="open" || !imeiInput.getClientRects().length ||
        document.querySelector('dialog[open],.office-access-lock'))return;
      const active=document.activeElement;
      if(active!==imeiInput && active?.matches('input,textarea,select,[contenteditable="true"]'))return;
      imeiInput.focus({preventScroll:true});
    };
    focus();
    scanFocusFrame=requestAnimationFrame(()=>{focus();scanFocusFrame=requestAnimationFrame(()=>{scanFocusFrame=0;focus();});});
  }

  function getClient() {
    if (!client) client = window.GREENLOOP_GET_CLIENT();
    return client;
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[character]);
  }

  function setMenu(isOpen) {
    sidebar.classList.toggle("is-open", isOpen);
    backdrop.hidden = !isOpen;
    document.body.classList.toggle("menu-open", isOpen);
  }

  function setMessage(text = "", type = "error") {
    message.textContent = text;
    message.classList.toggle("is-visible", Boolean(text));
    message.classList.toggle("is-success", type === "success");
  }

  function showToast(text) {
    clearTimeout(toastTimer);
    toast.textContent = text;
    toast.hidden = false;
    toast.classList.add("is-visible");
    toastTimer = setTimeout(() => {
      toast.hidden = true;
      toast.classList.remove("is-visible");
    }, 3400);
  }

  function phoneType(line) {
    const labels=[];
    if(line.esim_only===true)labels.push("e-Sim");
    if(line.is_rma===true)labels.push("RMA");
    return labels.join("/") || "-";
  }
  function invalidatePrint() { printedSnapshot=null;confirmPrintButton.hidden=true; }
  function setIssueBox(id) {
    if (issueBoxId !== id) {
      issueBoxId = id;
      sortField = "";
      descending = false;
      invalidatePrint();
    }
  }
  function showScanIssues(issues) {
    if(!issues.length || scannerLocked)return;
    if(!scanErrorDialog){
      scanErrorDialog=document.createElement("dialog");scanErrorDialog.id="box-scan-error-dialog";
      scanErrorDialog.className="gl-imei-stage-dialog imei-duplicate-dialog";
      scanErrorDialog.setAttribute("aria-labelledby","box-scan-error-title");
      scanErrorDialog.innerHTML='<div class="duplicate-imei-dialog-heading"><span aria-hidden="true">!</span><h2 id="box-scan-error-title">IMEI could not be added</h2></div><p>These phones were not added to this box. Check the reason below.</p><div data-box-scan-reasons></div><div class="duplicate-imei-actions"><button type="button" class="primary-button" data-box-scan-close data-capability="view" data-capability-page="export_boxes">OK</button></div>';
      document.body.append(scanErrorDialog);
      scanErrorDialog.querySelector('[data-box-scan-close]').onclick=()=>scanErrorDialog.close();
      scanErrorDialog.addEventListener('close',()=>{render();focusScanner();});
    }
    const list=scanErrorDialog.querySelector('[data-box-scan-reasons]');list.replaceChildren();
    list.style.cssText='max-height:45vh;overflow:auto;padding:0 24px 8px';
    for(const issue of issues){const row=document.createElement('p'),id=document.createElement('strong'),reason=document.createElement('span');
      id.textContent=String(issue.imei||'Scanned entry');reason.textContent=String(issue.reason||'This IMEI could not be added to the box.');
      id.style.display=reason.style.display='block';row.append(id,reason);list.append(row);
    }
    if(!scanErrorDialog.open)scanErrorDialog.showModal();
    render(false);
  }
  function removableDraft() {
    return can("scan") && currentBox?.box_status === "open" && workflow?.state === "draft" && !workflow?.saved_at;
  }
  function sortedLines() {
    if (!sortField || !can("sort")) return lines;
    return [...lines].sort((a, b) => {
      const first = String(a[sortField] ?? "").trim();
      const second = String(b[sortField] ?? "").trim();
      const firstMissing = !first || first === "-";
      const secondMissing = !second || second === "-";
      if (firstMissing || secondMissing) return Number(firstMissing) - Number(secondMissing);
      const comparison = sortField === "storage_gb" ? Number(first) - Number(second) : collator.compare(first, second);
      return descending ? -comparison : comparison;
    });
  }
  function updateSortHeadings() {
    const canSort = can("sort");
    for (const button of sortButtons) {
      const active = canSort && button.dataset.boxSort === sortField;
      button.closest("th").setAttribute("aria-sort", active ? (descending ? "descending" : "ascending") : "none");
      button.querySelector("span").textContent = active ? (descending ? "↓" : "↑") : "↕";
      button.disabled = !canSort || scannerLocked || boxBusy || scanning;
    }
  }
  function renderTabs() {
    const disabled = boxBusy || scanning || scannerLocked || Boolean(scanErrorDialog?.open);
    newBoxButton.hidden = !can("scan") || scannerLocked;
    newBoxButton.disabled = disabled || !can("scan");
    const active = currentBox?.box_id;
    const markup = openDrafts.map(box => `<button type="button" class="secondary-button" data-box-tab="${escapeHtml(box.box_id)}" aria-pressed="${active === box.box_id}" data-capability="view" data-capability-page="export_boxes" data-search-read-only><strong>${escapeHtml(box.box_number)}</strong><span class="export-box-tab-count">${box.item_count} pcs</span></button>`).join("");
    if (renderedTabs !== markup) {
      boxTabs.innerHTML = markup;
      renderedTabs = markup;
      const selected = boxTabs.querySelector('[aria-pressed="true"]');
      if (selected) {
        const tab = selected.getBoundingClientRect(), strip = boxTabs.getBoundingClientRect();
        if (tab.right > strip.right) boxTabs.scrollLeft += tab.right - strip.right + 4;
        if (tab.left < strip.left) boxTabs.scrollLeft -= strip.left - tab.left + 4;
      }
    }
    for (const button of boxTabs.children) button.disabled = disabled || !can("view");
  }

  function render(drawRows=true) {
    renderTabs();
    updateSortHeadings();
    const removable=removableDraft();
    document.querySelector('#export-delete-heading').hidden=!removable;
    if (!currentBox) {
      boxNumber.textContent = "No open export box";
      boxStatus.textContent = can("scan") ? "Use + New Box to begin" : "View only";
      boxCount.textContent = sheetTotal.textContent = "0 phones";
      boxRemaining.textContent = "No open box to display";
      progressBar.style.width = "0";
      sheetTitle.textContent = "Export Box";
      startNextButton.disabled = imeiInput.disabled = printButton.disabled = true;
      tableBody.innerHTML = '<tr><td class="export-sheet-empty" colspan="8">No open export box is available.</td></tr>';
      return;
    }
    const count = lines.length,mayRemove=removable;
    const isDraft = workflow?.state === "draft" && !workflow.saved_at;
    const hasCapacity = currentBox.box_status === "open";

    boxNumber.textContent = currentBox.box_number || "Export Box";
    boxStatus.textContent = !workflow ? "Select this box again to refresh" :
      !isDraft ? "Saved to Accounts" : hasCapacity ? "Open for scanning" : "Ready to print and save";
    boxCount.textContent = `${count} phone${count === 1 ? "" : "s"}`;
    boxRemaining.textContent = isDraft && hasCapacity ? "Ready to scan" : "";
    progressBar.style.width = count ? "100%" : "0";
    startNextButton.disabled = scannerLocked || !can("save") || !isDraft || boxBusy || scanning || count === 0 ||
      workflow.printed_revision !== workflow.revision || !workflow.printed_at;
    printButton.disabled = scannerLocked || !can("print") || !isDraft || count === 0 || scanning || boxBusy;
    confirmPrintButton.disabled = scannerLocked || !can("print") || scanning || boxBusy;
    imeiInput.disabled = scannerLocked || !can("scan") || boxBusy || !isDraft || !hasCapacity || scanning || Boolean(scanErrorDialog?.open);
    sheetTitle.textContent = `${currentBox.box_number || "Export Box"} - Export packing list`;
    sheetTotal.textContent = `${count} valid phone${count === 1 ? "" : "s"}`;
    if(!drawRows){tableBody.querySelectorAll('[data-draft-remove]').forEach(b=>b.disabled=boxBusy||scanning);return;}

    const validRows=sortedLines().map(line=>`<tr><td>${escapeHtml(line.serial_no)}</td><td>${escapeHtml(line.imei)}</td><td>${escapeHtml(line.model||"-")}</td><td>${escapeHtml(line.storage_gb?`${line.storage_gb} GB`:"-")}</td><td>${escapeHtml(line.final_grade||"-")}</td><td>${escapeHtml(line.color||"-")}</td><td class="export-esim">${phoneType(line)}</td><td>${escapeHtml(line.box_number||currentBox.box_number)}</td>${mayRemove?`<td class="export-line-action">${removable?`<button type="button" class="secondary-button" data-draft-remove="${escapeHtml(line.id)}" data-capability="scan" data-capability-page="export_boxes" ${boxBusy||scanning?'disabled':''} aria-label="Delete ${escapeHtml(line.imei)} from this box">Delete</button>`:''}</td>`:''}</tr>`).join('');
    tableBody.innerHTML=validRows||`<tr><td class="export-sheet-empty" colspan="${8+(mayRemove?1:0)}">Scan the first Ready Stock IMEI to add it to this box.</td></tr>`;

  }

  async function removeDraftLine(itemId) {
    if (scannerLocked || !removableDraft() || boxBusy || scanning) return;
    boxBusy=true;clearTimeout(scanTimer);render();setMessage();
    try {
      const {error}=await getClient().rpc('remove_draft_box_imei_v1',{p_box_id:currentBox.box_id,p_revision:workflow.revision,p_item_id:itemId});
      if(error)throw error;
      await loadWorkflow();
      setMessage('Phone removed from this draft box and returned to Ready Stock. Print the updated sheet before saving.','success');
    } catch(error) {
      setMessage(error.message||'The phone could not be removed.');
      try { await loadWorkflow(); } catch (_) {}
    } finally { boxBusy=false;render();focusScanner(); }
  }
  function assertBoxAccess() {
    if (scannerLocked || !can("view")) throw Error("Box Entry access changed. Reload the page to continue.");
  }

  async function readDrafts() {
    const { data, error } = await getClient().rpc("list_open_export_box_drafts_v1");
    if (error) throw error;
    assertBoxAccess();
    if (!Array.isArray(data) || new Set(data.map(box => box?.box_id)).size !== data.length ||
      data.some(box => !box?.box_id || !box.box_number || !Number.isSafeInteger(box.item_count) || box.item_count < 0)) {
      throw Error("The open box list could not be verified. Refresh Box Entry.");
    }
    return data;
  }

  async function createDraft(forceNew) {
    const requestId = forceNew ? (createRequestId ||= crypto.randomUUID()) : crypto.randomUUID();
    const { data, error } = await getClient().rpc("create_open_export_box_draft_v1", {
      p_request_id: requestId, p_force_new: forceNew
    });
    if (error) throw error;
    assertBoxAccess();
    if (typeof data !== "string" || !data) throw Error("The new box could not be verified. Try opening it again.");
    return data;
  }

  async function readBox(boxId) {
    const { data, error } = await getClient().rpc("get_box_workflow_v1", { p_box_id: boxId });
    if (error) throw error;
    assertBoxAccess();
    if (data?.box?.box_id !== boxId || !Number.isSafeInteger(data.box.revision) || !Array.isArray(data.lines)) {
      throw Error("The selected box could not be verified. Refresh Box Entry.");
    }
    return data;
  }

  function applyBox(data) {
    setIssueBox(data?.box.box_id);
    currentBox = workflow = data?.box ?? null;
    lines = data?.lines ?? [];
    const draft = openDrafts.find(box => box.box_id === currentBox?.box_id);
    if (draft) draft.item_count = lines.length;
    invalidatePrint();
  }

  async function loadCurrentBox(preferredId, createIfEmpty = false) {
    let drafts = await readDrafts();
    if (!drafts.length && createIfEmpty && can("scan")) {
      preferredId = await createDraft(false);
      drafts = await readDrafts();
    }
    const next = preferredId ? drafts.find(box => box.box_id === preferredId) : drafts[0];
    if (preferredId && !next) {
      openDrafts = drafts;
      if (!drafts.some(box => box.box_id === currentBox?.box_id)) applyBox(null);
      throw Error("That box is no longer open. Select an open box.");
    }
    const data = next ? await readBox(next.box_id) : null;
    if (data && (data.box.state !== "draft" || data.box.saved_at)) {
      throw Error("This box was already saved. Refresh Box Entry.");
    }
    openDrafts = drafts;
    applyBox(data);
    imeiInput.value = "";
  }

  async function loadWorkflow() {
    if (!currentBox?.box_id) return;
    invalidatePrint();
    workflow = null;
    const data = await readBox(currentBox.box_id);
    applyBox(data);
  }

  async function chooseDraft(id, forceNew = false) {
    if (scannerLocked || !can("view") || boxBusy || scanning || scanErrorDialog?.open ||
      (forceNew && !can("scan"))) return;
    boxBusy = true;
    clearTimeout(scanTimer);
    setMessage();
    render(false);
    try {
      if (forceNew) id = await createDraft(true);
      await loadCurrentBox(id);
      if (forceNew) createRequestId = undefined;
    } catch (error) {
      setMessage(error.message || "The selected box could not be opened.");
    } finally {
      boxBusy = false;
      render();
      if (can("scan")) focusScanner();
      else boxTabs.querySelector('[aria-pressed="true"]')?.focus({preventScroll:true});
    }
  }

  async function downloadCurrentBox(kind){
    if(scannerLocked||!can('view')||!can('print')||boxBusy||scanning||!lines.length)return;
    const id=currentBox.box_id;boxBusy=true;render();
    const allowed=()=>can('view')&&can('print')&&currentBox?.box_id===id&&!scannerLocked;
    try{const data=await readBox(id);await window.GREENLOOP_REPORT_DOWNLOADS.output(kind,window.GREENLOOP_REPORT_DOWNLOADS.boxReport(data),allowed,'export_boxes','print');}catch(e){setMessage(e.message);}finally{boxBusy=false;render();}
  }
  const downloadActions=document.createElement('span');downloadActions.className='box-actions';printButton.before(downloadActions);
  Promise.resolve(window.GREENLOOP_ACCESS_READY).then(()=>{downloadActions.innerHTML=window.GREENLOOP_REPORT_DOWNLOADS.buttons('data-export-current','export_boxes','print');});
  downloadActions.addEventListener('click',e=>{const b=e.target.closest('[data-export-current]');if(b)downloadCurrentBox(b.dataset.exportCurrent);});
  async function printBox() {
    if(scannerLocked || !can("print") || boxBusy || scanning || !lines.length || workflow?.state !== "draft")return;
    boxBusy=true;render();setMessage();
    try {
      await loadWorkflow();
      if (workflow.state !== "draft" || !lines.length) throw Error("This box is empty or already saved.");
      const snapshot={boxId:currentBox.box_id,revision:workflow.revision};
      await window.GREENLOOP_BOX_PRINT.open({box:{...workflow},lines:[...lines]},{allowed:()=>!scannerLocked && can("print") && currentBox?.box_id === snapshot.boxId});
      assertBoxAccess();
      printedSnapshot=snapshot;
      confirmPrintButton.hidden=!can("print");
      setMessage("Print from the preview. After printing succeeds, close the preview and choose Printing completed.","success");
    } catch(error){setMessage(error.message || "Printing could not start.");}
    finally{boxBusy=false;render();}
  }
  async function confirmPrint() {
    if(scannerLocked || !can("print") || boxBusy || scanning || !printedSnapshot || printedSnapshot.boxId !== currentBox?.box_id)return;
    boxBusy=true;render();
    try {
      const {error}=await getClient().rpc("mark_box_printed_v1",{p_box_id:printedSnapshot.boxId,p_revision:printedSnapshot.revision});if(error)throw error;
      await loadWorkflow();setMessage("Printing confirmed. Save Box to send it to Accounts.","success");
    }catch(error){printedSnapshot=null;confirmPrintButton.hidden=true;setMessage(error.message);}
    finally{boxBusy=false;render();}
  }
  function applyScanSnapshot(data,imeis) {
    if(!data?.box || data.box.box_id!==currentBox.box_id || !Number.isSafeInteger(data.box.revision) ||
      !Array.isArray(data.lines) || !Array.isArray(data.results) || data.results.length!==imeis.length ||
      data.results.some((r,i)=>r.imei!==imeis[i] || typeof r.ok!=="boolean") ||
      data.loaded!==data.results.filter(r=>r.ok).length ||
      data.results.some(r=>r.ok&&!data.lines.some(line=>line.imei===r.imei)))throw Error("The scan response could not be verified. Check the box before retrying.");
    applyBox(data);
  }
  async function scanImei() {
    clearTimeout(scanTimer);
    if(scannerLocked || !can("scan") || boxBusy || scanning || scanErrorDialog?.open || workflow?.state!=="draft" || currentBox?.box_status!=="open")return;
    const imei=imeiInput.value.replace(/\D/g,"").slice(0,15);imeiInput.value=imei;
    if(imei.length!==15){if(imei){imeiInput.value="";showScanIssues([{imei,reason:"Use a valid 15-digit IMEI."}]);}return;}
    return pasteImeis([imei],{isCurrent:()=>!scannerLocked});
  }
  async function pasteImeis(imeis,options) {
    clearTimeout(scanTimer);
    if(scannerLocked || !can("scan") || boxBusy || scanning || scanErrorDialog?.open || workflow?.state!=="draft" || currentBox?.box_status!=="open")throw Error("This box is not available for scanning.");
    if(!options.isCurrent())return {loaded:0,issues:[]};
    const issues=(options.rejected||[]).map(r=>({imei:r.imei,reason:r.message}));
    if(!imeis.length){imeiInput.value="";showScanIssues(issues);return {loaded:0,issues:[]};}
    scanning=true;setMessage();render(false);
    try{
      if(!workflow)throw Error("The current box could not be verified. Reload Box Entry before retrying.");
      // One request validates, saves and returns the canonical box/lines snapshot.
      const {data,error}=await getClient().rpc("scan_imeis_to_selected_export_box_v1",{p_box_id:currentBox.box_id,p_revision:workflow.revision,p_imeis:imeis});
      if(error)throw error;
      if(options.isCurrent() && !scannerLocked && can("view")){
        applyScanSnapshot(data,imeis);imeiInput.value="";
        issues.push(...data.results.filter(r=>!r.ok).map(r=>({imei:r.imei,reason:r.message})));
        if(issues.length)showScanIssues(issues);
        setMessage(data.loaded?`${data.loaded} phone${data.loaded===1?"":"s"} added to ${data.box.box_number}. Ready to scan.`:"","success");
      }
      return {loaded:data.loaded,issues:[]};
    }catch(error){
      // The response may be lost after commit. Read once; never repeat the write.
      let verified=false;
      try{if(options.isCurrent() && !scannerLocked){await loadWorkflow();verified=true;}}catch(_){}
      if(options.isCurrent() && !scannerLocked && can("view")){
        const unresolved=verified?imeis.filter(v=>!lines.some(r=>r.imei===v)):imeis;
        for(const imei of unresolved)issues.push({imei,reason:(error.message||"The scan result could not be verified.")+(verified?"":" Reload Box Entry before retrying; the saved result is unknown.")});
        imeiInput.value="";setMessage();showScanIssues(issues);
        if(verified&&!unresolved.length)setMessage("The saved phones were confirmed in the box. Ready to scan.","success");
      }
      return {loaded:verified?imeis.filter(v=>lines.some(r=>r.imei===v)).length:0,issues:[]};
    }finally{scanning=false;lastScanFinishedAt=performance.now();render();focusScanner();}
  }

  async function finishAndStartNext() {
    if (scannerLocked || !currentBox || workflow?.state !== "draft" || !can("save") || scanning || boxBusy || !lines.length) return;
    if (workflow.printed_revision !== workflow.revision || !workflow.printed_at) {
      setMessage("Print and confirm printing before saving this box.");
      return;
    }
    boxBusy = true;
    clearTimeout(scanTimer);
    render();
    try {
      const { box_id: savedId, box_number: savedNumber } = currentBox;
      const { error } = await getClient().rpc("close_export_box", { p_box_id: savedId });
      if (error) throw error;
      assertBoxAccess();
      openDrafts = openDrafts.filter(box => box.box_id !== savedId);
      applyBox(null);
      try {
        await loadCurrentBox(undefined, true);
        setMessage(savedNumber + " saved to Accounts." + (currentBox ? " " + currentBox.box_number + " selected." : ""), "success");
      } catch (error) {
        setMessage(savedNumber + " saved to Accounts. " + (error.message || "Refresh Box Entry to load the open boxes."));
      }
    } finally { boxBusy = false; render(); focusScanner(); }
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      permissionMessage.textContent = "Supabase authentication is not configured.";
      permissionMessage.hidden = false;
      return;
    }
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: canUse, error } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner", "manager", "production", "shipping"]
    });
    if (error) throw error;
    if (!canUse) {
      permissionMessage.textContent = "Your account does not have Export Box permission.";
      permissionMessage.hidden = false;
      return;
    }
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "export_boxes") return;
    app.hidden = false;
    boxBusy = true;
    render();
    try { await loadCurrentBox(undefined, true); }
    finally { boxBusy = false; render(); focusScanner(); }
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  window.GREENLOOP_BULK_IMEI?.register({selector:'#export-imei',capability:'scan',cancellable:false,inlineIssues:true,load:pasteImeis});
  imeiInput.addEventListener("input", () => {
    imeiInput.value = imeiInput.value.replace(/\D/g, "").slice(0, 15);
    clearTimeout(scanTimer);
    if (imeiInput.value.length === 15) void scanImei();
  });
  imeiInput.addEventListener("keydown", (event) => {
    // Very fast replies may clear the field before the scanner's Tab arrives.
    if(event.key==="Tab" && !imeiInput.value && lastScanFinishedAt>0 && performance.now()-lastScanFinishedAt<250){event.preventDefault();return;}
    if (event.key === "Enter" || event.key === "Tab" && /^\d{15}$/.test(imeiInput.value)) { event.preventDefault(); scanImei(); }
  });
  startNextButton.addEventListener("click", () => finishAndStartNext().catch((error) => setMessage(error.message || "The next export box could not be opened.")));
  printButton.addEventListener("click", printBox);
  confirmPrintButton.addEventListener("click", confirmPrint);
  newBoxButton.addEventListener("click", () => chooseDraft(null, true));
  boxTabs.addEventListener("click", event => {
    const tab = event.target.closest("[data-box-tab]");
    if (tab) void chooseDraft(tab.dataset.boxTab);
  });
  for (const button of sortButtons) {
    button.addEventListener("click", event => {
      if (button.disabled || !can("sort")) return;
      const field = button.dataset.boxSort;
      descending = sortField === field && !descending;
      sortField = field;
      render();
      if (event.detail > 0) focusScanner();
    });
  }
  tableBody.addEventListener('click',event=>{const button=event.target.closest('[data-draft-remove]');if(button)removeDraftLine(button.dataset.draftRemove);});
  for(const event of ['greenloop:office-locked','greenloop:signed-out','greenloop:permissions-changed'])window.addEventListener(event,()=>{scannerLocked=true;clearTimeout(scanTimer);cancelAnimationFrame(scanFocusFrame);scanErrorDialog?.close();openDrafts=[];applyBox(null);imeiInput.value="";setMessage();render();});
  window.addEventListener("pagehide",()=>{clearTimeout(scanTimer);cancelAnimationFrame(scanFocusFrame);});
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Export Boxes could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
