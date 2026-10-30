import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
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


const PASSWORD_VERSION = "20261030-user-password-1";
const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function validPassword(value: unknown): value is string {
  return typeof value === "string" && value.length >= 6 && value.length <= 20;
}
function rpcFailure(error: { code?: string } | null | undefined) {
  const code = error?.code;
  if (code === "42501") return jsonResponse({error:"Administrator role, Edit users & permissions access and an approved connection are required."},403);
  if (code === "40001") return jsonResponse({error:"This account changed. Refresh the users list before changing its password."},409);
  if (code === "53300") return jsonResponse({error:"Too many password changes. Try again later."},429);
  if (code === "55000") return jsonResponse({error:"A password change is already pending for this account. Check its status before trying again."},409);
  if (code === "22023") return jsonResponse({error:"The account or password request could not be verified. Refresh the users list."},400);
  return jsonResponse({error:"Password access could not be verified. Try again."},503);
}
function vaultBytes() {
  try {const raw=Deno.env.get("GREENLOOP_PASSWORD_VAULT_KEY")||"",bytes=Uint8Array.from(atob(raw),c=>c.charCodeAt(0));return bytes.length===32?bytes:null;}catch{return null;}
}
function base64(bytes: Uint8Array){let value="";for(const b of bytes)value+=String.fromCharCode(b);return btoa(value);}
async function vaultKey(){const bytes=vaultBytes();if(!bytes)throw new Error("Password viewing is not configured.");const digest=await crypto.subtle.digest("SHA-256",bytes);return{key:await crypto.subtle.importKey("raw",bytes,"AES-GCM",false,["encrypt","decrypt"]),id:Array.from(new Uint8Array(digest).slice(0,8),b=>b.toString(16).padStart(2,"0")).join("")};}
const vaultAad=(target:string,requestId:string)=>new TextEncoder().encode("greenloop-password-v1|"+target+"|"+requestId);
async function encryptPassword(password:string,target:string,requestId:string){const key=await vaultKey(),nonce=crypto.getRandomValues(new Uint8Array(12)),cipher=await crypto.subtle.encrypt({name:"AES-GCM",iv:nonce,additionalData:vaultAad(target,requestId)},key.key,new TextEncoder().encode(password));return{ciphertext:base64(new Uint8Array(cipher)),nonce:base64(nonce),key_id:key.id};}
async function passwordVisibility(admin:ReturnType<typeof createClient>,callerId:string,clientIp:string,body:Record<string,unknown>){
  const reveal=body.action==="reveal_password";
  if(Object.keys(body).some(k=>!["action","user_id","request_id"].includes(k))||typeof body.user_id!=="string"||!uuidPattern.test(body.user_id)||reveal&&(typeof body.request_id!=="string"||!uuidPattern.test(body.request_id)))return jsonResponse({error:"Select a valid user."},400);
  const target=body.user_id.toLowerCase(),requestId=reveal?String(body.request_id).toLowerCase():null;
  const{data,error}=await admin.rpc("get_admin_password_visibility_v1",{p_actor:callerId,p_target:target,p_client_ip:clientIp,p_reveal:reveal,p_request_id:requestId});
  if(error)return rpcFailure(error);
  if(!data||data.user_id!==target||typeof data.available!=="boolean")return jsonResponse({error:"Password visibility could not be verified."},503);
  if(!data.available)return jsonResponse({version:PASSWORD_VERSION,user_id:target,available:false,reason:data.reason});
  const key=await vaultKey();if(data.key_id!==key.id)return jsonResponse({version:PASSWORD_VERSION,user_id:target,available:false,reason:"key_unavailable"});
  if(!reveal)return jsonResponse({version:PASSWORD_VERSION,user_id:target,available:true,recorded_at:data.recorded_at});
  try{
    const plain=await crypto.subtle.decrypt({name:"AES-GCM",iv:Uint8Array.from(atob(data.nonce),c=>c.charCodeAt(0)),additionalData:vaultAad(target,data.vault_request_id)},key.key,Uint8Array.from(atob(data.ciphertext),c=>c.charCodeAt(0)));
    const password=new TextDecoder("utf-8",{fatal:true}).decode(plain);if(!validPassword(password))throw new Error("Invalid saved password");
    return jsonResponse({version:PASSWORD_VERSION,user_id:target,request_id:requestId,available:true,password,recorded_at:data.recorded_at});
  }catch{return jsonResponse({error:"The saved password cannot be displayed. Check the encryption setup or set a new password."},503);}
}

