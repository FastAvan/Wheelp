-- Bloque 1 de fiabilidad para la beta pública (2026-08-28).
-- Dos agujeros que solo se manifiestan con usuarios reales y varios ayudantes.

-- ============================================================
-- 1. nearby_helper_ids notificaba a ayudantes NO disponibles
-- ============================================================
-- Filtraba solo por distancia, así que un ayudante que se había marcado como
-- no disponible seguía recibiendo peticiones de ayuda.
--
-- Se mantiene la firma de 3 argumentos a propósito. Añadir un cuarto con
-- DEFAULT crearía una sobrecarga y PostgREST falla por ambigüedad al resolver
-- la RPC por nombre.
--
-- SOBRE LA FRESCURA DE LA UBICACIÓN, que aquí NO se filtra:
-- La tentación es exigir que location_updated_at sea reciente, para no avisar
-- a quien hoy está a 300 km. Se probó y es contraproducente: la app solo
-- actualiza la ubicación en primer plano (updateHelperLocation se llama desde
-- MapHomeView), no en segundo plano. Medido contra producción, el ayudante de
-- pruebas estaba a 1,8 km del destino y disponible, pero su ubicación era de
-- hacía dos días — la última vez que abrió la app. Cualquier ventana razonable
-- lo habría dejado fuera.
--
-- La asimetría manda: notificar de más solo molesta a alguien que declina;
-- notificar de menos deja a una persona con discapacidad esperando a nadie.
-- Hasta que haya presencia real —ubicación en segundo plano o un heartbeat,
-- con sus implicaciones de batería, permisos y privacidad— el único filtro
-- honesto es la disponibilidad declarada.
CREATE OR REPLACE FUNCTION public.nearby_helper_ids(
    p_lat       double precision,
    p_lng       double precision,
    p_radius_km double precision
)
RETURNS TABLE(user_id uuid) LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT h.user_id
  FROM public.helpers h
  WHERE h.available
    AND h.location IS NOT NULL
    AND extensions.st_dwithin(
      h.location,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
      p_radius_km * 1000
    );
$$;

-- ============================================================
-- 2. Las peticiones pendientes no caducaban nunca
-- ============================================================
-- Alguien pide ayuda, se cansa de esperar y se va. Horas después un ayudante
-- abre la app, ve la petición y la acepta: el solicitante recibe "alguien va
-- en camino" para un trayecto que ya no existe.
--
-- Va como trigger y no como política RLS a propósito: sobre help_requests hay
-- varias políticas PERMISSIVE (update_own_or_helper, aceptar_pendientes) que
-- se combinan con OR, así que restringir una sola no cierra nada. El trigger
-- es un punto único de control, se aplique la política que se aplique.
CREATE OR REPLACE FUNCTION public.prevent_stale_accept()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF OLD.status = 'pending' AND NEW.status = 'accepted' THEN
        IF (OLD.scheduled_at IS NULL  AND OLD.created_at   < now() - interval '30 minutes')
        OR (OLD.scheduled_at IS NOT NULL AND OLD.scheduled_at < now() - interval '30 minutes')
        THEN
            RAISE EXCEPTION 'Esta petición ha caducado'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_stale_accept ON public.help_requests;
CREATE TRIGGER prevent_stale_accept
BEFORE UPDATE ON public.help_requests
FOR EACH ROW EXECUTE FUNCTION public.prevent_stale_accept();
