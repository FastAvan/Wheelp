// Función retirada el 2026-08-24 (audit #5, hallazgo 6): no la llama ningún
// cliente — el push de "nueva solicitud" ya lo maneja el trigger
// push_new_helper_application -> wheelp_send_push -> send-push directamente.
// Se deja como stub inerte (sin acceso a auth.admin ni a la DB) en lugar de
// eliminarla porque no hay una herramienta de borrado de Edge Functions
// disponible; el stub cierra la superficie de ataque (ya no escanea
// auth.admin.listUsers() en cada invocación).
Deno.serve(() => new Response("Gone — retired, see wheelp_send_push trigger", { status: 410 }));
