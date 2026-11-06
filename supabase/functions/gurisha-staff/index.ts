import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const env = (key: string) => {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`Missing environment variable: ${key}`);
  return value;
};

async function hmacHex(secret: string, value: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);

  try {
    const url = env("SUPABASE_URL");
    const anonKey = env("SUPABASE_ANON_KEY");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const pepper = env("GURISHA_PIN_PEPPER");

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const body = await req.json();
    const action = String(body.action || "");

    // Employee PIN login: the PIN is never stored in the browser or database.
    if (action === "login") {
      const shopCode = String(body.shop_code || "").trim().toUpperCase();
      const name = String(body.name || "").trim();
      const pin = String(body.pin || "");
      if (!/^[A-F0-9]{8}$/.test(shopCode) || !name || !/^\d{6}$/.test(pin)) {
        return json({ error: "Code boutique, nom et code PIN à 6 chiffres requis." }, 400);
      }
      const { data: shop, error: shopLookupError } = await admin
        .from("shops").select("id").eq("login_code", shopCode).maybeSingle();
      if (shopLookupError) throw shopLookupError;
      if (!shop) return json({ error: "Code boutique invalide." }, 401);
      const shopId = shop.id;

      const loginKey = await hmacHex(pepper, `${shopId}|${name.toLocaleLowerCase()}`);
      const { data: locked, error: lockError } = await admin.rpc("gurisha_pin_is_locked", {
        p_shop_id: shopId, p_login_key: loginKey,
      });
      if (lockError) throw lockError;
      if (locked === true) return json({ error: "Trop de tentatives. Réessaie dans 15 minutes." }, 429);

      const { data: profiles, error } = await admin
        .from("staff_profiles")
        .select("id,user_id,auth_email,role,roles,is_active,display_name")
        .eq("shop_id", shopId)
        .ilike("display_name", name)
        .limit(2);
      if (error) throw error;
      if (!profiles || profiles.length !== 1 || !profiles[0].is_active) {
        await admin.rpc("gurisha_pin_record_failure", { p_shop_id: shopId, p_login_key: loginKey });
        return json({ error: "Identifiants incorrects ou compte désactivé." }, 401);
      }

      const profile = profiles[0];
      const effectiveRoles = Array.isArray(profile.roles) && profile.roles.length ? profile.roles : [profile.role];
      const { error: metadataError } = await admin.auth.admin.updateUserById(profile.user_id, {
        user_metadata: { gurisha_staff: true, shop_id: shopId, display_name: profile.display_name, gurisha_roles: effectiveRoles, gurisha_primary_role: profile.role }
      });
      if (metadataError) throw metadataError;
      const password = await hmacHex(pepper, `${shopId}|${profile.id}|${pin}`);
      const publicClient = createClient(url, anonKey, {
        auth: { autoRefreshToken: false, persistSession: false },
      });
      const { data: sessionData, error: loginError } = await publicClient.auth
        .signInWithPassword({ email: profile.auth_email, password });

      if (loginError || !sessionData.session) {
        await admin.rpc("gurisha_pin_record_failure", { p_shop_id: shopId, p_login_key: loginKey });
        return json({ error: "Identifiants incorrects ou compte désactivé." }, 401);
      }
      await admin.rpc("gurisha_pin_clear_failures", { p_shop_id: shopId, p_login_key: loginKey });

      return json({
        access_token: sessionData.session.access_token,
        refresh_token: sessionData.session.refresh_token,
        expires_in: sessionData.session.expires_in,
        token_type: sessionData.session.token_type,
        user: {
          id: profile.user_id,
          name: profile.display_name,
          role: profile.role,
          roles: Array.isArray(profile.roles) && profile.roles.length ? profile.roles : [profile.role],
          shop_id: shopId,
        },
      });
    }

    // All management actions require a valid owner session.
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Connexion propriétaire requise." }, 401);

    const callerClient = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: callerData, error: callerError } = await callerClient.auth.getUser();
    if (callerError || !callerData.user) return json({ error: "Session invalide." }, 401);

    const shopId = String(body.shop_id || "");
    if (!shopId) return json({ error: "shop_id requis." }, 400);

    const { data: ownerMembership, error: ownerError } = await admin
      .from("shop_members")
      .select("role")
      .eq("shop_id", shopId)
      .eq("user_id", callerData.user.id)
      .maybeSingle();
    if (ownerError) throw ownerError;
    if (ownerMembership?.role !== "owner") {
      return json({ error: "Seul le propriétaire peut gérer les employés." }, 403);
    }

    if (action === "get_shop_code") {
      const { data: shop, error: shopCodeError } = await admin
        .from("shops").select("login_code").eq("id", shopId).maybeSingle();
      if (shopCodeError) throw shopCodeError;
      if (!shop?.login_code) throw new Error("Code boutique non configuré. Exécutez la migration SQL.");
      return json({ login_code: shop.login_code });
    }

    if (action === "list") {
      const { data, error: listError } = await admin
        .from("staff_profiles")
        .select("id,display_name,role,roles,is_active,created_at")
        .eq("shop_id", shopId)
        .order("display_name");
      if (listError) throw listError;
      return json({ employees: data || [] });
    }

    if (action === "create") {
      const name = String(body.name || "").trim();
      const allowedRoles = [
        "manager","cashier","seller","stock_manager","preparer","order_preparer",
        "delivery_person","hairdresser","beautician","receptionist","baker",
        "mechanic","driver","reservation_manager","delivery_manager","mover",
        "team_leader","event_manager","technician"
      ];
      const roles = [...new Set(Array.isArray(body.roles) ? body.roles.map((r: unknown) => String(r)) : [String(body.role || "")])];
      const pin = String(body.pin || "");
      if (name.length < 2 || name.length > 80) return json({ error: "Le nom doit contenir 2 à 80 caractères." }, 400);
      if (!roles.length || roles.some((r: string) => !allowedRoles.includes(r))) return json({ error: "Sélectionnez au moins un rôle valide." }, 400);
      // Le rôle historique principal reste compatible avec les écrans et règles existants.
      const role = roles.includes("manager") ? "manager" : (roles.length === 1 && roles[0] === "preparer" ? "preparer" : "cashier");
      if (!/^\d{6}$/.test(pin)) return json({ error: "Choisissez un code PIN de 6 chiffres." }, 400);

      const profileId = crypto.randomUUID();
      const authEmail = `${await hmacHex(pepper, `${shopId}|${profileId}`)}@staff.gurisha.invalid`;
      const password = await hmacHex(pepper, `${shopId}|${profileId}|${pin}`);
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email: authEmail,
        password,
        email_confirm: true,
        user_metadata: { gurisha_staff: true, shop_id: shopId, display_name: name },
      });
      if (createError || !created.user) throw createError || new Error("Création du compte impossible.");

      const { error: memberError } = await admin.from("shop_members").insert({
        shop_id: shopId, user_id: created.user.id, role,
      });
      if (memberError) {
        await admin.auth.admin.deleteUser(created.user.id);
        throw memberError;
      }

      const { error: profileError } = await admin.from("staff_profiles").insert({
        id: profileId, shop_id: shopId, user_id: created.user.id,
        auth_email: authEmail, display_name: name, role, roles, is_active: true,
      });
      if (profileError) {
        await admin.from("shop_members").delete().eq("shop_id", shopId).eq("user_id", created.user.id);
        await admin.auth.admin.deleteUser(created.user.id);
        throw profileError;
      }
      return json({ success: true, employee: { id: profileId, name, role, is_active: true } }, 201);
    }

    const employeeId = String(body.employee_id || "");
    const { data: employee, error: employeeError } = await admin
      .from("staff_profiles")
      .select("id,user_id,shop_id,auth_email,display_name,role,is_active")
      .eq("id", employeeId)
      .eq("shop_id", shopId)
      .maybeSingle();
    if (employeeError) throw employeeError;
    if (!employee) return json({ error: "Employé introuvable." }, 404);

    if (action === "set_active") {
      const active = body.active === true;
      const { error: updateError } = await admin.from("staff_profiles")
        .update({ is_active: active, updated_at: new Date().toISOString() })
        .eq("id", employeeId);
      if (updateError) throw updateError;
      // A disabled employee is rejected by this function before Auth is called.
      return json({ success: true, is_active: active });
    }

    if (action === "reset_pin") {
      const pin = String(body.pin || "");
      if (!/^\d{6}$/.test(pin)) return json({ error: "Le nouveau code doit contenir 6 chiffres." }, 400);
      const password = await hmacHex(pepper, `${shopId}|${employeeId}|${pin}`);
      const { error: updateAuthError } = await admin.auth.admin.updateUserById(employee.user_id, { password });
      if (updateAuthError) throw updateAuthError;
      return json({ success: true });
    }

    if (action === "delete") {
      const { error: removeProfileError } = await admin.from("staff_profiles").delete().eq("id", employeeId);
      if (removeProfileError) throw removeProfileError;
      const { error: removeMemberError } = await admin.from("shop_members").delete()
        .eq("shop_id", shopId).eq("user_id", employee.user_id);
      if (removeMemberError) throw removeMemberError;
      const { error: deleteAuthError } = await admin.auth.admin.deleteUser(employee.user_id);
      if (deleteAuthError) throw deleteAuthError;
      return json({ success: true });
    }

    return json({ error: "Action inconnue." }, 400);
  } catch (error) {
    console.error("gurisha-staff error", error);
    return json({ error: error instanceof Error ? error.message : "Erreur serveur." }, 500);
  }
});
