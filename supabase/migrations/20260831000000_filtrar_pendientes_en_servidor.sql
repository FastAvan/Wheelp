-- C6: dejar de enviar datos de salud a ayudantes que no pueden atender.
--
-- fetchPending pedía TODAS las peticiones pendientes (limit 50) y filtraba por
-- distancia en el cliente. Es decir, el servidor entregaba a cualquier ayudante
-- verificado —esté en Madrid o en Barcelona— el disability_type, la zona
-- aproximada y el lugar de destino de personas a las que nunca va a ayudar.
--
-- disability_type es dato de categoría especial (art. 9 RGPD): salud. Junto a
-- zona y hora identifica razonablemente a una persona. Enviarlo a quien no está
-- asignado ni puede estarlo no supera la minimización del art. 5.1.c.
--
-- El filtro pasa al servidor. El ayudante sigue viendo lo mismo que necesita
-- para decidir —incluido el tipo de asistencia, que es justo lo que le permite
-- declinar si no se ve capaz— pero solo de las peticiones que tiene cerca.

CREATE OR REPLACE FUNCTION public.nearby_pending_requests(
    p_lat       double precision,
    p_lng       double precision,
    p_radius_km double precision DEFAULT 20
)
RETURNS SETOF public.help_requests
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT r.*
  FROM public.help_requests r
  WHERE r.status = 'pending'
    -- Solo ayudantes dados de alta.
    AND EXISTS (SELECT 1 FROM public.helpers h WHERE h.user_id = auth.uid())
    -- No enseñar lo que el trigger prevent_stale_accept va a rechazar igualmente.
    AND (
      (r.scheduled_at IS NULL     AND r.created_at   > now() - interval '30 minutes')
      OR (r.scheduled_at IS NOT NULL AND r.scheduled_at > now() - interval '30 minutes')
    )
    AND extensions.st_dwithin(
      extensions.st_setsrid(extensions.st_point(r.area_longitude, r.area_latitude), 4326)::extensions.geography,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
      p_radius_km * 1000
    );
$$;

REVOKE ALL ON FUNCTION public.nearby_pending_requests(double precision, double precision, double precision) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.nearby_pending_requests(double precision, double precision, double precision) TO authenticated;

-- Cerrar la vía directa: sin esto el filtro anterior es decorativo, porque el
-- cliente podría seguir consultando la tabla entera.
DROP POLICY IF EXISTS select_own_or_helper ON public.help_requests;
CREATE POLICY select_own_or_helper ON public.help_requests
    FOR SELECT TO authenticated
    USING (requester_id = auth.uid() OR helper_id = auth.uid());
