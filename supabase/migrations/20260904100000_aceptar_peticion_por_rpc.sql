-- REGRESIÓN GRAVE encontrada por supabase/tests/rls.sql: desde el 30/08/2026
-- ningún ayudante podía aceptar una petición.
--
-- Postgres exige política de SELECT también para un `UPDATE ... WHERE`: la
-- orden tiene que poder leer la fila para localizarla. Al cerrar
-- select_own_or_helper —para que un ayudante de Barcelona dejara de leer las
-- peticiones pendientes de todo el país, con su disability_type dentro— se
-- cerró de paso el único camino por el que se aceptaba. El ayudante ve las
-- peticiones por nearby_pending_requests (SECURITY DEFINER, así que esa función
-- sí las lee), pero el UPDATE de accept() iba contra la tabla y afectaba a CERO
-- filas. PostgREST devuelve 200 sin error, así que fallaba en silencio.
--
-- No se arregla reabriendo el SELECT: eso reabre la fuga de datos de salud. Se
-- mueve la aceptación a una función SECURITY DEFINER, que además es el sitio
-- correcto para resolver la carrera entre dos ayudantes.
CREATE OR REPLACE FUNCTION public.aceptar_peticion(
    p_id            uuid,
    p_helper_pubkey text,
    p_helper_payload text
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE n int;
BEGIN
    -- Ser ayudante sigue siendo requisito: SECURITY DEFINER se salta el RLS, así
    -- que la puerta hay que ponerla aquí a mano.
    IF NOT EXISTS (SELECT 1 FROM public.helpers WHERE user_id = auth.uid()) THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    -- El AND status='pending' es la carrera: si otro se adelantó son 0 filas y
    -- devolvemos false. Los triggers (caducidad, guard_helper_id) siguen
    -- aplicándose porque auth.uid() no cambia dentro de la función.
    UPDATE public.help_requests
       SET status         = 'accepted',
           helper_id      = auth.uid(),
           helper_pubkey  = p_helper_pubkey,
           helper_payload = p_helper_payload
     WHERE id = p_id AND status = 'pending';

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n = 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.aceptar_peticion(uuid, text, text) TO authenticated;
