-- Rate limiting para Edge Functions de Google Places y Google Routes.
-- Ventanas de 1 minuto por usuario y endpoint; solo accesible vía service_role.

CREATE TABLE IF NOT EXISTS public.api_rate_limits (
    user_id      uuid        NOT NULL,
    endpoint     text        NOT NULL,
    window_start timestamptz NOT NULL,
    call_count   int         NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, endpoint, window_start)
);

ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY;
-- Sin políticas RLS públicas: solo service_role puede leer/escribir.

CREATE OR REPLACE FUNCTION public.check_rate_limit(
    p_user_id        uuid,
    p_endpoint       text,
    p_max_per_minute int DEFAULT 10
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_window timestamptz := date_trunc('minute', now());
    v_count  int;
BEGIN
    -- ponytail: limpieza síncrona — suficiente para el volumen actual (< 100 users)
    DELETE FROM public.api_rate_limits
    WHERE window_start < now() - interval '5 minutes';

    INSERT INTO public.api_rate_limits (user_id, endpoint, window_start, call_count)
    VALUES (p_user_id, p_endpoint, v_window, 1)
    ON CONFLICT (user_id, endpoint, window_start)
    DO UPDATE SET call_count = public.api_rate_limits.call_count + 1
    RETURNING call_count INTO v_count;

    RETURN v_count <= p_max_per_minute;
END;
$$;
