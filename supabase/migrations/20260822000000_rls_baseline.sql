-- RLS baseline — snapshot del estado tras el security audit del 2026-08-22.
-- El esquema original (tablas, índices) se aplicó directamente antes de que
-- existiera este directorio. A partir de aquí, cada cambio tiene su migración.
-- Este archivo es idempotente: DROP IF EXISTS + CREATE para poder re-ejecutarlo.

-- ============================================================
-- help_requests
-- ============================================================
ALTER TABLE public.help_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS insert_own             ON public.help_requests;
DROP POLICY IF EXISTS select_own_or_helper   ON public.help_requests;
DROP POLICY IF EXISTS update_own_or_helper   ON public.help_requests;
DROP POLICY IF EXISTS aceptar_pendientes     ON public.help_requests;
DROP POLICY IF EXISTS delete_own_or_helper   ON public.help_requests;

CREATE POLICY insert_own ON public.help_requests
    FOR INSERT TO authenticated
    WITH CHECK (requester_id = auth.uid());

CREATE POLICY select_own_or_helper ON public.help_requests
    FOR SELECT TO authenticated
    USING (
        requester_id = auth.uid()
        OR helper_id = auth.uid()
        OR (status = 'pending' AND EXISTS (
            SELECT 1 FROM public.helpers WHERE helpers.user_id = auth.uid()
        ))
    );

-- update_own_or_helper: allows requester to update payload fields and helper
-- to update status. Field-level protection on helper_id is enforced by the
-- guard_helper_id trigger (see 20260823100000_guard_helper_id.sql).
CREATE POLICY update_own_or_helper ON public.help_requests
    FOR UPDATE TO authenticated
    USING (
        requester_id = auth.uid()
        OR helper_id = auth.uid()
        OR (status = 'pending' AND EXISTS (
            SELECT 1 FROM public.helpers WHERE helpers.user_id = auth.uid()
        ))
    )
    WITH CHECK (requester_id = auth.uid() OR helper_id = auth.uid());

-- aceptar_pendientes: additional guard ensuring only verified helpers can set
-- status=accepted. Works alongside update_own_or_helper (PERMISSIVE OR-logic).
CREATE POLICY aceptar_pendientes ON public.help_requests
    FOR UPDATE TO authenticated
    USING (
        status = 'pending'
        AND EXISTS (SELECT 1 FROM public.helpers h WHERE h.user_id = auth.uid())
    )
    WITH CHECK (helper_id = auth.uid() AND status = 'accepted');

CREATE POLICY delete_own_or_helper ON public.help_requests
    FOR DELETE TO authenticated
    USING (requester_id = auth.uid() OR helper_id = auth.uid());

-- ============================================================
-- help_messages
-- ============================================================
ALTER TABLE public.help_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leer_implicados    ON public.help_messages;
DROP POLICY IF EXISTS escribir_implicados ON public.help_messages;

CREATE POLICY leer_implicados ON public.help_messages
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.help_requests r
        WHERE r.id = help_messages.request_id
          AND (r.requester_id = auth.uid() OR r.helper_id = auth.uid())
    ));

CREATE POLICY escribir_implicados ON public.help_messages
    FOR INSERT TO authenticated
    WITH CHECK (
        sender_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.help_requests r
            WHERE r.id = help_messages.request_id
              AND (r.requester_id = auth.uid() OR r.helper_id = auth.uid())
        )
    );

-- ============================================================
-- profiles
-- ============================================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS insertar_propio_perfil ON public.profiles;
DROP POLICY IF EXISTS leer_propio_perfil     ON public.profiles;

CREATE POLICY insertar_propio_perfil ON public.profiles
    FOR INSERT TO authenticated
    WITH CHECK ((auth.uid())::text = id);

CREATE POLICY leer_propio_perfil ON public.profiles
    FOR SELECT TO authenticated
    USING ((auth.uid())::text = id);

-- ============================================================
-- helper_applications
-- ============================================================
ALTER TABLE public.helper_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS crear_solicitud                ON public.helper_applications;
DROP POLICY IF EXISTS ver_propia_solicitud           ON public.helper_applications;
DROP POLICY IF EXISTS actualizar_solicitud_pendiente ON public.helper_applications;
DROP POLICY IF EXISTS admin_read_helper_applications ON public.helper_applications;

CREATE POLICY crear_solicitud ON public.helper_applications
    FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY ver_propia_solicitud ON public.helper_applications
    FOR SELECT TO authenticated
    USING (auth.uid() = user_id);

-- Applicants can only update while still pending (prevents re-opening rejected)
CREATE POLICY actualizar_solicitud_pendiente ON public.helper_applications
    FOR UPDATE TO authenticated
    USING  (auth.uid() = user_id AND status = 'pending')
    WITH CHECK (auth.uid() = user_id AND status = 'pending');

CREATE POLICY admin_read_helper_applications ON public.helper_applications
    FOR SELECT
    USING (auth.email() = 'aelguer@icloud.com');

-- ============================================================
-- helpers
-- ============================================================
ALTER TABLE public.helpers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leer_propio     ON public.helpers;
DROP POLICY IF EXISTS helpers_update_own ON public.helpers;

CREATE POLICY leer_propio ON public.helpers
    FOR SELECT TO authenticated
    USING (auth.uid() = user_id);

CREATE POLICY helpers_update_own ON public.helpers
    FOR UPDATE TO authenticated
    USING  (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- helper_ratings
-- ============================================================
ALTER TABLE public.helper_ratings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leer_valoraciones ON public.helper_ratings;
DROP POLICY IF EXISTS escribir_propias  ON public.helper_ratings;
DROP POLICY IF EXISTS actualizar_propias ON public.helper_ratings;

CREATE POLICY leer_valoraciones ON public.helper_ratings
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY escribir_propias ON public.helper_ratings
    FOR INSERT TO authenticated
    WITH CHECK (rater_id = auth.uid());

CREATE POLICY actualizar_propias ON public.helper_ratings
    FOR UPDATE TO authenticated
    USING (rater_id = auth.uid());

-- ============================================================
-- push_tokens
-- ============================================================
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS own_token ON public.push_tokens;

CREATE POLICY own_token ON public.push_tokens
    FOR ALL
    USING  (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- accessibility_reports
-- ============================================================
ALTER TABLE public.accessibility_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lectura_autenticados ON public.accessibility_reports;
DROP POLICY IF EXISTS insercion_comunidad  ON public.accessibility_reports;

CREATE POLICY lectura_autenticados ON public.accessibility_reports
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY insercion_comunidad ON public.accessibility_reports
    FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id AND source = 'community');

-- ============================================================
-- website_waitlist
-- ============================================================
ALTER TABLE public.website_waitlist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon puede apuntarse" ON public.website_waitlist;

CREATE POLICY "anon puede apuntarse" ON public.website_waitlist
    FOR INSERT TO anon
    WITH CHECK (true);

-- ============================================================
-- Admin SECURITY DEFINER functions
-- (idempotent — CREATE OR REPLACE)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_approve_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid;
BEGIN
    IF auth.email() IS DISTINCT FROM 'aelguer@icloud.com' THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    SELECT user_id INTO v_user_id
        FROM public.helper_applications WHERE id = p_application_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    UPDATE public.helper_applications SET status = 'approved' WHERE id = p_application_id;
    INSERT INTO public.helpers (user_id) VALUES (v_user_id) ON CONFLICT (user_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF auth.email() IS DISTINCT FROM 'aelguer@icloud.com' THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.helper_applications WHERE id = p_application_id) THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    UPDATE public.helper_applications SET status = 'rejected' WHERE id = p_application_id;
END;
$$;
