-- Complemento de la migración anterior: una política RLS no concede acceso
-- por sí sola, solo lo restringe. admin_audit_log nunca tuvo GRANT a
-- authenticated (por diseño, para que nadie pudiera escribir en ella desde
-- el cliente), así que sin este GRANT la política de SELECT de admins falla
-- con "permission denied" en vez de aplicarse.
grant select on public.admin_audit_log to authenticated;
