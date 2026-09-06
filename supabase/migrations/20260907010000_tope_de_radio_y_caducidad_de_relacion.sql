-- Hallazgo del audit: nearby_pending_requests aceptaba cualquier radio del
-- cliente, sin tope ni límite de llamadas. Con un radio grande, cualquier
-- ayudante recibe todas las peticiones abiertas de España con tipo de
-- discapacidad, zona y hora — un catálogo para elegir víctima. La app en
-- producción nunca pide más de ~21 km (radiusKm 20 + gridPaddingKm 1), así
-- que el tope no cambia nada para uso legítimo.
CREATE OR REPLACE FUNCTION public.nearby_pending_requests(
    p_lat       double precision,
    p_lng       double precision,
    p_radius_km double precision DEFAULT 20
)
RETURNS SETOF help_requests LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT r.*
  FROM public.help_requests r
  WHERE public.check_rate_limit('nearby_pending_requests')
    AND r.status = 'pending'
    AND EXISTS (SELECT 1 FROM public.helpers h WHERE h.user_id = auth.uid())
    AND (
      (r.scheduled_at IS NULL     AND r.created_at   > now() - interval '30 minutes')
      OR (r.scheduled_at IS NOT NULL AND r.scheduled_at > now() - interval '30 minutes')
    )
    AND extensions.st_dwithin(
      extensions.st_setsrid(extensions.st_point(r.area_longitude, r.area_latitude), 4326)::extensions.geography,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
      LEAST(p_radius_km, 50) * 1000
    );
$$;

-- Hallazgo: quien pidió ayuda una vez conservaba lectura permanente de la
-- ubicación de ese ayudante en todos sus turnos futuros, porque la función
-- no comprobaba si la relación seguía activa. Ahora solo mientras hay (o
-- hubo, dentro del margen de retención de 7 días de arriba) una asignación
-- en curso o recién terminada.
CREATE OR REPLACE FUNCTION public.is_requester_of_helper(p_helper_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.help_requests r
        WHERE r.helper_id = p_helper_id
          AND r.requester_id = auth.uid()
          AND r.status IN ('accepted', 'in_progress', 'completed')
    );
$$;
