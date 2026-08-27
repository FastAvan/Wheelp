-- Fix (2026-08-26): el cap de 10 llamadas/minuto era demasiado bajo para el flujo real.
--
-- Cada búsqueda de destino ordena los 5 primeros resultados por accesibilidad, y eso
-- son 5 llamadas a google-places. Con el cap en 10, dos búsquedas seguidas agotaban la
-- cuota: a partir de ahí todo devolvía 429, la app se quedaba sin datos de Google y
-- caía al fallback de OpenStreetMap (lento). Es la causa de la lentitud percibida.
--
-- La app ya cachea en memoria el resultado por lugar (GooglePlacesAccessibilityService),
-- así que la ficha del destino ya no repite la llamada de la búsqueda. Aun así 10/min
-- deja solo 2 búsquedas por minuto. 60/min da margen de uso normal y sigue acotando el
-- gasto en caso de bucle o abuso.
--
-- NOTA DE COSTE: Places Text Search se factura por llamada. 5 llamadas por búsqueda es
-- el driver de coste principal de esta función — revisar con el CFO si conviene bajar
-- el ranking a 3 resultados o cachear en servidor (tabla) en vez de solo en memoria.

CREATE OR REPLACE FUNCTION public.check_rate_limit(p_endpoint text, p_user_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_uid    uuid := coalesce(auth.uid(), p_user_id);
    v_window timestamptz := date_trunc('minute', now());
    v_max    int := 60;
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
