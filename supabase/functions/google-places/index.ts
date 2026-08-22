// Edge Function: google-places
// Proxy para Google Places API (New) — la clave nunca sale del servidor.
// Requiere un usuario de Supabase autenticado (no solo la anon key pública),
// para que no cualquiera con la anon key pueda quemar la cuota de Google.
// Parámetros: { name: string, latitude: number, longitude: number }
// Retorna: respuesta JSON de Google (places.accessibilityOptions)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
  if (!authHeader) {
    return json({ error: "Missing Authorization header" }, 401);
  }
  const authClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: authError } = await authClient.auth.getUser();
  if (authError || !user) {
    return json({ error: "Unauthorized" }, 401);
  }

  const apiKey = Deno.env.get("GOOGLE_PLACES_API_KEY");
  if (!apiKey) {
    return json({ error: "API key not configured" }, 500);
  }

  let payload: { name?: unknown; latitude?: unknown; longitude?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const { name, latitude, longitude } = payload;
  if (
    typeof name !== "string" || name.trim().length === 0 ||
    typeof latitude !== "number" || !Number.isFinite(latitude) ||
    typeof longitude !== "number" || !Number.isFinite(longitude)
  ) {
    return json({ error: "Invalid parameters" }, 400);
  }

  const body = {
    textQuery: name,
    languageCode: "es",
    maxResultCount: 1,
    locationBias: {
      circle: {
        center: { latitude, longitude },
        radius: 500.0,
      },
    },
  };

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetch("https://places.googleapis.com/v1/places:searchText", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "places.displayName,places.accessibilityOptions",
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
