import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getSecretKey() {
  const direct =
    Deno.env.get("SUPABASE_SECRET_KEY") ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (direct) return direct;

  const namedSecrets = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!namedSecrets) return "";

  try {
    const parsed = JSON.parse(namedSecrets);
    return Object.values(parsed).find((value) => typeof value === "string") as string || "";
  } catch {
    return "";
  }
}

function cleanUsername(value: unknown) {
  return String(value || "").trim().toLowerCase().replace(/\s+/g, "");
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof Error && error.message) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message?: unknown }).message || "").trim();
    if (message) return message;
  }
  return fallback;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Read-only installation receipt; no credentials or account data returned.
  if (request.method === "GET") {
    return jsonResponse({ version: "20261016-page-capabilities-1" });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Only POST requests are accepted." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const secretKey = getSecretKey();
  const authorization = request.headers.get("Authorization") || "";
  const accessToken = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";

  if (!supabaseUrl || !secretKey) {
    return jsonResponse({ error: "The secure user service is not configured." }, 500);
  }

  if (!accessToken) {
    return jsonResponse({ error: "Sign in again before creating a user." }, 401);
  }

  const admin = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Run permission checks with the signed-in user's JWT. The secret client is
  // kept separately for the actual account creation and role assignment.
  const callerClient = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: callerData, error: callerError } = await admin.auth.getUser(accessToken);
  const caller = callerData?.user;

  if (callerError || !caller) {
    return jsonResponse({ error: "Your session is not valid. Sign in again." }, 401);
  }

  const { data: canCreateUsers, error: accessError } = await callerClient.rpc("has_role", {
    required_roles: ["super_admin", "owner"],
  });

  if (accessError) {
    return jsonResponse({
      error: `Administrator access check failed: ${accessError.message}`,
    }, 500);
  }

  if (canCreateUsers !== true) {
    return jsonResponse({ error: "Only Super Admin and Owner can create users." }, 403);
  }

  // Creating accounts is distinct from editing existing users' permissions.
  // Check the signed-in caller before any privileged Auth mutation.
  const { data: canEditUsers, error: editAccessError } = await callerClient.rpc("has_page_capability_v1", {
    p_page_key: "user_access",
    p_capability: "create_users",
  });
  if (editAccessError) {
    return jsonResponse({ error: "User Access permission could not be verified. Try again." }, 503);
  }
  if (canEditUsers !== true) {
    return jsonResponse({ error: "Add Greenloop User permission is required." }, 403);
  }

  const { data: isSuperAdmin, error: superAdminError } = await callerClient.rpc("has_role", {
    required_roles: ["super_admin"],
  });

  if (superAdminError) {
    return jsonResponse({
      error: `Super Admin access check failed: ${superAdminError.message}`,
    }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "The user details are not valid." }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return jsonResponse({ error: "The user details are not valid." }, 400);
  }

  const fullName = String(body.full_name || "").trim().replace(/\s+/g, " ");
  const username = cleanUsername(body.username);
  const password = String(body.password || "");
  const capabilities = body.capabilities;
  const pagePermissions = body.page_permissions;
  const partnerNamesAccess = String(body.partner_names_access || "none");
  if (!capabilities || typeof capabilities !== "object" || Array.isArray(capabilities)
      || !pagePermissions || typeof pagePermissions !== "object" || Array.isArray(pagePermissions)
      || !["none", "view", "edit"].includes(partnerNamesAccess)) {
    return jsonResponse({ error: "Refresh User Access and select the account's page permissions." }, 400);
  }
  const entries = Object.entries(capabilities as Record<string, unknown>);
  if (!entries.length || entries.length > 100 || entries.some(([key, value]) =>
      !/^[a-z][a-z_]{0,60}$/.test(key) || !Array.isArray(value) || value.length > 30
      || value.some(capability => typeof capability !== "string" || !/^[a-z][a-z_]{0,60}$/.test(capability))
      || value.length > 0 && !value.includes("view"))) {
    return jsonResponse({ error: "Select View before selecting a page's other permissions." }, 400);
  }
  const requestedPages = entries.filter(([, value]) => (value as string[]).includes("view")).map(([key]) => key);

  if (fullName.length < 2 || fullName.length > 100) {
    return jsonResponse({ error: "Full name must use 2 to 100 characters." }, 400);
  }

  if (!/^[a-z0-9._-]{3,40}$/.test(username)) {
    return jsonResponse({ error: "Username must use 3 to 40 letters, numbers, dots, underscores, or hyphens." }, 400);
  }

  if (password.length < 8 || password.length > 72) {
    return jsonResponse({ error: "Password must use 8 to 72 characters." }, 400);
  }

  if (!requestedPages.length) {
    return jsonResponse({ error: "Select at least one page for this user." }, 400);
  }

  if (isSuperAdmin !== true && requestedPages.includes("user_access")) {
    return jsonResponse({ error: "Only Super Admin can grant User Access permission." }, 403);
  }

  // Supabase Auth requires a unique identity. Staff never see or enter this address.
  // Gmail plus-addressing keeps all recovery mail in the system administrator inbox.
  const internalEmail = `zeee.afridi+greenloop.${username}@gmail.com`;
  let createdUserId = "";

  try {
    const { data: createdData, error: createError } = await admin.auth.admin.createUser({
      email: internalEmail,
      password,
      email_confirm: true,
      user_metadata: {
        full_name: fullName,
        login_username: username,
        greenloop_managed: true,
      },
    });

    if (createError || !createdData.user) {
      const duplicate = /already|registered|exists/i.test(createError?.message || "");
      return jsonResponse({
        error: duplicate
          ? "This username already has a login account."
          : (createError?.message || "The login account could not be created."),
      }, duplicate ? 409 : 400);
    }

    createdUserId = createdData.user.id;

    // This service-only initializer validates the original caller's create_users
    // capability again and sets all initial permissions in one transaction.
    // It cannot be used to edit an existing account. No browser follow-up save
    // is needed, so a create-only administrator never needs manage_access.
    const { data: accessSaved, error: saveAccessError } = await admin.rpc("initialize_user_capabilities_v1", {
      p_actor_user_id: caller.id,
      p_user_id: createdUserId,
      p_full_name: fullName,
      p_login_username: username,
      p_page_permissions: pagePermissions,
      p_capabilities: capabilities,
      p_partner_names_access: partnerNamesAccess,
    });

    if (saveAccessError || accessSaved !== true) {
      throw new Error(`User permissions could not be saved: ${saveAccessError?.message || "The database did not confirm the permission setup."}`);
    }

    return jsonResponse({
      success: true,
      user_id: createdUserId,
      full_name: fullName,
      username,
      page_keys: requestedPages,
    }, 201);
  } catch (error) {
    if (createdUserId) {
      try {
        const { error: cleanupError } = await admin.auth.admin.deleteUser(createdUserId);
        if (cleanupError) throw cleanupError;
      } catch {
        return jsonResponse({ error: "Account setup did not finish and cleanup could not be confirmed. Ask your administrator to review this username before trying again." }, 500);
      }
    }

    return jsonResponse({
      error: errorMessage(error, "The user account could not be created."),
    }, 400);
  }
});
