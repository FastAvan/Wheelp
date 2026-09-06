-- Hallazgo del audit de especialistas, 2026-09-06: terminar un servicio
-- borraba la fila entera, y cualquier ayudante podía hacerlo en cualquier
-- momento. Media hora después no quedaba ningún registro de que la ayuda
-- hubiera ocurrido: si alguien denuncia a un ayudante, no había ni forma de
-- confirmar que estuvo asignado a esa persona. Efecto colateral: la política
-- de valoraciones exige status='completed', que ningún camino del código
-- llegaba a escribir nunca — el borrado ocurría antes.
--
-- Una petición que nunca llegó a asignarse (sigue pending, helper_id nulo) no
-- tiene nada que auditar: seguir borrándola es lo correcto para minimización.
-- Una que sí tuvo asignación pasa a un estado final (completed/cancelled) y
-- se conserva un tiempo acotado, lo justo para poder valorar al ayudante o
-- revisar un incidente. purgar_datos_caducados se encarga de borrarla pasado
-- ese plazo — no se guarda indefinidamente.

ALTER TABLE public.help_requests ADD COLUMN IF NOT EXISTS ended_at timestamptz;

CREATE OR REPLACE FUNCTION public.marcar_fin_de_peticion()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.status IN ('completed', 'cancelled') AND OLD.status NOT IN ('completed', 'cancelled') THEN
        NEW.ended_at := now();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS marcar_fin_de_peticion ON public.help_requests;
CREATE TRIGGER marcar_fin_de_peticion
BEFORE UPDATE ON public.help_requests
FOR EACH ROW EXECUTE FUNCTION public.marcar_fin_de_peticion();

DROP POLICY IF EXISTS delete_own_or_helper ON public.help_requests;
CREATE POLICY borrar_solo_pendiente_sin_asignar ON public.help_requests
    FOR DELETE USING (
        requester_id = auth.uid() AND status = 'pending' AND helper_id IS NULL
    );

CREATE OR REPLACE FUNCTION public.purgar_datos_caducados()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    DELETE FROM public.help_requests
     WHERE status = 'pending'
       AND coalesce(scheduled_at, created_at) < now() - interval '24 hours';

    DELETE FROM public.help_requests
     WHERE status IN ('completed', 'cancelled')
       AND ended_at < now() - interval '7 days';

    UPDATE public.helpers
       SET available = false,
           latitude = NULL, longitude = NULL, location = NULL,
           location_updated_at = NULL
     WHERE available_until IS NOT NULL
       AND available_until < now() - interval '1 hour'
       AND (location IS NOT NULL OR available);
END;
$$;
