-- Audit 2026-08-31, hallazgo 8: deriva entre el fichero y lo desplegado.
--
-- 20260823100000_guard_helper_id.sql creaba prevent_helper_id_hijack() SIN
-- `SET search_path = ''` y sin la rama de liberación. La función viva sí las
-- tiene: se corrigió en caliente y el fichero se quedó atrás. El riesgo no es
-- teórico: reaplicar el histórico en un entorno nuevo instalaría la versión
-- insegura y rompería release().
--
-- El histórico es append-only, así que no se reescribe el fichero viejo: se
-- redefine aquí para que el estado final coincida con producción. Copiado de
-- pg_get_functiondef sobre la base viva, no de memoria.
CREATE OR REPLACE FUNCTION public.prevent_helper_id_hijack()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.helper_id IS DISTINCT FROM OLD.helper_id THEN
        -- Liberar: el ayudante asignado devuelve la petición al grupo.
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
