-- Fix (2026-08-26): check_rate_limit devolvía SIEMPRE false en producción.
--
-- El audit #5 (20260824000000) cambió la firma a check_rate_limit(p_endpoint)
-- y pasó a resolver el usuario con auth.uid() internamente. Pero las Edge
-- Functions google-places / google-routes llaman a la RPC con el cliente de
-- service_role, cuyo JWT no tiene `sub`: auth.uid() es NULL, se entra en el
-- early-return y la función responde 429 en cada llamada.
-- Efecto: Google Places (accesibilidad de lugares) y Google Routes (transporte)
-- llevan rotos desde el 24/08. Es el mismo fallo que el punto 3 de aquel audit.
--
-- Fix: aceptar el uid del caller como respaldo cuando auth.uid() es NULL.
-- Sigue siendo seguro: la RPC solo es ejecutable por service_role (REVOKE de
-- anon/authenticated más abajo), es decir solo desde una Edge Function que ya
-- ha validado el JWT del usuario con auth.getUser(). El cap sigue fijo en el
-- servidor (la otra mitad de la vulnerabilidad del audit #5).

DROP FUNCTION IF EXISTS public.check_rate_limit(text);

CREATE OR REPLACE FUNCTION public.check_rate_limit(p_endpoint text, p_user_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_uid    uuid := coalesce(auth.uid(), p_user_id);
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

REVOKE EXECUTE ON FUNCTION public.check_rate_limit(text, uuid) FROM anon, authenticated, public;
GRANT  EXECUTE ON FUNCTION public.check_rate_limit(text, uuid) TO service_role;
