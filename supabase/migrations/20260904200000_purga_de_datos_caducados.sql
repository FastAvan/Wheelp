-- Audit 2026-08-31, hallazgo 4: no había ningún plazo de conservación aplicado.
--
-- Esto NO fija los plazos que tiene que decidir asesoría legal (cuentas
-- inactivas, valoraciones, solicitudes rechazadas, datos de verificación de
-- identidad). Cierra solo lo que no admite discusión, porque el dato ya no
-- sirve para nada:
--
--   · Una petición pendiente de hace horas está abandonada: prevent_stale_accept
--     ya impide aceptarla pasados 30 minutos. Seguía guardando tipo de
--     discapacidad (categoría especial) y zona. Había una del 7 de agosto.
--
--   · La zona de un ayudante con el turno caducado. La app promete que "al
--     terminar el turno deja de compartirse", y era verdad a medias: dejaba de
--     actualizarse, pero la última zona conocida se quedaba ahí para siempre.
--     Borrarla es lo que hace cierto el texto que lee el ayudante.
CREATE OR REPLACE FUNCTION public.purgar_datos_caducados()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    DELETE FROM public.help_requests
     WHERE status = 'pending'
       AND coalesce(scheduled_at, created_at) < now() - interval '24 hours';

    UPDATE public.helpers
       SET available = false,
           latitude = NULL, longitude = NULL, location = NULL,
           location_updated_at = NULL
     WHERE available_until IS NOT NULL
       AND available_until < now() - interval '1 hour'
       AND (location IS NOT NULL OR available);
END;
$$;

REVOKE ALL ON FUNCTION public.purgar_datos_caducados() FROM anon, authenticated;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('purgar-datos-caducados', '17 * * * *',
                     'SELECT public.purgar_datos_caducados()');
