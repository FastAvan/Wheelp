-- Audit 2026-08-31, hallazgos 1 (HIGH) y 3 (MEDIUM).
--
-- Hallazgo 1: la identidad de admin era un correo personal repetido a fuego en
-- cinco sitios, uno de ellos un repositorio público. Sin punto único de
-- control, sin forma de añadir un segundo admin. Se sustituye por una tabla: el
-- rol pasa a ser un dato, no una constante.
--
-- Hallazgo 3: aprobar o rechazar a un ayudante no dejaba rastro. El único
-- vestigio era la columna status, que se sobrescribe y no dice quién ni cuándo.
CREATE TABLE IF NOT EXISTS public.admins (
    user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    nota       text,
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
-- A propósito sin políticas: nadie lee esta tabla directamente. Se consulta
-- solo desde is_admin(), que es SECURITY DEFINER. Quién es admin no tiene por
-- qué ser público.

INSERT INTO public.admins (user_id, nota)
SELECT id, 'admin inicial, migrado del correo a fuego (audit 2026-08-31)'
FROM auth.users WHERE email = 'aelguer@icloud.com'
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

-- EXECUTE tiene que seguir concedido a authenticated aunque solo se use dentro
-- de políticas: Postgres comprueba el permiso también al evaluar expresiones
-- RLS. Revocarlo rompe la política, no la protege — comprobado en este mismo
-- audit con is_requester_of_helper (hallazgo 7, que por eso se descarta).
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

DROP POLICY IF EXISTS admin_read_helper_applications ON public.helper_applications;
CREATE POLICY admin_read_helper_applications ON public.helper_applications
    FOR SELECT USING (public.is_admin());

CREATE TABLE IF NOT EXISTS public.admin_audit_log (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id   uuid NOT NULL,
    accion     text NOT NULL,
    target_id  uuid,
    detalle    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
-- Sin políticas y sin permisos: solo escriben las funciones SECURITY DEFINER de
-- abajo. Que ni siquiera el admin pueda borrar su propio rastro es el punto.
REVOKE ALL ON public.admin_audit_log FROM anon, authenticated;

-- Antes bastaba `auth.role() = 'service_role'` para saltarse el control. Ahora
-- se exige ser admin de verdad, así que la Edge Function llama con el JWT de la
-- persona y no con la clave de servicio. Si esa clave se filtra, ya no da
-- acceso a aprobar ayudantes.
CREATE OR REPLACE FUNCTION public.admin_approve_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    SELECT user_id INTO v_user_id
        FROM public.helper_applications WHERE id = p_application_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    UPDATE public.helper_applications SET status = 'approved' WHERE id = p_application_id;
    INSERT INTO public.helpers (user_id) VALUES (v_user_id) ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO public.admin_audit_log (actor_id, accion, target_id, detalle)
        VALUES (auth.uid(), 'approve_helper', p_application_id,
                jsonb_build_object('user_id', v_user_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    SELECT user_id INTO v_user_id
        FROM public.helper_applications WHERE id = p_application_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    UPDATE public.helper_applications SET status = 'rejected' WHERE id = p_application_id;
    INSERT INTO public.admin_audit_log (actor_id, accion, target_id, detalle)
        VALUES (auth.uid(), 'reject_helper', p_application_id,
                jsonb_build_object('user_id', v_user_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_approve_helper(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_helper(uuid) TO authenticated;