async function passwordAction(admin: ReturnType<typeof createClient>, callerId: string, clientIp: string, body: Record<string, unknown>) {
  const action = body.action;
  const allowed = action === "password_change_status" ? ["action","user_id","request_id"] : ["action","user_id","request_id","expected_username","password"];
  if (Object.keys(body).some(key=>!allowed.includes(key)) || typeof body.user_id !== "string" || !uuidPattern.test(body.user_id) || typeof body.request_id !== "string" || !uuidPattern.test(body.request_id)) return jsonResponse({error:"Select a valid user and password request."},400);
  const target = body.user_id.toLowerCase(), requestId = body.request_id.toLowerCase();
  if (action === "password_change_status") {
    const {data,error}=await admin.rpc("get_admin_password_change_status_v1",{p_actor:callerId,p_target:target,p_request_id:requestId,p_client_ip:clientIp});
    if(error)return rpcFailure(error);
    if(!data||data.request_id!==requestId||data.user_id!==target||!["pending","confirmed","failed","not_started"].includes(data.status))return jsonResponse({error:"Password status could not be verified."},503);
    return jsonResponse({...data,version:PASSWORD_VERSION,success:data.status==="confirmed"});
  }
  if (!validPassword(body.password) || typeof body.expected_username !== "string" || body.expected_username.length>40) return jsonResponse({error:"Password must use 6 to 20 characters. Numbers alone are allowed."},400);
  const sealed=await encryptPassword(body.password,target,requestId);
  const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(getSecretKey()),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const bytes=await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(JSON.stringify([callerId,target,requestId,body.expected_username,body.password])));
  const fingerprint=Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,"0")).join("");
  const {data:reservation,error:reserveError}=await admin.rpc("reserve_admin_password_change_v1",{p_actor:callerId,p_target:target,p_expected_username:body.expected_username,p_client_ip:clientIp,p_request_id:requestId,p_fingerprint:fingerprint});
  if(reserveError)return rpcFailure(reserveError);
  if(!reservation||reservation.request_id!==requestId||reservation.user_id!==target||reservation.username!==body.expected_username||!["apply","pending","confirmed","failed"].includes(reservation.status))return jsonResponse({error:"Password access could not be verified."},503);
  if(reservation.status!=="apply")return jsonResponse({...reservation,version:PASSWORD_VERSION,success:reservation.status==="confirmed"},reservation.status==="pending"?202:200);
  const pending=()=>jsonResponse({success:false,status:"pending",version:PASSWORD_VERSION,request_id:requestId,user_id:target,error:"The password update is not confirmed yet. It may already be applied. Use Check status before trying another change."},202);
  let outcome: "confirmed" | "failed";let authUpdatedAt:string|null=null;
  try {
    // Only this API receives the password. No email, role, profile or page grants
    // are changed, and no password is sent to the audit/database RPCs.
    const {data,error}=await admin.auth.admin.updateUserById(target,{password:body.password});
    if(error){const status=Number(error.status);if(status<400||status>=500||!Number.isFinite(status))return pending();outcome="failed";}
    else if(data?.user?.id===target&&typeof data.user.updated_at==="string"){outcome="confirmed";authUpdatedAt=data.user.updated_at;}
    else return pending();
  }catch{return pending();}
  for(let attempt=0;attempt<2;attempt++){
    const {data,error}=await admin.rpc("finish_admin_password_change_v1",{p_actor:callerId,p_target:target,p_request_id:requestId,p_fingerprint:fingerprint,p_status:outcome,p_error_code:outcome==="failed"?"auth_rejected":null,p_ciphertext:outcome==="confirmed"?sealed.ciphertext:null,p_nonce:outcome==="confirmed"?sealed.nonce:null,p_key_id:outcome==="confirmed"?sealed.key_id:null,p_auth_updated_at:authUpdatedAt});
    if(!error&&data?.request_id===requestId&&data?.user_id===target&&data?.status===outcome){
      if(outcome==="failed")return jsonResponse({success:false,status:"failed",version:PASSWORD_VERSION,request_id:requestId,user_id:target,error:"Supabase rejected this password. Check the project's Auth password policy, then choose a password with 6 to 20 characters."},400);
      return jsonResponse({success:true,status:"confirmed",version:PASSWORD_VERSION,request_id:requestId,user_id:target,username:reservation.username});
    }
  }
  return pending();
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Read-only installation receipt; no credentials or account data returned.
  if (request.method === "GET") {
    return jsonResponse({ version: PASSWORD_VERSION, password_min_length:6, password_max_length:20, vault_ready:!!vaultBytes(), vault_key_status:!Deno.env.get("GREENLOOP_PASSWORD_VAULT_KEY")?"missing":vaultBytes()?"ready":"invalid", actions:["create_user","change_password","password_change_status","password_info","reveal_password"] });
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
    return jsonResponse({ error: "Sign in again before managing user accounts." }, 401);
  }

  const admin = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: callerData, error: callerError } = await admin.auth.getUser(accessToken);
  const caller = callerData?.user;

  if (callerError || !caller) {
    return jsonResponse({ error: "Your session is not valid. Sign in again." }, 401);
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

  const action = body.action === undefined ? "create_user" : body.action;
  if(!["create_user","change_password","password_change_status","password_info","reveal_password"].includes(String(action)))return jsonResponse({error:"This account action is not supported."},400);
  const clientIp = request.headers.get("cf-connecting-ip") || "";
  if(action!=="create_user") {
    try{return await (["password_info","reveal_password"].includes(String(action))?passwordVisibility(admin,caller.id,clientIp,body):passwordAction(admin,caller.id,clientIp,body));}catch{return jsonResponse({error:["password_info","reveal_password"].includes(String(action))?"Encrypted password viewing could not be verified. Check the encryption setup.":"The password update could not be confirmed. Use Check status before trying again."},503);}
  }
  // The original client IP comes only from Supabase's Cloudflare edge header.
  // Never take it from body.network/IP, XFF or caller-editable user metadata.
  const {data: context, error: contextError} = await admin.rpc("get_office_create_context_v1", {p_actor:caller.id,p_client_ip:clientIp});
  if(contextError || !context || typeof context.allowed !== "boolean" || typeof context.can_create !== "boolean" || typeof context.is_super_admin !== "boolean") return jsonResponse({error:"Office access could not be verified. Try again."},503);
  if(!context.allowed) return jsonResponse({error:"Office access only. Please connect to the office network."},403);
  if(!context.can_create) return jsonResponse({error:"Add Greenloop User permission and an administrator role are required."},403);
  const isSuperAdmin = context.is_super_admin === true;

  const networkMode = body.network_mode === undefined ? "anywhere" : body.network_mode;
  if(networkMode !== "anywhere" && networkMode !== "office") return jsonResponse({error:"Choose Office Only or Anywhere."},400);
  const fullName = String(body.full_name || "").trim().replace(/\s+/g, " ");
  const username = cleanUsername(body.username);
  const password = body.password;
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

  if (!validPassword(password)) {
    return jsonResponse({ error: "Password must use 6 to 20 characters. Numbers alone are allowed." }, 400);
  }

  if (!requestedPages.length) {
    return jsonResponse({ error: "Select at least one page for this user." }, 400);
  }

  if (isSuperAdmin !== true && requestedPages.includes("user_access")) {
    return jsonResponse({ error: "Only Super Admin can grant User Access permission." }, 403);
  }

  if(!vaultBytes())return jsonResponse({error:"The encrypted password service is not configured. Ask the administrator to finish setup."},503);

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

    const vaultRequestId=crypto.randomUUID(),sealed=await encryptPassword(password,createdUserId,vaultRequestId);
    const{data:vaultSaved,error:vaultError}=await admin.rpc("register_created_password_v1",{p_actor:caller.id,p_target:createdUserId,p_username:username,p_client_ip:clientIp,p_request_id:vaultRequestId,p_ciphertext:sealed.ciphertext,p_nonce:sealed.nonce,p_key_id:sealed.key_id,p_auth_updated_at:createdData.user.updated_at});
    if(vaultError||vaultSaved!==true)throw new Error("The new account password could not be saved for authorised admin viewing.");

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
