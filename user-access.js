(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#user-access-app");
  const permissionMessage = document.querySelector("#permission-message");
  const createUserForm = document.querySelector("#create-user-form");
  const newFullName = document.querySelector("#new-full-name");
  const newUsername = document.querySelector("#new-username");
  const newPassword = document.querySelector("#new-password");
  const newConfirmPassword = document.querySelector("#new-confirm-password");
  const newRoleOptions = document.querySelector("#new-role-options");
  const createUserMessage = document.querySelector("#create-user-message");
  const createUserButton = document.querySelector("#create-user-button");
  const userList = document.querySelector("#user-list");
  const editor = document.querySelector("#access-editor");
  const selectUserMessage = document.querySelector("#select-user-message");
  const fullName = document.querySelector("#access-full-name");
  const username = document.querySelector("#access-username");
  const active = document.querySelector("#access-active");
  const roleOptions = document.querySelector("#role-options");
  const message = document.querySelector("#access-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  let client;
  let users = [];
  let selectedUserId = "";
  let currentUserIsSuperAdmin = false;
  let savingAccess = false;
  let creatingUser = false;

  const accessSections = {
    "login-activity": ["access-login-view", "Login Activity"],
    "greenloop-accounts": ["access-accounts-view", "Greenloop Accounts with Page Permissions"],
    "add-greenloop-user": ["access-create-view", "Add Greenloop User"]
  };

  function sectionAllowed(section) {
    if (section === "add-greenloop-user") return can("create_users");
    if (section === "login-activity") return can("login_activity");
    return can("view");
  }

  function applySectionPermissions() {
    app.querySelectorAll("[data-access-section]").forEach(button => {
      button.hidden = !sectionAllowed(button.dataset.accessSection);
    });
  }

  function showAccessSection(focusHeading = false) {
    const section = location.hash.slice(1);
    const selected = Object.prototype.hasOwnProperty.call(accessSections, section) && sectionAllowed(section) ? section : "";
    Object.entries(accessSections).forEach(([key, [id]]) => {
      document.getElementById(id).hidden = key !== selected;
    });
    app.querySelectorAll("[data-access-section]").forEach((button) => {
      const active = button.dataset.accessSection === selected;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-expanded", String(active));
    });
    document.getElementById("user-access-section-heading").hidden = !selected;
    const heading = document.getElementById("user-access-section-title");
    heading.textContent = selected ? accessSections[selected][1] : "";
    if (selected && focusHeading) heading.focus({preventScroll: true});
    if (selected === "login-activity") window.GREENLOOP_LOGIN_TRACKER?.refresh?.();
  }

  const catalog = window.GREENLOOP_PERMISSION_CATALOG;
  const can = capability => window.GREENLOOP_CAN?.(capability, "user_access") === true;
  const specialPages = ["supplier_returns", "supplier_return_approval", "supplier_return_handover", "damage_report", "tv_manual_entry", "accounts", "stock_exported"];
  const pageGuideData = catalog?.pages || [];

  function getClient() {
    return (client ||= window.GREENLOOP_GET_CLIENT());
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "'": "&#39;",
      '"': "&quot;"
    })[character]);
  }

  function setMessage(target, text = "", type = "error") {
    target.textContent = text;
    target.classList.toggle("is-visible", Boolean(text));
    target.classList.toggle("is-success", type === "success");
  }

  function setMenu(open) {
    sidebar.classList.toggle("is-open", open);
    backdrop.hidden = !open;
    document.body.classList.toggle("menu-open", open);
  }

  function pageName(pageKey) {
    return catalog.byPage[pageKey]?.label || pageKey;
  }

  function capabilityObject(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Page permissions could not be verified. Refresh and try again.");
    const result = {};
    for (const page of pageGuideData) {
      const available = new Set(page.capabilities.map(item => item.key));
      const selected = value[page.key];
      if (!Array.isArray(selected) || selected.some(key => !available.has(key))) throw new Error("Page permissions could not be verified. Refresh and try again.");
      result[page.key] = [...new Set(selected)];
      if (result[page.key].length && !result[page.key].includes("view")) throw new Error("Page permissions are incomplete. Refresh and try again.");
    }
    return result;
  }

  function capabilityRoleQualifier(pageKey, capability) {
    if (pageKey === "inventory" && capability === "approve") return "Owner, Manager or Super Admin";
    if (pageKey === "reports" && capability === "damage_reset") return "Owner or Super Admin";
    if (pageKey === "user_access" && capability === "login_activity") return "Super Admin only";
    return "";
  }

  function capabilityCheckbox(page, item, values, visible, locked, payableEnabled) {
    const qualifier = capabilityRoleQualifier(page.key, item.key);
    const checked = visible && values.includes(item.key) && (item.key !== "payable" || payableEnabled);
    const disabled = locked || !visible || item.key === "payable" && !payableEnabled;
    return `<label class="permission-capability"><input type="checkbox" data-access-capability="${escapeHtml(item.key)}" aria-label="${escapeHtml(page.label)}: ${escapeHtml(item.label)}${qualifier ? ` (${escapeHtml(qualifier)})` : ""}"${checked ? " checked" : ""}${disabled ? " disabled" : ""}><span>${escapeHtml(item.label)}${qualifier ? `<span class="permission-capability-role">${escapeHtml(qualifier)}</span>` : ""}</span></label>`;
  }

  function pageCheckboxes(selected = {}, partnerAccess = "none", isNew = false) {
    const permitted = can(isNew ? "create_users" : "manage_access");
    const pages = isNew && !currentUserIsSuperAdmin ? pageGuideData.filter(page => page.key !== "user_access") : pageGuideData;
    return pages.map(page => {
      const values = Array.isArray(selected[page.key]) ? selected[page.key] : [];
      const visible = values.includes("view");
      const payableEnabled = page.key !== "damage_report" || values.includes("original_prices") || values.includes("copy_prices");
      const locked = !permitted || page.key === "user_access" && !currentUserIsSuperAdmin;
      const actions = page.capabilities.filter(item => item.key !== "view");
      return `<article class="role-option${visible ? " is-selected" : ""}" data-page-permission="${escapeHtml(page.key)}">
        <div class="permission-page-heading"><label class="permission-check"><input type="checkbox" data-page-view value="${escapeHtml(page.key)}" aria-label="${escapeHtml(page.label)}: View"${visible ? " checked" : ""}${locked ? " disabled" : ""}><strong>${escapeHtml(page.label)}</strong><span class="permission-view-label">View</span></label><small>${escapeHtml(page.description)}</small><span class="permission-selection-count">${visible ? values.length - 1 : 0} additional actions selected</span></div>
        <div class="permission-capabilities" role="group" aria-label="${escapeHtml(page.label)} permissions">${actions.map(item => capabilityCheckbox(page, item, values, visible, locked, payableEnabled)).join("")}</div>
      </article>`;
    }).join("") + `<article class="role-option${partnerAccess !== "none" ? " is-selected" : ""}" data-partner-name-option><div class="permission-page-heading"><label class="permission-check"><input type="checkbox" data-partner-names${partnerAccess !== "none" ? " checked" : ""}${permitted ? "" : " disabled"}><strong>Supplier &amp; Customer Names</strong></label><small>Show confidential names. Supplier and customer codes remain visible on allowed pages.</small></div></article>`;
  }

  function collectSelection(container) {
    const capabilities = Object.fromEntries(pageGuideData.map(page => [page.key, []]));
    const pagePermissions = Object.fromEntries(specialPages.map(key => [key, "none"]));
    container.querySelectorAll("[data-page-permission]").forEach(card => {
      const key = card.dataset.pagePermission;
      if (!card.querySelector("[data-page-view]").checked) return;
      const selected = ["view", ...[...card.querySelectorAll("[data-access-capability]:checked")].map(field => field.dataset.accessCapability)];
      capabilities[key] = selected;
      pagePermissions[key] = catalog.byPage[key].capabilities.some(item => item.write && selected.includes(item.key)) ? "edit" : "view";
    });
    return {capabilities, pagePermissions, partnerNamesAccess:container.querySelector("[data-partner-names]")?.checked ? "view" : "none"};
  }

  function syncPermissionCard(checkbox) {
    const card = checkbox.closest("[data-page-permission]");
    if (!card) { checkbox.closest("[data-partner-name-option]")?.classList.toggle("is-selected", checkbox.checked); return; }
    const isNew = newRoleOptions.contains(card);
    if (!can(isNew ? "create_users" : "manage_access")) return;
    const view = card.querySelector("[data-page-view]");
    if (checkbox === view && !view.checked) card.querySelectorAll("[data-access-capability]").forEach(field => { field.checked = false; });
    card.classList.toggle("is-selected", view.checked);
    card.querySelectorAll("[data-access-capability]").forEach(field => { field.disabled = !view.checked || card.dataset.pagePermission === "user_access" && !currentUserIsSuperAdmin; });
    if (card.dataset.pagePermission === "damage_report") {
      const payable = card.querySelector('[data-access-capability="payable"]');
      const priced = card.querySelector('[data-access-capability="original_prices"]').checked || card.querySelector('[data-access-capability="copy_prices"]').checked;
      if (!priced) payable.checked = false;
      payable.disabled = !view.checked || !priced;
      payable.closest("label").title = priced ? "" : "Select Original or Copy prices to show payable amounts.";
    }
    card.querySelector(".permission-selection-count").textContent = card.querySelectorAll("[data-access-capability]:checked").length + " additional actions selected";
  }

  function renderNewUserPages() {
    newRoleOptions.innerHTML = pageCheckboxes({}, "none", true);
    createUserForm.querySelectorAll(".create-user-fields input").forEach(field => { field.disabled = !can("create_users"); });
    createUserButton.disabled = creatingUser || !can("create_users");
  }

  function renderUsers() {
    const matchingUsers = window.GREENLOOP_FILTERS.use('user-list-filters', users, {before:userList,fields:[['status','Status']],onChange:()=>renderUsers(),project:u=>({...u,status:u.is_active?'Active':'Inactive'}),searchFields:['full_name','login_username']});
    userList.innerHTML = matchingUsers.length ? matchingUsers.map((user) => {
      const pages = pageGuideData.filter(page => user.capabilities[page.key].includes("view"));
      const actionCount = pages.reduce((total, page) => total + user.capabilities[page.key].filter(key => key !== "view").length, 0);
      return `
        <button class="user-list-item${String(user.user_id) === String(selectedUserId) ? " active" : ""}${user.is_active ? "" : " inactive"}" type="button" data-user-id="${escapeHtml(user.user_id)}">
          <strong>${escapeHtml(user.full_name || user.login_username || "Unnamed user")}</strong>
          <small>@${escapeHtml(user.login_username || "No username")}</small>
          <span class="user-role-summary">${escapeHtml(pages.length ? `${pages.length} pages · ${actionCount} additional actions` : "No page assigned")}</span>
        </button>
      `;
    }).join("") : '<p class="access-empty">No users match these filters.</p>';
  }

  function renderEditor() {
    const user = users.find((item) => String(item.user_id) === String(selectedUserId));
    editor.hidden = !user;
    selectUserMessage.hidden = Boolean(user);
    setMessage(message);
    if (!user) return;

    fullName.value = user.full_name || "";
    username.value = user.login_username || "";
    active.checked = Boolean(user.is_active);
    roleOptions.innerHTML = pageCheckboxes(user.capabilities, user.partner_names_access);
    [fullName, username, active].forEach(field => { field.disabled = !can("manage_access"); });
    document.querySelector("#save-access").disabled = savingAccess || !can("manage_access");
    const settings=user.tv_display;
    tvOnly.checked=settings.tv_only;
    tvOnly.disabled=settings.protected_account || !can("manage_access");
    [tvParts,tvOriginal,tvCopy].forEach(field => { field.disabled = !can("manage_access"); });
    tvParts.checked=settings.show_parts;tvOriginal.checked=settings.show_original;tvCopy.checked=settings.show_copy;
    document.querySelector("#damage-tv-mode-help").textContent=settings.protected_account ? "Administrator account: use a separate staff account for the TV." : "Open the damage wall directly. Entry, PDF and other software pages are blocked for this account.";
    tvModeChanged();
  }

  const tvOnly = document.querySelector("#access-tv-only");
  const tvParts = document.querySelector("#access-tv-parts");
  const tvOriginal = document.querySelector("#access-tv-original");
  const tvCopy = document.querySelector("#access-tv-copy");
  function tvModeChanged() {
    const locked = tvOnly.checked;
    document.querySelector("#damage-tv-choices").hidden = !locked;
    document.querySelector("#access-page-permissions").hidden=locked;
    roleOptions.querySelectorAll("[data-page-permission]").forEach(card => {
      const pageLocked = locked || !can("manage_access") || card.dataset.pagePermission === "user_access" && !currentUserIsSuperAdmin;
      const view = card.querySelector("[data-page-view]");
      view.disabled = pageLocked;
      card.querySelectorAll("[data-access-capability]").forEach(field => { field.disabled = pageLocked || !view.checked; });
      if (card.dataset.pagePermission === "damage_report") {
        const payable = card.querySelector('[data-access-capability="payable"]');
        const priced = card.querySelector('[data-access-capability="original_prices"]').checked || card.querySelector('[data-access-capability="copy_prices"]').checked;
        if (!priced) payable.checked = false;
        payable.disabled = pageLocked || !view.checked || !priced;
      }
    });
    roleOptions.querySelector("[data-partner-names]").disabled = locked || !can("manage_access");
  }
  tvOnly.addEventListener("change", tvModeChanged);

  async function loadUsers(preferredUserId = selectedUserId) {
    if (!can("view")) return;
    const [matrixResult, capabilityResult, tvResult, partnerResult] = await Promise.all([
      getClient().rpc("get_user_page_access_matrix_v2"),
      getClient().rpc("get_user_page_capabilities_v1"),
      getClient().rpc("get_user_damage_tv_settings_v1"),
      getClient().rpc("get_user_partner_name_access_matrix")
    ]);
    for (const result of [matrixResult, capabilityResult, tvResult, partnerResult]) if (result.error) throw result.error;
    const tvSettings = new Map((tvResult.data || []).map(row => [String(row.user_id), row]));
    const capabilitySettings = new Map((capabilityResult.data || []).map(row => [String(row.user_id), capabilityObject(row.capabilities)]));
    const partnerSettings = new Map((partnerResult.data || []).map(row => [String(row.user_id), ["view", "edit"].includes(row.access_level) || row.can_view === true ? "view" : "none"]));
    const nextUsers = (matrixResult.data || []).map(user => ({...user, tv_display:tvSettings.get(String(user.user_id)), capabilities:capabilitySettings.get(String(user.user_id)), partner_names_access:partnerSettings.get(String(user.user_id)) || "none"}));
    if (nextUsers.some(user => !user.tv_display || !user.capabilities)) throw new Error("Account permissions could not be verified. Refresh the account list.");
    users = nextUsers;
    const preferred = String(preferredUserId || "");
    selectedUserId = users.some((user) => String(user.user_id) === preferred)
      ? preferred
      : String(users[0]?.user_id || "");
    renderUsers();
    renderEditor();
  }

  async function readFunctionError(error) {
    const fallback = error?.message || "The user account could not be created.";
    const response = error?.context;
    if (!response || typeof response.clone !== "function") return fallback;

    try {
      const payload = await response.clone().json();
      return payload?.error || payload?.message || fallback;
    } catch {
      return fallback;
    }
  }

  async function createUser(event) {
    event.preventDefault();
    if (creatingUser || !can("create_users")) return;
    setMessage(createUserMessage);
    if (!createUserForm.reportValidity()) return;
    if (newPassword.value !== newConfirmPassword.value) { setMessage(createUserMessage, "Passwords do not match."); newConfirmPassword.focus(); return; }
    const selected = collectSelection(newRoleOptions);
    if (!Object.values(selected.capabilities).some(values => values.includes("view"))) { setMessage(createUserMessage, "Select View for at least one page."); return; }
    creatingUser = true;
    createUserButton.disabled = true;
    createUserButton.textContent = "Creating...";
    let createdAccount;
    try {
      const {data, error} = await getClient().functions.invoke("admin-create-user", {body:{
        full_name:newFullName.value.trim(), username:newUsername.value.trim(), password:newPassword.value,
        page_permissions:selected.pagePermissions, capabilities:selected.capabilities, partner_names_access:selected.partnerNamesAccess
      }});
      if (error) throw new Error(await readFunctionError(error));
      if (!data?.success || !data.user_id) throw new Error(data?.error || "The user account could not be created.");
      createdAccount = data;
      createUserForm.reset();
      renderNewUserPages();
      await loadUsers(data.user_id);
      setMessage(createUserMessage, `User @${data.username} was created with the selected permissions.`, "success");
    } catch (error) {
      setMessage(createUserMessage, createdAccount
        ? `User @${createdAccount.username} was created and permissions were saved, but the account list could not refresh. Refresh the list; do not create the account again. ${error.message || ""}`
        : error.message || "The user account could not be created.");
    } finally {
      creatingUser = false;
      createUserButton.disabled = !can("create_users");
      createUserButton.textContent = "Create user";
    }
  }

  async function saveAccess(event) {
    event.preventDefault();
    if (savingAccess || !can("manage_access")) return;
    if (!editor.checkValidity()) { editor.reportValidity(); return; }
    if(tvOnly.checked && !tvParts.checked && !tvOriginal.checked && !tvCopy.checked){setMessage(message,"Choose at least one TV display option.");return;}
    const selected = collectSelection(roleOptions);
    if (tvOnly.checked) {
      selected.capabilities = Object.fromEntries(pageGuideData.map(page => [page.key, []]));
      selected.capabilities.damage_report = ["view", ...(tvParts.checked ? ["parts_details"] : []), ...(tvOriginal.checked ? ["original_prices"] : []), ...(tvCopy.checked ? ["copy_prices"] : []), ...(tvOriginal.checked || tvCopy.checked ? ["payable"] : [])];
      selected.pagePermissions = {...Object.fromEntries(specialPages.map(key => [key, "none"])), damage_report:"view"};
      selected.partnerNamesAccess = "none";
    }
    const partnerNamesAccess = selected.partnerNamesAccess;
    if (!selectedUserId) return;
    const targetUserId = selectedUserId;

    const button = document.querySelector("#save-access");
    savingAccess = true;
    button.disabled = true;
    button.textContent = "Saving...";
    let pagesSaved = false;
    try {
    const { data: saved, error } = await getClient().rpc("save_user_access_capabilities_v1", {
      p_user_id: targetUserId,
      p_full_name: fullName.value.trim(),
      p_login_username: username.value.trim(),
      p_is_active: active.checked,
      p_page_permissions: selected.pagePermissions,
      p_capabilities: selected.capabilities,
      p_partner_names_access: partnerNamesAccess,
      p_tv_only: tvOnly.checked,p_show_parts:tvParts.checked,p_show_original:tvOriginal.checked,p_show_copy:tvCopy.checked,
      p_expected_revision:users.find(user=>String(user.user_id)===String(targetUserId)).tv_display.revision
    });

    if (error) throw error;
    if (saved !== true) throw new Error("The database did not confirm the permission update. Refresh and try again.");
    pagesSaved = true;

    const savedUser = users.find((user) => String(user.user_id) === String(targetUserId));
    if (savedUser) {
      savedUser.partner_names_access = partnerNamesAccess;
      savedUser.partner_names_allowed = partnerNamesAccess !== "none";
    }
    await loadUsers(targetUserId);
    setMessage(message, "User access was saved.", "success");
    } catch (error) {
      setMessage(message, `${pagesSaved ? "Access was saved, but the list could not be refreshed. " : ""}${error.message || "User access could not be saved."}`);
    } finally {
      savingAccess = false;
      button.disabled = !can("manage_access");
      button.textContent = "Save access";
    }
  }

  async function initialize() {
    await window.GREENLOOP_ACCESS_READY;
    if (window.GREENLOOP_PAGE_ACCESS?.pageKey !== "user_access") return;
    if (!catalog?.pages?.length || typeof window.GREENLOOP_CAN !== "function") throw new Error("The permission controls could not load. Refresh and try again.");
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) {
      throw new Error("Supabase authentication is not configured.");
    }

    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) {
      window.location.replace("index.html");
      return;
    }

    const { data: allowed, error } = await getClient().rpc("has_role", {
      required_roles: ["super_admin", "owner"]
    });
    if (error) throw error;
    if (!allowed) {
      permissionMessage.textContent = "Only Super Admin and Owner can manage user access.";
      permissionMessage.hidden = false;
      return;
    }

    const { data: isSuperAdmin, error: superAdminError } = await getClient().rpc("has_role", {
      required_roles: ["super_admin"]
    });
    if (superAdminError) throw superAdminError;
    currentUserIsSuperAdmin = Boolean(isSuperAdmin);

    app.hidden = false;
    applySectionPermissions();
    showAccessSection();
    renderNewUserPages();
    await loadUsers();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  app.querySelectorAll("[data-access-section]").forEach((button) => {
    button.addEventListener("click", () => {
      if (!sectionAllowed(button.dataset.accessSection)) return;
      if (location.hash.slice(1) === button.dataset.accessSection) showAccessSection(true);
      else location.hash = button.dataset.accessSection;
    });
  });
  document.querySelector("#user-access-home").addEventListener("click", () => {
    history.pushState(null, "", location.pathname + location.search);
    showAccessSection();
    app.querySelector("[data-access-section]:not([hidden])")?.focus({preventScroll: true});
  });
  window.addEventListener("hashchange", () => showAccessSection(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-users").addEventListener("click", () => {
    if (savingAccess || creatingUser) return;
    loadUsers().catch((error) => setMessage(message, error.message || "Users could not be loaded."));
  });
  userList.addEventListener("click", (event) => {
    if (savingAccess) return;
    const item = event.target.closest("[data-user-id]");
    if (!item) return;
    selectedUserId = item.dataset.userId;
    renderUsers();
    renderEditor();
  });
  newUsername.addEventListener("blur", () => {
    newUsername.value = newUsername.value.trim().toLowerCase().replace(/\s+/g, "");
  });
  newRoleOptions.addEventListener("change", (event) => {
    const checkbox = event.target.closest('input[type="checkbox"]');
    if (checkbox) { if (!can("create_users")) { renderNewUserPages(); return; } syncPermissionCard(checkbox); }
  });
  roleOptions.addEventListener("change", (event) => {
    const checkbox = event.target.closest('input[type="checkbox"]');
    if (checkbox) { if (!can("manage_access")) { renderEditor(); return; } syncPermissionCard(checkbox); }
  });
  createUserForm.addEventListener("submit", (event) => {
    createUser(event).catch((error) => setMessage(createUserMessage, error.message || "The user account could not be created."));
  });
  editor.addEventListener("submit", (event) => {
    saveAccess(event).catch((error) => setMessage(message, error.message || "User access could not be saved."));
  });

  initialize().catch((error) => {
    permissionMessage.textContent = error.message || "User Access could not be loaded.";
    permissionMessage.hidden = false;
  });
})();
