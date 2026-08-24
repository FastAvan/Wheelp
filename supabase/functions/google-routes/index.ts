// Edge Function: google-routes
// Proxy para Google Routes API v2 (tránsito) — la clave nunca sale del servidor.
// Requiere usuario autenticado; aplica rate limit de 10 llamadas/minuto por usuario.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const FIELD_MASK = [
  "routes.legs.steps.transitDetails",
  "routes.legs.steps.navigationInstruction",
  "routes.legs.steps.travelMode",
  "routes.legs.steps.distanceMeters",
  "routes.legs.steps.staticDuration",
  "routes.duration",
  "routes.legs.steps.transitDetails.stopDetails.departureStop.location",
  "routes.legs.steps.transitDetails.stopDetails.arrivalStop.location",
].join(",");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

  const authClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: authError } = await authClient.auth.getUser();
  if (authError || !user) return json({ error: "Unauthorized" }, 401);

  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: allowed } = await serviceClient.rpc("check_rate_limit", {
    p_endpoint: "google-routes",
  });
  if (!allowed) return json({ error: "Too many requests" }, 429);

  const apiKey = Deno.env.get("GOOGLE_PLACES_API_KEY");
  if (!apiKey) return json({ error: "API key not configured" }, 500);

  let payload: { originLat?: unknown; originLng?: unknown; destLat?: unknown; destLng?: unknown };
  try { payload = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }

  const { originLat, originLng, destLat, destLng } = payload;
  if ([originLat, originLng, destLat, destLng].some((v) => typeof v !== "number" || !Number.isFinite(v))) {
    return json({ error: "Invalid parameters" }, 400);
  }

  const body = {
    origin: { location: { latLng: { latitude: originLat, longitude: originLng } } },
    destination: { location: { latLng: { latitude: destLat, longitude: destLng } } },
    travelMode: "TRANSIT",
    languageCode: "es",
  };

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": FIELD_MASK,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const data = await response.json();
    return json(data, response.status);
  } catch {
    return json({ error: "Upstream request failed or timed out" }, 502);
  } finally {
    clearTimeout(timeout);
  }
});
