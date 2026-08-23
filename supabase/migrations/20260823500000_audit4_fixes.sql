-- Audit #4 del 2026-08-23 — nuevos findings confirmados.

-- 1. MEDIUM: helper_ratings.escribir_propias sin comprobación de sesión completada
--    Cualquier usuario autenticado podía insertar una valoración sobre cualquier
--    helper sin haber tenido nunca una help_request con él.
--    Fix: añadir EXISTS que exija una help_request completada entre rater y helper.
DROP POLICY IF EXISTS escribir_propias ON public.helper_ratings;
CREATE POLICY escribir_propias ON public.helper_ratings
    FOR INSERT TO authenticated
    WITH CHECK (
        rater_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.help_requests r
            WHERE r.requester_id = auth.uid()
              AND r.helper_id    = helper_ratings.helper_id
              AND r.status       = 'completed'
        )
    );

-- 2. HIGH (parcial): restringir admin functions al mínimo posible sin romper la app.
--    El guard real es auth.email() dentro de la función (server-side, no falsificable),
--    pero satisfacer least-privilege requiere mover el RPC a una Edge Function con
--    service_role. Como paso intermedio, revocamos de 'public' (el grant por defecto)
--    y mantenemos el grant explícito a 'authenticated' con un GRANT restrictivo.
--    TODO: migrar a Edge Function admin-actions antes de lanzamiento público.
REVOKE EXECUTE ON FUNCTION public.admin_approve_helper(uuid) FROM public;
REVOKE EXECUTE ON FUNCTION public.admin_reject_helper(uuid)  FROM public;
GRANT  EXECUTE ON FUNCTION public.admin_approve_helper(uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_reject_helper(uuid)  TO authenticated;
