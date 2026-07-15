// deno-lint-ignore-file
// ============================================================
// Edge Function: admin-user  (Gastos PDG)
// ============================================================
// Permite al SUPER ADMIN gestionar cuentas de auth desde la app:
//   - setPassword: asigna nueva contraseña
//   - setEmail:    cambia el correo (login)
//   - deleteUser:  elimina la cuenta
//
// Valida el JWT del llamante y confirma en public.profiles
// que su rol sea 'super_admin'.
//
// Deploy:
//   supabase functions deploy admin-user --no-verify-jwt
//   supabase secrets set SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=...
// ============================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Missing token" }, 401);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) {
    return json({ error: "Server not configured" }, 500);
  }

  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: auth } },
  });
  const { data: userRes, error: userErr } = await caller.auth.getUser();
  if (userErr || !userRes?.user) return json({ error: "Invalid token" }, 401);

  const { data: me, error: meErr } = await caller
    .from("profiles")
    .select("role,active")
    .eq("id", userRes.user.id)
    .maybeSingle();
  if (meErr) return json({ error: meErr.message }, 500);
  if (!me || me.role !== "super_admin" || me.active === false) {
    return json({ error: "Solo el Super Admin puede ejecutar esta acción" }, 403);
  }

  let body: any = null;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const { action, targetId, email, password } = body || {};
  if (!action || !targetId) return json({ error: "Faltan action/targetId" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    if (action === "setPassword") {
      if (!password || String(password).length < 6) {
        return json({ error: "Contraseña mínimo 6 caracteres" }, 400);
      }
      const { error } = await admin.auth.admin.updateUserById(targetId, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action === "setEmail") {
      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return json({ error: "Correo inválido" }, 400);
      }
      const { error } = await admin.auth.admin.updateUserById(targetId, {
        email,
        email_confirm: true,
      });
      if (error) return json({ error: error.message }, 400);
      await admin.from("profiles").update({ email }).eq("id", targetId);
      return json({ ok: true });
    }

    if (action === "deleteUser") {
      if (targetId === userRes.user.id) {
        return json({ error: "No puedes borrar tu propia cuenta" }, 400);
      }
      const { error } = await admin.auth.admin.deleteUser(targetId);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: "Acción desconocida" }, 400);
  } catch (e) {
    return json({ error: String((e as any)?.message || e) }, 500);
  }
});
