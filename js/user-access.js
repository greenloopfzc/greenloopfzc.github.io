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
  const roleGuide = document.querySelector("#role-guide");
  const message = document.querySelector("#access-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  let client;
  let users = [];
  let selectedUserId = "";
  let currentUserIsSuperAdmin = false;

  const pageGuideData = [
    ["overview", "Overview", "Dashboard and live operational summary."],
    ["stock_received", "Stock Received", "Create and view received stock batches."],
    ["imei_entry", "IMEI Entry", "Enter IMEIs and the first device details."],
    ["initial_qc", "Initial QC", "Inspect, grade, identify work, and assign technicians."],
    ["lab_glass", "Lab & Glass", "Laboratory and glass repair work."],
    ["lab_live_board", "Lab Live Board", "TV display of live technician workload and performance."],
    ["parts", "Parts", "View requests and issue required parts."],
    ["inventory", "Inventory", "Receive and control parts inventory."],
    ["final_qc", "Final QC", "Final inspection, grade, Battery Health, Pass or Fail."],
    ["ready_stock", "Ready Stock", "View all Final QC passed stock."],
    ["export_boxes", "Export Boxes", "Create boxes and scan phones for export."],
    ["ready_stock_journey", "Ready Stock Journey", "View complete IMEI workflow history."],
    ["reports", "Reports", "View operational and management reports."],
    ["user_access", "User Access", "Create users and control their page permissions."],
    ["partner_names", "Supplier & Customer Names", "Show confidential supplier and customer names. Codes remain visible to everyone with page access."]
  ];

  function getClient() {
    return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey));
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
    return pageGuideData.find(([key]) => key === pageKey)?.[1] || String(pageKey).replaceAll("_", " ");
  }

  function pageCheckboxes(pages = pageGuideData, selectedPermissions = {}) {
    return pages.map(([key, name, scope]) => {
      const accessLevel = selectedPermissions[key] || "edit";
      const checked = Object.hasOwn(selectedPermissions, key);
      return `
        <article class="role-option${checked ? " is-selected" : ""}" data-page-permission="${escapeHtml(key)}">
          <label class="permission-check"><input type="checkbox" value="${escapeHtml(key)}"${checked ? " checked" : ""}><strong>${escapeHtml(name)}</strong></label>
          <select data-access-level aria-label="${escapeHtml(name)} access level"${checked ? "" : " disabled"}>
            <option value="view"${accessLevel === "view" ? " selected" : ""}>Only View</option>
            <option value="edit"${accessLevel !== "view" ? " selected" : ""}>Entry Allowed</option>
          </select>
          <small>${escapeHtml(scope)}</small>
        </article>
      `;
    }).join("");
  }

  function permissionsForUser(user) {
    if (user?.page_permissions && typeof user.page_permissions === "object" && !Array.isArray(user.page_permissions)) return user.page_permissions;
    return Object.fromEntries((user?.page_keys || []).map((key) => [key, "edit"]));
  }

  function databaseBoolean(value) {
    let candidate = value;
    if (Array.isArray(candidate)) candidate = candidate[0];
    if (candidate && typeof candidate === "object") {
      candidate = candidate.can_view ?? candidate.allowed ?? Object.values(candidate)[0];
    }
    return candidate === true || String(candidate ?? "").trim().toLowerCase() === "true";
  }

  function displayPermissionsForUser(user) {
    const permissions = { ...permissionsForUser(user) };
    if (["view", "edit"].includes(user?.partner_names_access)) permissions.partner_names = user.partner_names_access;
    else delete permissions.partner_names;
    return permissions;
  }

  function collectPagePermissions(container) {
    const result = {};
    container.querySelectorAll("[data-page-permission]").forEach((card) => {
      const checkbox = card.querySelector('input[type="checkbox"]');
      if (checkbox.checked) result[checkbox.value] = card.querySelector("[data-access-level]").value || "view";
    });
    return result;
  }

  function syncPermissionCard(checkbox) {
    const card = checkbox.closest("[data-page-permission]");
    card.classList.toggle("is-selected", checkbox.checked);
    card.querySelector("[data-access-level]").disabled = !checkbox.checked;
  }

  function renderPageGuide() {
    roleGuide.innerHTML = pageGuideData.map(([, name, scope]) => `
      <article class="role-guide-item">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(scope)}</span>
      </article>
    `).join("");
  }

  function renderNewUserPages() {
    const availablePages = currentUserIsSuperAdmin
      ? pageGuideData
      : pageGuideData.filter(([key]) => key !== "user_access");
    newRoleOptions.innerHTML = pageCheckboxes(availablePages);
  }

  function renderUsers() {
    userList.innerHTML = users.length ? users.map((user) => {
      const permissions = displayPermissionsForUser(user);
      const pages = Object.keys(permissions);
      return `
        <button class="user-list-item${String(user.user_id) === String(selectedUserId) ? " active" : ""}${user.is_active ? "" : " inactive"}" type="button" data-user-id="${escapeHtml(user.user_id)}">
          <strong>${escapeHtml(user.full_name || user.login_username || "Unnamed user")}</strong>
          <small>@${escapeHtml(user.login_username || "No username")}</small>
          <span class="user-role-summary">${escapeHtml(pages.length ? pages.map((key) => `${pageName(key)} (${permissions[key] === "view" ? "View" : "Entry"})`).join(", ") : "No page assigned")}</span>
        </button>
      `;
    }).join("") : '<p class="access-empty">No user profiles were found.</p>';
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
    roleOptions.innerHTML = pageCheckboxes(pageGuideData, displayPermissionsForUser(user));
  }

  async function loadUsers(preferredUserId = selectedUserId) {
    let { data, error } = await getClient().rpc("get_user_page_access_matrix_v2");
    if (error && (error.code === "PGRST202" || String(error.message || "").includes("get_user_page_access_matrix_v2"))) {
      ({ data, error } = await getClient().rpc("get_user_page_access_matrix"));
    }
    if (error) throw error;
    users = data || [];
    const { data: partnerAccess, error: partnerError } = await getClient().rpc("get_user_partner_name_access_matrix");
    if (partnerError) throw partnerError;
    const accessByUser = new Map((partnerAccess || []).map((row) => {
      const savedLevel = String(row.access_level || "").trim().toLowerCase();
      const accessLevel = ["view", "edit"].includes(savedLevel)
        ? savedLevel
        : (databaseBoolean(row.can_view) ? "view" : "none");
      return [String(row.user_id), accessLevel];
    }));
    users.forEach((user) => {
      user.partner_names_access = accessByUser.get(String(user.user_id)) || "none";
      user.partner_names_allowed = user.partner_names_access !== "none";
    });
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
    setMessage(createUserMessage);

    if (!createUserForm.checkValidity()) {
      createUserForm.reportValidity();
      return;
    }

    if (newPassword.value !== newConfirmPassword.value) {
      setMessage(createUserMessage, "Passwords do not match.");
      newConfirmPassword.focus();
      return;
    }

    const selectedPermissions = collectPagePermissions(newRoleOptions);
    const partnerNamesAccess = selectedPermissions.partner_names || "none";
    const normalPermissions = Object.fromEntries(Object.entries(selectedPermissions).filter(([key]) => key !== "partner_names"));
    const selectedPages = Object.keys(normalPermissions);
    if (!selectedPages.length) {
      setMessage(createUserMessage, "Select at least one page for this user.");
      return;
    }

    createUserButton.disabled = true;
    createUserButton.textContent = "Creating...";

    try {
      const { data, error } = await getClient().functions.invoke("admin-create-user", {
        body: {
          full_name: newFullName.value.trim(),
          username: newUsername.value.trim(),
          password: newPassword.value,
          page_keys: selectedPages
        }
      });

      if (error) throw new Error(await readFunctionError(error));
      if (!data?.success || !data?.user_id) throw new Error(data?.error || "The user account could not be created.");

      const { error: accessError } = await getClient().rpc("save_user_page_access_v2", {
        p_user_id: data.user_id,
        p_full_name: newFullName.value.trim(),
        p_login_username: data.username,
        p_is_active: true,
        p_page_permissions: normalPermissions
      });
      if (accessError) throw accessError;
      const { error: partnerError } = await getClient().rpc("save_user_partner_name_access", { p_user_id: data.user_id, p_access_level: partnerNamesAccess });
      if (partnerError) throw partnerError;

      createUserForm.reset();
      renderNewUserPages();
      await loadUsers(data.user_id);
      setMessage(createUserMessage, `User @${data.username} was created and can sign in now.`, "success");
    } catch (error) {
      setMessage(createUserMessage, error.message || "The user account could not be created.");
    } finally {
      createUserButton.disabled = false;
      createUserButton.textContent = "Create user";
    }
  }

  async function saveAccess(event) {
    event.preventDefault();
    const selectedPermissions = collectPagePermissions(roleOptions);
    const partnerNamesAccess = selectedPermissions.partner_names || "none";
    const normalPermissions = Object.fromEntries(Object.entries(selectedPermissions).filter(([key]) => key !== "partner_names"));
    if (!selectedUserId) return;

    const button = document.querySelector("#save-access");
    button.disabled = true;
    button.textContent = "Saving...";

    let { error } = await getClient().rpc("save_user_page_access_v2", {
      p_user_id: selectedUserId,
      p_full_name: fullName.value.trim(),
      p_login_username: username.value.trim(),
      p_is_active: active.checked,
      p_page_permissions: normalPermissions
    });

    button.disabled = false;
    button.textContent = "Save access";
    if (error) {
      setMessage(message, error.message || "User access could not be saved.");
      return;
    }
    const { error: partnerError } = await getClient().rpc("save_user_partner_name_access", { p_user_id: selectedUserId, p_access_level: partnerNamesAccess });
    if (partnerError) {
      setMessage(message, partnerError.message || "Supplier and customer name access could not be saved.");
      return;
    }

    const savedUser = users.find((user) => String(user.user_id) === String(selectedUserId));
    if (savedUser) {
      savedUser.partner_names_access = partnerNamesAccess;
      savedUser.partner_names_allowed = partnerNamesAccess !== "none";
    }
    await loadUsers(selectedUserId);
    setMessage(message, "User access was saved.", "success");
  }

  async function initialize() {
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
    renderPageGuide();
    renderNewUserPages();
    await loadUsers();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-users").addEventListener("click", () => {
    loadUsers().catch((error) => setMessage(message, error.message || "Users could not be loaded."));
  });
  userList.addEventListener("click", (event) => {
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
    if (checkbox) syncPermissionCard(checkbox);
  });
  roleOptions.addEventListener("change", (event) => {
    const checkbox = event.target.closest('input[type="checkbox"]');
    if (checkbox) syncPermissionCard(checkbox);
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
