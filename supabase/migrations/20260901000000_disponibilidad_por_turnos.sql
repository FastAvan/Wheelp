-- Disponibilidad como turno declarado, no como interruptor indefinido.
--
-- Motivo (revisión legal previa): mientras el ayudante está disponible se
-- comparte su zona aproximada en segundo plano. Un interruptor que se sostiene
-- solo convierte eso en seguimiento de alguien que ya no está trabajando —que
-- es exactamente la conducta por la que el Garante italiano sancionó a Foodinho
-- (grupo Glovo) con 5 M€ en noviembre de 2024: geolocalización con la app en
-- segundo plano mientras el repartidor no trabajaba.
--
-- La defensa no es acortar el plazo, es que el estado deje de ser pasivo: se
-- declara una duración, hay que renovarla, y expira sola. "Se dejó el
-- interruptor puesto" no es un argumento que sostenga el responsable del
-- tratamiento (art. 5.2 RGPD, responsabilidad proactiva).

-- Hasta cuándo declaró estar disponible. NULL = nunca activó el turno.
ALTER TABLE public.helpers
    ADD COLUMN IF NOT EXISTS available_until timestamptz;

-- Las filas que ya estaban en available=true vienen de la época del
-- interruptor indefinido: sin turno declarado no hay base para seguir
-- compartiendo ubicación, así que se apagan.
UPDATE public.helpers SET available = false WHERE available_until IS NULL;

-- ============================================================
-- Disponible = declarado Y no caducado
-- ============================================================
-- Se comprueba en el servidor y no solo en el cliente: si la app se cierra sin
-- poder apagar el turno, la caducidad tiene que valer igualmente.
CREATE OR REPLACE FUNCTION public.nearby_helper_ids(
    p_lat       double precision,
    p_lng       double precision,
    p_radius_km double precision
)
RETURNS TABLE(user_id uuid) LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT h.user_id
  FROM public.helpers h
  WHERE h.available
    AND h.available_until IS NOT NULL
    AND h.available_until > now()
    AND h.location IS NOT NULL
    AND extensions.st_dwithin(
      h.location,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
      p_radius_km * 1000
    );
$$;

-- ============================================================
-- Tope de 8 horas, impuesto por el servidor
-- ============================================================
-- El cliente ofrece 2/4/8 h, pero el límite se aplica aquí: una app modificada
-- no debe poder declararse disponible durante una semana. Ocho horas es "una
-- jornada", que se defiende solo.
CREATE OR REPLACE FUNCTION public.limitar_turno_disponibilidad()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.available AND NEW.available_until IS NOT NULL THEN
        IF NEW.available_until > now() + interval '8 hours' THEN
            NEW.available_until := now() + interval '8 hours';
        END IF;
    END IF;
    -- Sin turno declarado no hay disponibilidad posible.
    IF NEW.available AND NEW.available_until IS NULL THEN
        NEW.available := false;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS limitar_turno_disponibilidad ON public.helpers;
CREATE TRIGGER limitar_turno_disponibilidad
BEFORE INSERT OR UPDATE ON public.helpers
FOR EACH ROW EXECUTE FUNCTION public.limitar_turno_disponibilidad();
