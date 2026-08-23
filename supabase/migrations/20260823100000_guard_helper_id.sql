-- BEFORE UPDATE trigger: impide que cualquier usuario (en especial el solicitante)
-- cambie helper_id a un UUID que no sea el suyo propio.
-- El solicitante queda bloqueado explícitamente aunque auth.uid() == NEW.helper_id.
-- Aplicada el 2026-08-23.

CREATE OR REPLACE FUNCTION public.prevent_helper_id_hijack()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
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

DROP TRIGGER IF EXISTS guard_helper_id ON public.help_requests;
CREATE TRIGGER guard_helper_id
BEFORE UPDATE ON public.help_requests
FOR EACH ROW EXECUTE FUNCTION public.prevent_helper_id_hijack();
