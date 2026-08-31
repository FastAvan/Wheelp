import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Unauthorized" }, 401);

  const anonClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error } = await anonClient.auth.getUser();
  if (error || !user) return json({ error: "Unauthorized" }, 401);

  let body: { action?: string; application_id?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }

  const { action, application_id } = body;
  if (!application_id || !["approve", "reject"].includes(action ?? "")) {
    return json({ error: "Invalid params" }, 400);
  }

  // Se llama con el JWT de la persona, NO con la clave de servicio: quien
  // decide si es admin es la base de datos, vía is_admin(), y no una cadena
  // repetida aquí. Si la clave de servicio se filtra, ya no aprueba ayudantes.
  const fnName = action === "approve" ? "admin_approve_helper" : "admin_reject_helper";
  const { error: fnError } = await anonClient.rpc(fnName, { p_application_id: application_id });
  if (fnError) {
    const forbidden = fnError.message.includes("Unauthorized");
    return json({ error: fnError.message }, forbidden ? 403 : 500);
  }

  return json({ ok: true });
});
