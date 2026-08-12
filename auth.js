(() => {
  "use strict";

  const form = document.querySelector("#sign-in-form");
  const usernameInput = document.querySelector("#username");
  const passwordInput = document.querySelector("#password");
  const togglePasswordButton = document.querySelector("#toggle-password");
  const forgotPasswordButton = document.querySelector("#forgot-password");
  const rememberSessionInput = document.querySelector("#remember-session");
  const signInButton = document.querySelector("#sign-in-button");
  const message = document.querySelector("#form-message");
  const config = window.GREENLOOP_CONFIG || {};
  let client;

  function showMessage(text, type = "error") {
    message.textContent = text;
    message.classList.add("is-visible");
    message.classList.toggle("is-success", type === "success");
  }

  function clearMessage() {
    message.textContent = "";
    message.classList.remove("is-visible", "is-success");
  }

  function isConfigured() {
    return Boolean(config.supabaseUrl && config.supabaseAnonKey && window.supabase);
  }

  function getClient() {
    if (!client) {
      client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey, {
        auth: {
          persistSession: rememberSessionInput.checked,
          autoRefreshToken: true,
          detectSessionInUrl: true
        }
      });
    }

    return client;
  }

  function setSubmitting(isSubmitting) {
    signInButton.disabled = isSubmitting;
    signInButton.querySelector("span").textContent = isSubmitting ? "Signing in..." : "Sign in";
  }

  togglePasswordButton.addEventListener("click", () => {
    const isPasswordVisible = passwordInput.type === "text";
    passwordInput.type = isPasswordVisible ? "password" : "text";
    togglePasswordButton.textContent = isPasswordVisible ? "Show" : "Hide";
    togglePasswordButton.setAttribute("aria-label", isPasswordVisible ? "Show password" : "Hide password");
    togglePasswordButton.setAttribute("aria-pressed", String(!isPasswordVisible));
  });

  forgotPasswordButton.addEventListener("click", async () => {
    clearMessage();
    if (!isConfigured()) {
      showMessage("Authentication is not configured yet.");
      return;
    }
    forgotPasswordButton.disabled = true;
    try {
      const { error } = await getClient().auth.resetPasswordForEmail("zeee.afridi@gmail.com");
      if (error) throw error;
      showMessage("A password recovery message was sent to the system recovery email.", "success");
    } catch (error) {
      showMessage(error.message || "Password recovery could not be requested.");
    } finally {
      forgotPasswordButton.disabled = false;
    }
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    clearMessage();

    if (!form.checkValidity()) {
      form.reportValidity();
      return;
    }

    if (!isConfigured()) {
      showMessage("Authentication is not configured yet. Add the Supabase project settings in js/config.js.");
      return;
    }

    setSubmitting(true);

    try {
      const { error } = await getClient().auth.signInWithPassword({
        email: await resolveUsername(usernameInput.value),
        password: passwordInput.value
      });

      if (error) {
        throw error;
      }

      showMessage("Sign-in successful. Loading your workspace...", "success");
      window.location.assign("dashboard.html");
    } catch (error) {
      showMessage(error.message || "We could not sign you in. Check your username and password, then try again.");
      setSubmitting(false);
    }
  });

  async function resolveUsername(value) {
    const username = value.trim();
    if (!username) throw new Error("Enter your username.");
    const { data, error } = await getClient().rpc("resolve_login_username", { p_username: username });
    if (error) throw error;
    const record = Array.isArray(data) ? data[0] : data;
    if (!record?.email) throw new Error("Username or password is incorrect.");
    return record.email;
  }

  async function redirectSignedInUser() {
    if (!isConfigured()) return;

    const { data } = await getClient().auth.getSession();
    if (data.session) {
      window.location.replace("dashboard.html");
    }
  }

  redirectSignedInUser();
})();
