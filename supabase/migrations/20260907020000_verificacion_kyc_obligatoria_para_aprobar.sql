-- Hallazgo del audit de especialistas, 2026-09-06: el kyc_session_id lo
-- escribe el cliente y nadie lo comprobaba contra Didit. Un cliente
-- modificado podía enviar cualquier texto y la solicitud se aprobaba igual.
-- Hoy "nuestros ayudantes están verificados" era falso y comprobable en un
-- repositorio público.
--
-- kyc_verified lo pone SOLO el servidor (admin-actions, tras preguntarle de
-- verdad a Didit), nunca el cliente: no hay política de UPDATE para
-- authenticated sobre estas columnas.
ALTER TABLE public.helper_applications
    ADD COLUMN IF NOT EXISTS kyc_verified   boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS kyc_status     text,
    ADD COLUMN IF NOT EXISTS kyc_checked_at timestamptz;

CREATE OR REPLACE FUNCTION public.admin_approve_helper(p_application_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid; v_kyc_ok boolean;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;
    SELECT user_id, kyc_verified INTO v_user_id, v_kyc_ok
        FROM public.helper_applications WHERE id = p_application_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    IF NOT v_kyc_ok THEN
        RAISE EXCEPTION 'KYC not verified: call verify-helper-kyc before approving';
    END IF;
    UPDATE public.helper_applications SET status = 'approved' WHERE id = p_application_id;
    INSERT INTO public.helpers (user_id) VALUES (v_user_id) ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO public.admin_audit_log (actor_id, accion, target_id, detalle)
        VALUES (auth.uid(), 'approve_helper', p_application_id,
                jsonb_build_object('user_id', v_user_id, 'kyc_status',
                    (SELECT kyc_status FROM public.helper_applications WHERE id = p_application_id)));
END;
$$;
