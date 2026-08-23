import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUNDLE_ID = "fastavan.wheelp";
const APNS_HOST = Deno.env.get("APNS_ENVIRONMENT") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";
const ADMIN_EMAIL = "aelguer@icloud.com";
const NEARBY_RADIUS_KM = 5;
const APNS_FETCH_TIMEOUT_MS = 5000;

function base64UrlDecode(input: string): string {
  let b64 = input.replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4) b64 += "=";
  return atob(b64);
}

function isServiceRoleRequest(req: Request): boolean {
  const authHeader = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  try {
    const claims = JSON.parse(base64UrlDecode(authHeader.split(".")[1]));
    return claims.role === "service_role";
  } catch {
    return false;
  }
}

async function apnsJWT(): Promise<string> {
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const keyId  = Deno.env.get("APNS_KEY_ID")!;
  const pem    = Deno.env.get("APNS_PRIVATE_KEY")!
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const keyData = Uint8Array.from(atob(pem), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false, ["sign"]
  );

  const now = Math.floor(Date.now() / 1000);
  const b64u = (o: object) =>
    btoa(JSON.stringify(o)).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");

  const header  = b64u({ alg: "ES256", kid: keyId });
  const payload = b64u({ iss: teamId, iat: now });
  const input   = `${header}.${payload}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(input)
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");
  return `${input}.${sigB64}`;
}

async function sendAlertPush(
  token: string,
  jwt: string,
  title: string,
  body: string,
  contentAvailable = false,
): Promise<{ token: string; ok: boolean; status?: number; apnsId?: string | null; error?: string }> {
  const aps: Record<string, unknown> = {
    alert: { title, body },
    sound: "default",
  };
  if (contentAvailable) aps["content-available"] = 1;

  const tokenPreview = token.slice(0, 8) + "...";
  try {
    const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-push-type": "alert",
        "apns-topic": BUNDLE_ID,
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps }),
      signal: AbortSignal.timeout(APNS_FETCH_TIMEOUT_MS),
    });
    const apnsId = res.headers.get("apns-id");
    if (!res.ok) {
      const errBody = await res.text().catch(() => "");
      return { token: tokenPreview, ok: false, status: res.status, apnsId, error: errBody };
    }
    return { token: tokenPreview, ok: true, status: res.status, apnsId };
  } catch (err) {
    return { token: tokenPreview, ok: false, error: String(err) };
  }
}

Deno.serve(async (req) => {
  if (!isServiceRoleRequest(req)) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const { type, table, record, old_record } = await req.json();
  let userIds: string[] = [];
  let title = "Wheelp";
  let body = "Tienes una notificación nueva";
  let contentAvailable = false;

  if (table === "help_requests" && type === "INSERT") {
    const { data, error } = await supabase.rpc("nearby_helper_ids", {
      p_lat: record.area_latitude,
      p_lng: record.area_longitude,
      p_radius_km: NEARBY_RADIUS_KM,
    });
    if (error) console.error("nearby_helper_ids error", error);
    userIds = (data ?? []).map((r: any) => r.user_id);
    title = "Nueva petición de ayuda";
    body = "Alguien cerca de ti necesita ayuda. Ábrela para ver los detalles.";
    contentAvailable = true;

  } else if (table === "help_requests" && type === "UPDATE"
             && record.status === "accepted" && old_record?.status === "pending") {
    if (record.requester_id) userIds = [record.requester_id];
    title = "¡Tu solicitud fue aceptada!";
    body = "Un ayudante viene en camino";

  } else if (table === "help_messages" && type === "INSERT") {
    const { data: hr } = await supabase
      .from("help_requests")
      .select("requester_id, helper_id")
      .eq("id", record.request_id)
      .single();
    if (hr) {
      const other = record.sender_id === hr.requester_id ? hr.helper_id : hr.requester_id;
      if (other) userIds = [other];
    }
    title = "Nuevo mensaje";
    body = "Tienes un mensaje nuevo en Wheelp";

  } else if (table === "helper_applications" && type === "INSERT") {
    const { data } = await supabase.auth.admin.listUsers();
    const admin = data?.users?.find((u: any) => u.email === ADMIN_EMAIL);
    if (admin) userIds = [admin.id];
    title = "Nueva solicitud de ayudante";
    body = record.display_name
      ? `${record.display_name} quiere unirse como ayudante`
      : "Alguien quiere unirse como ayudante";
  }

  if (!userIds.length) return new Response(JSON.stringify({ sent: 0, reason: "no recipients" }), { status: 200 });

  const { data: tokens } = await supabase
    .from("push_tokens").select("token").in("user_id", userIds);

  if (!tokens?.length) return new Response(JSON.stringify({ sent: 0, reason: "no tokens" }), { status: 200 });

  const jwt = await apnsJWT();
  const results = await Promise.all(
    tokens.map(({ token }) => sendAlertPush(token, jwt, title, body, contentAvailable))
  );

  return new Response(JSON.stringify({ sent: results.filter(r => r.ok).length, results }), { status: 200 });
});
