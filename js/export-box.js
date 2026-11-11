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
  const progressBar = document.querySelector("#export-progress-bar");
  const startNextButton = document.querySelector("#start-next-box");
  const printButton = document.querySelector("#print-box-sheet");
  const tableBody = document.querySelector("#export-box-lines");
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
  let lines = [];
  let issueBoxId=null;
  let scanTimer;
  let toastTimer;
  let scanning = false;
  let boxBusy = false;
  let scannerLocked=false,scanFocusFrame=0,scanErrorDialog;
  let canEdit = false;
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

  function asRow(data) { return Array.isArray(data) ? data[0] : data; }

  function formatDateTime(value) {
    return new Date(value || Date.now()).toLocaleString("en-GB", {
      timeZone: "Asia/Dubai", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: true
    });
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

  function invalidatePrint() { printedSnapshot=null;confirmPrintButton.hidden=true; }
  function setIssueBox(id) { if(issueBoxId!==id){issueBoxId=id;invalidatePrint();} }
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
  function render(drawRows=true) {
    const removable=removableDraft();
    document.querySelector('#export-delete-heading').hidden=!removable;
    if (!currentBox) {
      boxNumber.textContent = "No open export box";
      boxStatus.textContent = "View only";
      boxCount.textContent = sheetTotal.textContent = "0 phones";
      boxRemaining.textContent = "No open box to display";
      startNextButton.disabled = imeiInput.disabled = printButton.disabled = true;
      tableBody.innerHTML = '<tr><td class="export-sheet-empty" colspan="7">No open export box is available.</td></tr>';
      return;
    }
    const count = lines.length,mayRemove=removable;
    const isFinished = ["full", "closed"].includes(String(currentBox.box_status));

    boxNumber.textContent = currentBox.box_number || "Export Box";
    boxStatus.textContent = isFinished ? "Box finished" : "Open for scanning";
    boxCount.textContent = `${count} phone${count === 1 ? "" : "s"}`;
    boxRemaining.textContent = isFinished ? "Start a new box" : "Ready to scan";
    progressBar.style.width = count ? "100%" : "0";
    startNextButton.disabled = !(isFinished ? can("scan") : can("save")) || boxBusy || scanning || (!isFinished && (count === 0 || workflow?.printed_revision !== workflow?.revision || !workflow?.printed_at));
    startNextButton.textContent = isFinished ? "Start next box" : "Save Box";
    printButton.disabled = !can("print") || count === 0 || scanning || boxBusy;
    confirmPrintButton.disabled = !can("print") || scanning || boxBusy;
    imeiInput.disabled = scannerLocked || !can("scan") || boxBusy || isFinished || scanning || !workflow || Boolean(scanErrorDialog?.open);
    sheetTitle.textContent = `${currentBox.box_number || "Export Box"} - Export packing list`;
    sheetTotal.textContent = `${count} valid phone${count === 1 ? "" : "s"}`;
    if(!drawRows){tableBody.querySelectorAll('[data-draft-remove]').forEach(b=>b.disabled=boxBusy||scanning);return;}

    const validRows=lines.map(line=>`<tr><td>${escapeHtml(line.serial_no)}</td><td>${escapeHtml(line.imei)}</td><td>${escapeHtml(line.model||"-")}</td><td>${escapeHtml(line.storage_gb?`${line.storage_gb} GB`:"-")}</td><td>${escapeHtml(line.final_grade||"-")}</td><td>${escapeHtml(line.color||"-")}</td><td>${escapeHtml(line.box_number||currentBox.box_number)}</td>${mayRemove?`<td class="export-line-action">${removable?`<button type="button" class="secondary-button" data-draft-remove="${escapeHtml(line.id)}" data-capability="scan" data-capability-page="export_boxes" ${boxBusy||scanning?'disabled':''} aria-label="Delete ${escapeHtml(line.imei)} from this box">Delete</button>`:''}</td>`:''}</tr>`).join('');
    tableBody.innerHTML=validRows||`<tr><td class="export-sheet-empty" colspan="${7+(mayRemove?1:0)}">Scan the first Ready Stock IMEI to add it to this box.</td></tr>`;

  }

  async function removeDraftLine(itemId) {
    if (!removableDraft() || boxBusy || scanning) return;
    boxBusy=true;clearTimeout(scanTimer);render();setMessage();
    try {
      const {error}=await getClient().rpc('remove_draft_box_imei_v1',{p_box_id:currentBox.box_id,p_revision:workflow.revision,p_item_id:itemId});
      if(error)throw error;
      await loadLines();
      setMessage('Phone removed from this draft box and returned to Ready Stock. Print the updated sheet before saving.','success');
    } catch(error) {
      setMessage(error.message||'The phone could not be removed.');
      try { await loadLines(); } catch (_) {}
    } finally { boxBusy=false;render();focusScanner(); }
  }
  async function loadLines() {
    if (!currentBox?.box_id) return;
    const { data, error } = await getClient().rpc("get_export_box_lines", { p_box_id: currentBox.box_id });
    if (error) throw error;
    lines = Array.isArray(data) ? data : [];
    await loadWorkflow();
    render();
  }

  async function loadCurrentBox() {
    let nextBox;
    if (!can("scan")) {
      const { data, error } = await getClient().from("export_boxes").select("id, box_number, box_status, opened_at").eq("box_status", "open").order("opened_at", { ascending: true }).limit(1);
      if (error) throw error;
      const row = data?.[0];
      nextBox = row ? { ...row, box_id: row.id } : null;
    } else {
      const { data, error } = await getClient().rpc("get_or_create_open_export_box", { p_capacity: 1000000 });
      if (error) throw error;
      nextBox = asRow(data);
      if (!nextBox) throw new Error("An export box could not be opened.");
    }
    let nextLines = [];
    if (nextBox) {
      const { data, error } = await getClient().rpc("get_export_box_lines", { p_box_id: nextBox.box_id });
      if (error) throw error;
      nextLines = Array.isArray(data) ? data : [];
    }
    setIssueBox(nextBox?.box_id);
    currentBox = nextBox;
    lines = nextLines;
    await loadWorkflow();
    render();
    focusScanner();
  }

  async function loadWorkflow() {
    printedSnapshot=null;confirmPrintButton.hidden=true;workflow=null;
    if (!currentBox?.box_id) return;
    const {data,error}=await getClient().rpc("get_box_workflow_v1",{p_box_id:currentBox.box_id});
    if(error)throw error;
    setIssueBox(currentBox.box_id);
    workflow=data.box;
    // Print the lines and revision from the same database snapshot. A second
    // scanner must not make an older sheet qualify as the current printed box.
    lines=data.lines || [];
    currentBox={...currentBox,...data.box};
  }
  async function printBox() {
    if(!can("print") || boxBusy || scanning || !lines.length)return;
    boxBusy=true;render();setMessage();
    try {
      await loadLines();
      const snapshot={boxId:currentBox.box_id,revision:workflow.revision};
      await window.GREENLOOP_BOX_PRINT.open({box:{...workflow},lines:[...lines]},{allowed:()=>can("print")});
      printedSnapshot=snapshot;
      confirmPrintButton.hidden=!can("print");
      setMessage("Print from the preview. After printing succeeds, close the preview and choose Printing completed.","success");
    } catch(error){setMessage(error.message || "Printing could not start.");}
    finally{boxBusy=false;render();}
  }
  async function confirmPrint() {
    if(!can("print") || boxBusy || scanning || !printedSnapshot)return;
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
    workflow=data.box;currentBox={...currentBox,...data.box};lines=data.lines;invalidatePrint();
  }
  async function scanImei() {
    clearTimeout(scanTimer);
    if(scannerLocked || !can("scan") || boxBusy || scanning || scanErrorDialog?.open || !currentBox?.box_id || currentBox.box_status!=="open")return;
    const imei=imeiInput.value.replace(/\D/g,"").slice(0,15);imeiInput.value=imei;
    if(imei.length!==15){if(imei){imeiInput.value="";showScanIssues([{imei,reason:"Use a valid 15-digit IMEI."}]);}return;}
    return pasteImeis([imei],{isCurrent:()=>!scannerLocked});
  }
  async function pasteImeis(imeis,options) {
    clearTimeout(scanTimer);
    if(scannerLocked || !can("scan") || boxBusy || scanning || scanErrorDialog?.open || !currentBox?.box_id || currentBox.box_status!=="open")throw Error("This box is not available for scanning.");
    if(!options.isCurrent())return {loaded:0,issues:[]};
    const issues=(options.rejected||[]).map(r=>({imei:r.imei,reason:r.message}));
    if(!imeis.length){imeiInput.value="";showScanIssues(issues);return {loaded:0,issues:[]};}
    scanning=true;setMessage();render(false);
    try{
      if(!workflow)throw Error("The current box could not be verified. Reload Box Entry before retrying.");
      // One request validates, saves and returns the canonical box/lines snapshot.
      const {data,error}=await getClient().rpc("scan_imeis_to_export_box_v1",{p_box_id:currentBox.box_id,p_revision:workflow.revision,p_imeis:imeis});
      if(error)throw error;
      if(options.isCurrent()){
        applyScanSnapshot(data,imeis);imeiInput.value="";
        issues.push(...data.results.filter(r=>!r.ok).map(r=>({imei:r.imei,reason:r.message})));
        if(issues.length)showScanIssues(issues);
        setMessage(data.loaded?`${data.loaded} phone${data.loaded===1?"":"s"} added to ${data.box.box_number}. Ready to scan.`:"","success");
      }
      return {loaded:data.loaded,issues:[]};
    }catch(error){
      // The response may be lost after commit. Read once; never repeat the write.
      let verified=false;
      try{if(options.isCurrent()){await loadWorkflow();verified=true;}}catch(_){}
      if(options.isCurrent()){
        const unresolved=verified?imeis.filter(v=>!lines.some(r=>r.imei===v)):imeis;
        for(const imei of unresolved)issues.push({imei,reason:(error.message||"The scan result could not be verified.")+(verified?"":" Reload Box Entry before retrying; the saved result is unknown.")});
        imeiInput.value="";setMessage();showScanIssues(issues);
        if(verified&&!unresolved.length)setMessage("The saved phones were confirmed in the box. Ready to scan.","success");
      }
      return {loaded:verified?imeis.filter(v=>lines.some(r=>r.imei===v)).length:0,issues:[]};
    }finally{scanning=false;render();focusScanner();}
  }

  async function finishAndStartNext() {
    if (!currentBox || !(String(currentBox.box_status) === "open" ? can("save") : can("scan")) || scanning || boxBusy) return;
    if (!lines.length && String(currentBox.box_status) === "open") return;
    if (String(currentBox.box_status) === "open" && (workflow?.printed_revision !== workflow?.revision || !workflow?.printed_at)) { setMessage("Print and confirm printing before saving this box."); return; }
    boxBusy = true;
    clearTimeout(scanTimer);
    render();
    try {
      if (String(currentBox.box_status) === "open") {
        const { error } = await getClient().rpc("close_export_box", { p_box_id: currentBox.box_id });
        if (error) throw error;
        currentBox.box_status = "closed";
      }
      const savedNumber=currentBox.box_number;
      await loadCurrentBox();
      imeiInput.value = "";
      setMessage(savedNumber + " saved to Accounts." + (currentBox ? " " + currentBox.box_number + " is ready for scanning." : ""), "success");
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
    await window.GREENLOOP_ACCESS_READY;await window.GREENLOOP_STOCK?.ready();
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "export_boxes") return;
    canEdit = window.GREENLOOP_PAGE_ACCESS.canEdit === true;
    app.hidden = false;
    await loadCurrentBox();
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
    if (event.key === "Enter" || event.key === "Tab" && /^\d{15}$/.test(imeiInput.value)) { event.preventDefault(); scanImei(); }
  });
  startNextButton.addEventListener("click", () => finishAndStartNext().catch((error) => setMessage(error.message || "The next export box could not be opened.")));
  printButton.addEventListener("click", printBox);
  confirmPrintButton.addEventListener("click", confirmPrint);
  tableBody.addEventListener('click',event=>{const button=event.target.closest('[data-draft-remove]');if(button)removeDraftLine(button.dataset.draftRemove);});
  for(const event of ['greenloop:office-locked','greenloop:signed-out'])window.addEventListener(event,()=>{scannerLocked=true;clearTimeout(scanTimer);cancelAnimationFrame(scanFocusFrame);scanErrorDialog?.close();invalidatePrint();render();});
  window.addEventListener("pagehide",()=>{clearTimeout(scanTimer);cancelAnimationFrame(scanFocusFrame);});
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Export Boxes could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
