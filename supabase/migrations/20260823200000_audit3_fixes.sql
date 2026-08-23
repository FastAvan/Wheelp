-- Audit #3 del 2026-08-23 — 3 correcciones de seguridad.

-- 1. HIGH: helper_ratings.actualizar_propias sin WITH CHECK
--    Sin esta restricción, un usuario podía enviar PATCH y sobrescribir
--    rater_id con el UUID de cualquier otra persona.
DROP POLICY IF EXISTS actualizar_propias ON public.helper_ratings;
CREATE POLICY actualizar_propias ON public.helper_ratings
    FOR UPDATE TO authenticated
    USING     (rater_id = auth.uid())
    WITH CHECK (rater_id = auth.uid());

-- 2. HIGH: rls_auto_enable() SECURITY DEFINER accesible por anon
--    La anon key es pública en el repo, así que cualquiera podía invocar
--    esta función elevada sin autenticarse.
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon, public;

-- 3. MEDIUM: prevent_helper_id_hijack con search_path mutable
--    Recrear la función con SET search_path = '' para fijar el linter
--    de Supabase y eliminar el riesgo de inyección de esquema.
CREATE OR REPLACE FUNCTION public.prevent_helper_id_hijack()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.helper_id IS DISTINCT FROM OLD.helper_id THEN
        IF auth.uid() IS DISTINCT FROM NEW.helper_id
           OR auth.uid() = OLD.requester_id THEN
            RAISE EXCEPTION 'Unauthorized: only the accepting helper may set helper_id'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
