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

  const roleGuideData = [
    ["super_admin", "Super Admin", "All pages, settings, reports, deleted history, and user access."],
    ["owner", "Owner", "Business-wide viewing, reports, cost, and user access."],
    ["manager", "Manager", "All operational pages, reports, approvals, and deleted history."],
    ["receiving", "Receiving", "Stock Received, IMEI Entry, and receiving history."],
    ["initial_qc", "Initial QC", "Initial QC queue, diagnosis, technician assignment, and parts request."],
    ["parts", "Parts", "Parts requests, issue sheet, and parts inventory."],
    ["technician", "Technician", "Laboratory work, issued parts, and assigned repairs."],
    ["final_qc", "Final QC", "Final QC inspection, final grade, pass, fail, and rework return."],
    ["production", "Production", "Ready Stock, Production, and export box preparation."],
    ["shipping", "Shipping", "Export Boxes, packing lists, and shipment handling."],
    ["rma", "RMA", "RMA Stock Received and RMA workflow."],
    ["shop_staff", "Retail Shop", "Retail Shop stock and shop-related device records."],
    ["glass", "Glass", "Glass department work and device history."],
    ["frame", "Frame", "Frame department work and device history."],
    ["packing", "Packing", "Packing and outbound preparation."]
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

  function roleName(roleKey) {
    return roleGuideData.find(([key]) => key === roleKey)?.[1] || String(roleKey).replaceAll("_", " ");
  }

  function roleCheckboxes(roles = roleGuideData, selectedRoles = new Set()) {
    return roles.map(([key, name, scope]) => `
      <label class="role-option">
        <input type="checkbox" value="${escapeHtml(key)}"${selectedRoles.has(key) ? " checked" : ""}>
        <strong>${escapeHtml(name)}</strong>
        <small>${escapeHtml(scope)}</small>
      </label>
    `).join("");
  }

  function renderRoleGuide() {
    roleGuide.innerHTML = roleGuideData.map(([, name, scope]) => `
      <article class="role-guide-item">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(scope)}</span>
      </article>
    `).join("");
  }

  function renderNewUserRoles() {
    const availableRoles = currentUserIsSuperAdmin
      ? roleGuideData
      : roleGuideData.filter(([key]) => key !== "super_admin" && key !== "owner");
    newRoleOptions.innerHTML = roleCheckboxes(availableRoles);
  }

  function renderUsers() {
    userList.innerHTML = users.length ? users.map((user) => {
      const roles = user.role_keys || [];
      return `
        <button class="user-list-item${user.user_id === selectedUserId ? " active" : ""}${user.is_active ? "" : " inactive"}" type="button" data-user-id="${escapeHtml(user.user_id)}">
          <strong>${escapeHtml(user.full_name || user.login_username || "Unnamed user")}</strong>
          <small>@${escapeHtml(user.login_username || "No username")}</small>
          <span class="user-role-summary">${escapeHtml(roles.length ? roles.map(roleName).join(", ") : "No role assigned")}</span>
        </button>
      `;
    }).join("") : '<p class="access-empty">No user profiles were found.</p>';
  }

  function renderEditor() {
    const user = users.find((item) => item.user_id === selectedUserId);
    editor.hidden = !user;
    selectUserMessage.hidden = Boolean(user);
    setMessage(message);
    if (!user) return;

    fullName.value = user.full_name || "";
    username.value = user.login_username || "";
    active.checked = Boolean(user.is_active);
    roleOptions.innerHTML = roleCheckboxes(roleGuideData, new Set(user.role_keys || []));
  }

  async function loadUsers(preferredUserId = selectedUserId) {
    const { data, error } = await getClient().rpc("get_user_access_matrix");
    if (error) throw error;
    users = data || [];
    selectedUserId = users.some((user) => user.user_id === preferredUserId)
      ? preferredUserId
      : (users[0]?.user_id || "");
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

    const selectedRoles = [...newRoleOptions.querySelectorAll("input:checked")].map((input) => input.value);
    if (!selectedRoles.length) {
      setMessage(createUserMessage, "Select at least one role for this user.");
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
          role_keys: selectedRoles
        }
      });

      if (error) throw new Error(await readFunctionError(error));
      if (!data?.success || !data?.user_id) throw new Error(data?.error || "The user account could not be created.");

      createUserForm.reset();
      renderNewUserRoles();
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
    const selectedRoles = [...roleOptions.querySelectorAll("input:checked")].map((input) => input.value);
    if (!selectedUserId) return;

    const button = document.querySelector("#save-access");
    button.disabled = true;
    button.textContent = "Saving...";

    const { error } = await getClient().rpc("save_user_access", {
      p_user_id: selectedUserId,
      p_full_name: fullName.value.trim(),
      p_login_username: username.value.trim(),
      p_is_active: active.checked,
      p_role_keys: selectedRoles
    });

    button.disabled = false;
    button.textContent = "Save access";
    if (error) {
      setMessage(message, error.message || "User access could not be saved.");
      return;
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
    renderRoleGuide();
    renderNewUserRoles();
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
