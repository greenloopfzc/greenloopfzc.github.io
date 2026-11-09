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
  const sheetDate = document.querySelector("#export-sheet-date");
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
  let scanIssues=[],issueBoxId=null,issueSequence=0,needsCleanPrint=false;
  let scanTimer;
  let toastTimer;
  let scanning = false;
  let boxBusy = false;
  let canEdit = false;
  const can = capability => window.GREENLOOP_CAN?.(capability,"export_boxes") === true;

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
  function setIssueBox(id) { if(issueBoxId!==id){scanIssues=[];issueBoxId=id;needsCleanPrint=false;invalidatePrint();} }
  function addScanIssue(imei,reason) {
    setIssueBox(currentBox?.box_id);scanIssues.push({id:String(++issueSequence),imei:String(imei||''),reason:String(reason||'This IMEI could not be added to the box.')});
    needsCleanPrint=true;invalidatePrint();
  }
  function removeScanIssue(id) {
    if(!can('scan')||boxBusy||scanning)return;
    scanIssues=scanIssues.filter(r=>r.id!==id);invalidatePrint();render();if(!imeiInput.disabled)imeiInput.focus();
  }
  function removableDraft() {
    return can("scan") && currentBox?.box_status === "open" && workflow?.state === "draft" && !workflow?.saved_at;
  }
  function render() {
    const removable=removableDraft();
    document.querySelector('#export-delete-heading').hidden=!(removable||scanIssues.length&&can('scan'));
    document.querySelector('#export-issue-heading').hidden=!scanIssues.length;
    if (!currentBox) {
      boxNumber.textContent = "No open export box";
      boxStatus.textContent = "View only";
      boxCount.textContent = sheetTotal.textContent = "0 phones";
      boxRemaining.textContent = "No open box to display";
      startNextButton.disabled = imeiInput.disabled = printButton.disabled = true;
      tableBody.innerHTML = '<tr><td class="export-sheet-empty" colspan="7">No open export box is available.</td></tr>';
      return;
    }
    const count = lines.length,issueCount=scanIssues.length,mayRemove=removable||issueCount&&can("scan");
    const isFinished = ["full", "closed"].includes(String(currentBox.box_status));

    boxNumber.textContent = currentBox.box_number || "Export Box";
    boxStatus.textContent = isFinished ? "Box finished" : "Open for scanning";
    boxCount.textContent = `${count} phone${count === 1 ? "" : "s"}`;
    boxRemaining.textContent = issueCount ? `${issueCount} scan issue${issueCount===1?"":"s"} - delete before saving` : isFinished ? "Start a new box" : "Ready to scan";
    progressBar.style.width = count ? "100%" : "0";
    startNextButton.disabled = !(isFinished ? can("scan") : can("save")) || boxBusy || scanning || issueCount>0 || needsCleanPrint || (!isFinished && (count === 0 || workflow?.printed_revision !== workflow?.revision || !workflow?.printed_at));
    startNextButton.textContent = isFinished ? "Start next box" : "Save Box";
    printButton.disabled = !can("print") || count+issueCount === 0 || scanning || boxBusy;
    confirmPrintButton.disabled = !can("print") || scanning || boxBusy || issueCount>0;
    imeiInput.disabled = !can("scan") || boxBusy || isFinished || scanning;
    sheetTitle.textContent = `${currentBox.box_number || "Export Box"} - Export packing list`;
    sheetDate.textContent = `Opened: ${formatDateTime(currentBox.opened_at)}`;
    sheetTotal.textContent = `${count} valid phone${count === 1 ? "" : "s"}`+(issueCount?` · ${issueCount} scan issue${issueCount===1?"":"s"}`:"");

    const validRows=lines.map(line=>`<tr><td>${escapeHtml(line.serial_no)}</td><td>${escapeHtml(line.imei)}</td><td>${escapeHtml(line.model||"-")}</td><td>${escapeHtml(line.storage_gb?`${line.storage_gb} GB`:"-")}</td><td>${escapeHtml(line.final_grade||"-")}</td><td>${escapeHtml(line.color||"-")}</td><td>${escapeHtml(line.box_number||currentBox.box_number)}</td>${issueCount?'<td class="export-scan-reason">-</td>':''}${mayRemove?`<td class="export-line-action">${removable?`<button type="button" class="secondary-button" data-draft-remove="${escapeHtml(line.id)}" data-capability="scan" data-capability-page="export_boxes" ${boxBusy||scanning?'disabled':''} aria-label="Delete ${escapeHtml(line.imei)} from this box">Delete</button>`:''}</td>`:''}</tr>`).join('');
    const lastSerial=lines.reduce((n,r)=>Math.max(n,Number(r.serial_no)||0),0);
    const issueRows=scanIssues.map((r,i)=>`<tr class="export-scan-issue" data-scan-issue="${r.id}"><td>${lastSerial+i+1}</td><td>${escapeHtml(r.imei)}</td><td>-</td><td>-</td><td>-</td><td>-</td><td>${escapeHtml(currentBox.box_number)}</td><td class="export-scan-reason">${escapeHtml(r.reason)}</td>${mayRemove?`<td class="export-line-action"><button type="button" class="secondary-button" data-issue-remove="${r.id}" data-capability="scan" data-capability-page="export_boxes" ${boxBusy||scanning?'disabled':''} aria-label="Delete scan issue ${escapeHtml(r.imei)}">Delete</button></td>`:''}</tr>`).join('');
    tableBody.innerHTML=validRows+issueRows||`<tr><td class="export-sheet-empty" colspan="${7+(mayRemove?1:0)}">Scan the first Ready Stock IMEI to add it to this box.</td></tr>`;

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
    } finally { boxBusy=false;render();if(!imeiInput.disabled)imeiInput.focus(); }
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
    if (!imeiInput.disabled) imeiInput.focus();
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
    if(!can("print") || boxBusy || scanning || !(lines.length+scanIssues.length))return;
    boxBusy=true;render();setMessage();
    try {
      await loadLines();
      const snapshot={boxId:currentBox.box_id,revision:workflow.revision};
      await window.GREENLOOP_BOX_PRINT.open({box:{...workflow},lines:[...lines],issues:scanIssues.map(r=>({...r}))},{allowed:()=>can("print")});
      if(scanIssues.length){invalidatePrint();setMessage();return;}
      printedSnapshot=snapshot;
      confirmPrintButton.hidden=!can("print");
      setMessage("Print from the preview. After printing succeeds, close the preview and choose Printing completed.","success");
    } catch(error){setMessage(error.message || "Printing could not start.");}
    finally{boxBusy=false;render();}
  }
  async function confirmPrint() {
    if(!can("print") || boxBusy || scanning || !printedSnapshot || scanIssues.length)return;
    boxBusy=true;render();
    try {
      const {error}=await getClient().rpc("mark_box_printed_v1",{p_box_id:printedSnapshot.boxId,p_revision:printedSnapshot.revision});if(error)throw error;
      await loadWorkflow();needsCleanPrint=false;setMessage("Printing confirmed. Save Box to send it to Accounts.","success");
    }catch(error){printedSnapshot=null;confirmPrintButton.hidden=true;setMessage(error.message);}
    finally{boxBusy=false;render();}
  }
  async function scanImei() {
    const imei = imeiInput.value.replace(/\D/g, "").slice(0, 15);
    imeiInput.value = imei;
    if (!can("scan") || boxBusy || scanning || !currentBox?.box_id || currentBox.box_status!=="open") return;
    if(imei.length!==15){if(imei){addScanIssue(imei,"Use a valid 15-digit IMEI.");imeiInput.value="";render();}return;}

    scanning = true;
    setMessage();
    render();
    try {
      const { data, error } = await getClient().rpc("scan_imei_to_export_box", { p_imei: imei });
      if (error) throw error;
      const result = asRow(data);
      if (!result) throw new Error("The IMEI was not added to the export box.");

      currentBox = {
        box_id: result.box_id,
        box_number: result.box_number,
        box_status: result.box_status,
        opened_at: currentBox?.opened_at || new Date().toISOString()
      };
      imeiInput.value = "";
      await loadLines();
      setMessage(`${imei} added to ${result.box_number}. Ready Stock was updated.`, "success");
      showToast(`Phone ${result.serial_no} added to the export box.`);
      return {ok:true};
    } catch (error) {
      addScanIssue(imei,error.message||"This IMEI could not be added to the export box.");
      imeiInput.value="";setMessage();
      return {ok:false,error:error.message};
    } finally {
      scanning = false;
      render();
      if (!imeiInput.disabled) imeiInput.focus();
    }
  }

  async function pasteImeis(imeis, options) {
    clearTimeout(scanTimer);
    if (!can("scan") || boxBusy || scanning || !currentBox?.box_id || currentBox.box_status !== "open") throw new Error("This box is not available for scanning.");
    if (!options.isCurrent()) return {loaded:0,issues:[]};
    for(const rejected of options.rejected||[])addScanIssue(rejected.imei,rejected.message);
    if(!imeis.length){imeiInput.value="";render();return {loaded:0,issues:[]};}
    scanning=true;setMessage();render();
    try {
      const {data,error}=await getClient().rpc("scan_imeis_to_export_box_v1",{p_box_id:currentBox.box_id,p_revision:workflow.revision,p_imeis:imeis});
      if(error)throw error;
      if(!data?.box || !Array.isArray(data.lines) || !Array.isArray(data.results))throw new Error("The box response could not be verified. Refresh the box before retrying.");
      if(options.isCurrent()) {
        workflow=data.box;currentBox={...currentBox,...data.box};lines=data.lines;
        invalidatePrint();imeiInput.value="";
        for(const r of data.results)if(!r.ok)addScanIssue(r.imei,r.message);
        setMessage(scanIssues.length?"":`${data.loaded} of ${imeis.length} IMEIs added to ${data.box.box_number}. Ready to scan.`,"success");
      }
      return {loaded:data.loaded,issues:[]};
    } catch(error) {
      // A lost response can follow a committed request. Reload the canonical
      // box once instead of retrying writes and risking duplicate scans.
      try { if(options.isCurrent())await loadLines(); } catch (_) {}
      if(options.isCurrent()){
        for(const imei of imeis)if(!lines.some(r=>r.imei===imei))addScanIssue(imei,error.message||"The scan result could not be verified. Check this phone before retrying.");
        imeiInput.value="";setMessage();
      }
      return {loaded:imeis.filter(v=>lines.some(r=>r.imei===v)).length,issues:[]};
    } finally {scanning=false;render();if(!imeiInput.disabled)imeiInput.focus();}
  }

  async function finishAndStartNext() {
    if (!currentBox || !(String(currentBox.box_status) === "open" ? can("save") : can("scan")) || scanning || boxBusy) return;
    if(scanIssues.length||needsCleanPrint)return;
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
    } finally { boxBusy = false; render(); }
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
    if (imeiInput.value.length === 15) scanTimer = setTimeout(scanImei, 180);
  });
  imeiInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); scanImei(); }
  });
  startNextButton.addEventListener("click", () => finishAndStartNext().catch((error) => setMessage(error.message || "The next export box could not be opened.")));
  printButton.addEventListener("click", printBox);
  confirmPrintButton.addEventListener("click", confirmPrint);
  tableBody.addEventListener('click',event=>{const button=event.target.closest('[data-draft-remove]');if(button)removeDraftLine(button.dataset.draftRemove);const issue=event.target.closest('[data-issue-remove]');if(issue)removeScanIssue(issue.dataset.issueRemove);});
  for(const event of ['greenloop:office-locked','greenloop:signed-out'])window.addEventListener(event,()=>{scanIssues=[];invalidatePrint();render();});
  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "Export Boxes could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
