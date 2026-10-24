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
    return jsonResponse({ version: "20261024-office-access-1" });
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

  const { data: callerData, error: callerError } = await admin.auth.getUser(accessToken);
  const caller = callerData?.user;

  if (callerError || !caller) {
    return jsonResponse({ error: "Your session is not valid. Sign in again." }, 401);
  }

  // The original client IP comes only from Supabase's Cloudflare edge header.
  // Never take it from body.network/IP, XFF or caller-editable user metadata.
  const clientIp = request.headers.get("cf-connecting-ip") || "";
  const {data: context, error: contextError} = await admin.rpc("get_office_create_context_v1", {p_actor:caller.id,p_client_ip:clientIp});
  if(contextError || !context || typeof context.allowed !== "boolean" || typeof context.can_create !== "boolean" || typeof context.is_super_admin !== "boolean") return jsonResponse({error:"Office access could not be verified. Try again."},503);
  if(!context.allowed) return jsonResponse({error:"Office access only. Please connect to the office network."},403);
  if(!context.can_create) return jsonResponse({error:"Add Greenloop User permission and an administrator role are required."},403);
  const isSuperAdmin = context.is_super_admin === true;

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "The user details are not valid." }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return jsonResponse({ error: "The user details are not valid." }, 400);
  }

  const networkMode = body.network_mode === undefined ? "anywhere" : body.network_mode;
  if(networkMode !== "anywhere" && networkMode !== "office") return jsonResponse({error:"Choose Office Only or Anywhere."},400);
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
      !/^[a-z][a-z_]{0,60}$/.test(key) || !Array.isArray(value) || value.length > (key === "daily_production" ? 512 : 30)
      || value.some(capability => typeof capability !== "string" || !/^[a-z][a-z_]{0,60}$/.test(capability))
      || value.length > 0 && !value.includes("view"))) {
    return jsonResponse({ error: "Select View before selecting a page's other permissions." }, 400);
  }
  // Appearance contains personal display choices, not a software page grant.
  const appearance = (capabilities as Record<string, unknown>).appearance;
  if (appearance !== undefined && (!Array.isArray(appearance)
      || appearance.some(key => !["view", "theme", "display_mode"].includes(key)))
      || Object.prototype.hasOwnProperty.call(pagePermissions, "appearance")) {
    return jsonResponse({ error: "Refresh User Access and select the account's appearance options again." }, 400);
  }
  const requestedPages = entries.filter(([key, value]) => key !== "appearance" && (value as string[]).includes("view")).map(([key]) => key);

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
    const { data: accessSaved, error: saveAccessError } = await admin.rpc("initialize_user_office_access_v1", {
      p_actor_user_id: caller.id,
      p_network_mode:networkMode,p_client_ip:clientIp,
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
      network_mode:networkMode,
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
