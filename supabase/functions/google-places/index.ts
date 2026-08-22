// Edge Function: google-places
// Proxy para Google Places API (New) — la clave nunca sale del servidor.
// Parámetros: { name: string, latitude: number, longitude: number }
// Retorna: respuesta JSON de Google (places.accessibilityOptions)

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  const apiKey = Deno.env.get("GOOGLE_PLACES_API_KEY");
  if (!apiKey) {
    return new Response(JSON.stringify({ error: "API key not configured" }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const { name, latitude, longitude } = await req.json();

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

  const response = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey,
      "X-Goog-FieldMask": "places.displayName,places.accessibilityOptions",
    },
    body: JSON.stringify(body),
  });

  const data = await response.json();
  return new Response(JSON.stringify(data), {
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});
