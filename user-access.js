(() => {
  "use strict";

  const config = window.GREENLOOP_CONFIG || {};
  const app = document.querySelector("#user-access-app");
  const permissionMessage = document.querySelector("#permission-message");
  const userList = document.querySelector("#user-list");
  const editor = document.querySelector("#access-editor");
  const selectUserMessage = document.querySelector("#select-user-message");
  const fullName = document.querySelector("#access-full-name");
  const username = document.querySelector("#access-username");
  const email = document.querySelector("#access-email");
  const active = document.querySelector("#access-active");
  const roleOptions = document.querySelector("#role-options");
  const roleGuide = document.querySelector("#role-guide");
  const message = document.querySelector("#access-message");
  const sidebar = document.querySelector("#sidebar");
  const backdrop = document.querySelector("#menu-backdrop");
  let client;
  let users = [];
  let selectedUserId = "";

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

  function getClient() { return (client ||= window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)); }
  function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
  function setMessage(text = "", type = "error") { message.textContent = text; message.classList.toggle("is-visible", Boolean(text)); message.classList.toggle("is-success", type === "success"); }
  function setMenu(open) { sidebar.classList.toggle("is-open", open); backdrop.hidden = !open; document.body.classList.toggle("menu-open", open); }
  function roleName(roleKey) { return roleGuideData.find(([key]) => key === roleKey)?.[1] || String(roleKey).replaceAll("_", " "); }

  function renderRoleGuide() {
    roleGuide.innerHTML = roleGuideData.map(([, name, scope]) => `<article class="role-guide-item"><strong>${escapeHtml(name)}</strong><span>${escapeHtml(scope)}</span></article>`).join("");
  }

  function renderUsers() {
    userList.innerHTML = users.length ? users.map((user) => {
      const roles = user.role_keys || [];
      return `<button class="user-list-item${user.user_id === selectedUserId ? " active" : ""}${user.is_active ? "" : " inactive"}" type="button" data-user-id="${escapeHtml(user.user_id)}"><strong>${escapeHtml(user.full_name || user.login_username || "Unnamed user")}</strong><small>${escapeHtml(user.login_username || "No username")} · ${escapeHtml(user.email || "No email")}</small><span class="user-role-summary">${escapeHtml(roles.length ? roles.map(roleName).join(", ") : "No role assigned")}</span></button>`;
    }).join("") : '<p class="access-empty">No user profiles were found.</p>';
  }

  function renderEditor() {
    const user = users.find((item) => item.user_id === selectedUserId);
    editor.hidden = !user;
    selectUserMessage.hidden = Boolean(user);
    setMessage();
    if (!user) return;
    fullName.value = user.full_name || "";
    username.value = user.login_username || "";
    email.textContent = user.email || "No email linked";
    active.checked = Boolean(user.is_active);
    const selectedRoles = new Set(user.role_keys || []);
    roleOptions.innerHTML = roleGuideData.map(([key, name, scope]) => `<label class="role-option"><input type="checkbox" value="${escapeHtml(key)}"${selectedRoles.has(key) ? " checked" : ""}><strong>${escapeHtml(name)}</strong><small>${escapeHtml(scope)}</small></label>`).join("");
  }

  async function loadUsers(preferredUserId = selectedUserId) {
    const { data, error } = await getClient().rpc("get_user_access_matrix");
    if (error) throw error;
    users = data || [];
    selectedUserId = users.some((user) => user.user_id === preferredUserId) ? preferredUserId : (users[0]?.user_id || "");
    renderUsers();
    renderEditor();
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
    if (error) { setMessage(error.message || "User access could not be saved."); return; }
    await loadUsers(selectedUserId);
    setMessage("User access was saved.", "success");
  }

  async function initialize() {
    if (!config.supabaseUrl || !config.supabaseAnonKey || !window.supabase) throw new Error("Supabase authentication is not configured.");
    const { data: sessionData } = await getClient().auth.getSession();
    if (!sessionData.session) { window.location.replace("index.html"); return; }
    const { data: allowed, error } = await getClient().rpc("has_role", { required_roles: ["super_admin", "owner"] });
    if (error) throw error;
    if (!allowed) { permissionMessage.textContent = "Only Super Admin and Owner can manage user access."; permissionMessage.hidden = false; return; }
    app.hidden = false;
    renderRoleGuide();
    await loadUsers();
  }

  document.querySelector("#open-menu").addEventListener("click", () => setMenu(true));
  document.querySelector("#close-menu").addEventListener("click", () => setMenu(false));
  backdrop.addEventListener("click", () => setMenu(false));
  document.querySelector("#refresh-users").addEventListener("click", () => loadUsers().catch((error) => setMessage(error.message || "Users could not be loaded.")));
  userList.addEventListener("click", (event) => { const item = event.target.closest("[data-user-id]"); if (!item) return; selectedUserId = item.dataset.userId; renderUsers(); renderEditor(); });
  editor.addEventListener("submit", (event) => saveAccess(event).catch((error) => setMessage(error.message || "User access could not be saved.")));
  initialize().catch((error) => { permissionMessage.textContent = error.message || "User Access could not be loaded."; permissionMessage.hidden = false; });
})();
