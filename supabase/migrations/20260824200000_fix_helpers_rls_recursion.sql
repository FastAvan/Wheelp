-- Bug crítico: recursión infinita entre políticas RLS de helpers y help_requests.
--
-- helpers.ver_helper_asignado (añadida el 2026-08-23) consulta help_requests;
-- help_requests.select_own_or_helper / update_own_or_helper / aceptar_pendientes
-- consultan helpers. Postgres detecta el ciclo y devuelve 500 en CUALQUIER
-- consulta a la tabla helpers ("infinite recursion detected in policy for
-- relation helpers") — isRegisteredHelper() fallaba silenciosamente desde
-- entonces y ningún usuario podía entrar en modo ayudante.
--
-- Fix: mover la comprobación cruzada a una función SECURITY DEFINER. Al
-- ejecutarse como el dueño de la función (no como el rol del caller), no
-- vuelve a evaluar las políticas RLS de help_requests y rompe el ciclo.
CREATE OR REPLACE FUNCTION public.is_requester_of_helper(p_helper_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.help_requests r
        WHERE r.helper_id = p_helper_id AND r.requester_id = auth.uid()
    );
$$;
REVOKE ALL ON FUNCTION public.is_requester_of_helper(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.is_requester_of_helper(uuid) TO authenticated;

DROP POLICY IF EXISTS ver_helper_asignado ON public.helpers;
CREATE POLICY ver_helper_asignado ON public.helpers
    FOR SELECT TO authenticated
    USING (public.is_requester_of_helper(user_id));
