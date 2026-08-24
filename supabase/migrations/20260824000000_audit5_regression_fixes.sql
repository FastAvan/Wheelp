-- Audit #5 del 2026-08-24 — corrige 3 regresiones introducidas el 2026-08-23.

-- 1. HIGH: check_rate_limit aceptaba p_user_id y p_max_per_minute del caller,
--    y era ejecutable por anon/authenticated sin REVOKE.
--    Cualquiera podía inflar el contador de otro usuario o saltarse su propio límite.
--    Fix: usar auth.uid() internamente, cap fijo por endpoint, solo service_role.
DROP FUNCTION IF EXISTS public.check_rate_limit(uuid, text, int);

CREATE OR REPLACE FUNCTION public.check_rate_limit(p_endpoint text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_uid    uuid := auth.uid();
    v_window timestamptz := date_trunc('minute', now());
    v_max    int := 10;
    v_count  int;
BEGIN
    IF v_uid IS NULL THEN
        RETURN false;
    END IF;

    DELETE FROM public.api_rate_limits
    WHERE window_start < now() - interval '5 minutes';

    INSERT INTO public.api_rate_limits (user_id, endpoint, window_start, call_count)
    VALUES (v_uid, p_endpoint, v_window, 1)
    ON CONFLICT (user_id, endpoint, window_start)
    DO UPDATE SET call_count = public.api_rate_limits.call_count + 1
    RETURNING call_count INTO v_count;

    RETURN v_count <= v_max;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.check_rate_limit(text) FROM anon, authenticated, public;
GRANT  EXECUTE ON FUNCTION public.check_rate_limit(text) TO service_role;

-- 2. MEDIUM: rls_auto_enable seguía ejecutable por authenticated — el REVOKE
--    del 2026-08-23 solo cubrió anon y public, no authenticated.
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM authenticated;

-- 3. HIGH funcional: admin_approve_helper / admin_reject_helper comprobaban
--    auth.email() = admin, pero bajo service_role (llamado desde la Edge
--    Function admin-actions) auth.email() es NULL — el check fallaba siempre
--    y el flujo de aprobar ayudantes estaba roto en producción.
--    Fix: permitir también auth.role() = 'service_role' (la Edge Function ya
--    verificó el email del admin antes de llegar aquí con su propio JWT check).
CREATE OR REPLACE FUNCTION public.admin_approve_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid;
BEGIN
    IF auth.role() <> 'service_role' AND auth.email() IS DISTINCT FROM 'aelguer@icloud.com' THEN
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
    IF auth.role() <> 'service_role' AND auth.email() IS DISTINCT FROM 'aelguer@icloud.com' THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.helper_applications WHERE id = p_application_id) THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    UPDATE public.helper_applications SET status = 'rejected' WHERE id = p_application_id;
END;
$$;
