-- Revocar admin functions de authenticated: el admin ya pasa por la Edge Function
-- admin-actions que usa service_role como proxy. Aplicar DESPUÉS de desplegar
-- la Edge Function admin-actions.
REVOKE EXECUTE ON FUNCTION public.admin_approve_helper(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_reject_helper(uuid)  FROM authenticated;
