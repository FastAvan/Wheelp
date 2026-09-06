import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const DIDIT_API_BASE = "https://verification.didit.me";

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

  if (action === "approve") {
    // Comprobación real de identidad contra Didit, justo aquí, antes de
    // aprobar. Antes de esto, kyc_session_id lo escribía el cliente y nadie
    // lo validaba: un cliente modificado podía mandar cualquier texto y la
    // solicitud se aprobaba igual.
    const outcome = await verifyKycWithDidit(anonClient, application_id);
    if (!outcome.ok) return json({ error: outcome.error }, outcome.status);
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

/// Consulta el estado real de la sesión de Didit y lo escribe en la fila.
/// Escribe con el cliente de service_role a propósito: kyc_verified no tiene
/// política de UPDATE para `authenticated`, así que ni el propio admin puede
/// tocarlo desde la app. Solo lo pone esta función, tras preguntarle a Didit.
async function verifyKycWithDidit(
  anonClient: ReturnType<typeof createClient>,
  applicationId: string,
): Promise<{ ok: true } | { ok: false; error: string; status: number }> {
  const { data: app, error: fetchError } = await anonClient
    .from("helper_applications")
    .select("kyc_session_id")
    .eq("id", applicationId)
    .single();
  if (fetchError || !app?.kyc_session_id) {
    return { ok: false, error: "No hay sesión de verificación asociada a esta solicitud", status: 400 };
  }

  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const apiKey = Deno.env.get("DIDIT_API_KEY");
  if (!apiKey) {
    // Fallar cerrado: sin clave configurada no se puede comprobar nada, y es
    // mejor bloquear aprobaciones que aprobar a ciegas.
    await serviceClient.from("helper_applications").update({
      kyc_status: "sin_configurar",
      kyc_checked_at: new Date().toISOString(),
    }).eq("id", applicationId);
    return { ok: false, error: "DIDIT_API_KEY no configurada: no se puede verificar la identidad", status: 500 };
  }

  let status = "error_de_red";
  try {
    const res = await fetch(
      `${DIDIT_API_BASE}/v3/session/${app.kyc_session_id}/decision/`,
      { headers: { "x-api-key": apiKey } },
    );
    if (res.ok) {
      const decision = await res.json();
      status = typeof decision?.status === "string" ? decision.status : "desconocido";
    }
  } catch {
    status = "error_de_red";
  }

  const verified = status === "Approved";
  await serviceClient.from("helper_applications").update({
    kyc_verified: verified,
    kyc_status: status,
    kyc_checked_at: new Date().toISOString(),
  }).eq("id", applicationId);

  if (!verified) {
    return { ok: false, error: `Verificación de identidad no aprobada (Didit: ${status})`, status: 422 };
  }
  return { ok: true };
}
