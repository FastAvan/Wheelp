-- Dos correcciones LOW del audit #3 (2026-08-23).

-- 1. LOW: website_waitlist sin restricción de duplicados
--    Un email ya registrado podía volver a insertar filas indefinidamente
--    (no rate limiting a nivel de DB). Índice único case-insensitive:
--    previene spam con el mismo email y variantes de mayúsculas.
CREATE UNIQUE INDEX IF NOT EXISTS website_waitlist_email_key
    ON public.website_waitlist (lower(email));

-- 2. LOW: RLS en helpers bloqueaba al solicitante ver el perfil del ayudante
--    El solicitante necesita leer nombre/avatar del helper asignado a su
--    solicitud para mostrarlo en la tarjeta de ayudante.
DROP POLICY IF EXISTS ver_helper_asignado ON public.helpers;
CREATE POLICY ver_helper_asignado ON public.helpers
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.help_requests r
            WHERE r.helper_id   = helpers.user_id
              AND r.requester_id = auth.uid()
        )
    );
