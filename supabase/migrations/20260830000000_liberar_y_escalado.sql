-- Bloque 2 de fiabilidad: liberar asignación y escalado de búsqueda.
--
-- Dos huecos que hoy acaban en el mismo sitio — una persona esperando a nadie:
--
--   · Un ayudante que acepta y luego no puede ir NO tiene forma de devolver la
--     petición. Sus únicas salidas son desaparecer o marcarla "Completada"
--     mintiendo. Al desaparecer, close() borra la fila y al solicitante se le
--     desvanece la petición sin explicación: tiene que empezar de cero.
--   · Si nadie acepta, no pasa nada. Ni se amplía la búsqueda ni se avisa.

-- ============================================================
-- 1. Radio de búsqueda por petición, para poder ampliarlo
-- ============================================================
-- Vive en la fila y no en la Edge Function para que ampliarlo sea un UPDATE
-- normal del solicitante: dispara el trigger de push que ya existe, sin RPC
-- nueva ni permisos extra.
ALTER TABLE public.help_requests
    ADD COLUMN IF NOT EXISTS search_radius_km int NOT NULL DEFAULT 5;

ALTER TABLE public.help_requests
    DROP CONSTRAINT IF EXISTS help_requests_radius_sano;
ALTER TABLE public.help_requests
    ADD CONSTRAINT help_requests_radius_sano
    CHECK (search_radius_km BETWEEN 1 AND 50);

-- ============================================================
-- 2. Permitir que el ayudante asignado libere la petición
-- ============================================================
-- Hoy lo bloquean dos cosas a la vez:
--   · guard_helper_id: cualquier cambio de helper_id que no sea "yo me asigno"
--     se rechaza, y poner NULL entra en ese saco.
--   · update_own_or_helper: su WITH CHECK exige requester_id = auth.uid() OR
--     helper_id = auth.uid(); al dejar helper_id en NULL ya no se cumple.
-- Se abren los dos, y solo para este caso concreto.

CREATE OR REPLACE FUNCTION public.prevent_helper_id_hijack()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.helper_id IS DISTINCT FROM OLD.helper_id THEN
        -- Caso permitido: el ayudante asignado devuelve la petición al grupo.
        -- Es justo lo que se quiere fomentar frente a desaparecer sin avisar.
        IF NEW.helper_id IS NULL AND auth.uid() = OLD.helper_id THEN
            RETURN NEW;
        END IF;

        IF auth.uid() IS DISTINCT FROM NEW.helper_id
           OR auth.uid() = OLD.requester_id THEN
            RAISE EXCEPTION 'Unauthorized: only the accepting helper may set helper_id'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP POLICY IF EXISTS liberar_asignacion ON public.help_requests;
CREATE POLICY liberar_asignacion ON public.help_requests
    FOR UPDATE TO authenticated
    USING (helper_id = auth.uid() AND status IN ('accepted', 'in_progress'))
    WITH CHECK (status = 'pending' AND helper_id IS NULL);
