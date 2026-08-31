-- Audit 2026-08-31, hallazgo 2: un ayudante podía apropiarse de la petición.
--
-- La política update_own_or_helper pasa su WITH CHECK por la rama
-- `helper_id = auth.uid()`, así que una vez aceptada la petición el ayudante
-- podía cambiar CUALQUIER otra columna. El trigger guard_helper_id solo vigila
-- helper_id. Ruta de ataque confirmada:
--   UPDATE help_requests SET requester_id = <ayudante> WHERE id = <peticion>;
-- y la persona que pidió ayuda deja de ver su propia petición —select_own_or_helper
-- exige ser requester o helper— quedándose tirada en la calle mientras el
-- ayudante conserva los detalles cifrados que ya se descargó.
--
-- Se cierra la clase entera, no solo requester_id: todo lo que fija quien pide
-- al crear la petición es inmutable después. Verificado contra HelperService:
-- la app solo actualiza status, helper_id, requester_payload y search_radius_km.
CREATE OR REPLACE FUNCTION public.peticion_inmutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.requester_id   IS DISTINCT FROM OLD.requester_id
    OR NEW.disability_type IS DISTINCT FROM OLD.disability_type
    OR NEW.area_latitude  IS DISTINCT FROM OLD.area_latitude
    OR NEW.area_longitude IS DISTINCT FROM OLD.area_longitude THEN
        RAISE EXCEPTION 'Estos campos de la petición no se pueden cambiar'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS peticion_inmutable ON public.help_requests;
CREATE TRIGGER peticion_inmutable
BEFORE UPDATE ON public.help_requests
FOR EACH ROW EXECUTE FUNCTION public.peticion_inmutable();
