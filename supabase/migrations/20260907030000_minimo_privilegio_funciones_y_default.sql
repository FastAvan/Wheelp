-- Audit 2026-09-07 (F1, F2, F3, F4, F6, y raíz común de todos):
-- CREATE FUNCTION concede EXECUTE a PUBLIC por defecto salvo que se revoque a
-- mano, y el esquema public (dueño postgres) concede lo mismo a anon/authenticated
-- en cada objeto nuevo vía ALTER DEFAULT PRIVILEGES. Eso es lo que dejó
-- is_admin(), nearby_helper_ids(), purgar_datos_caducados() y aceptar_peticion()
-- ejecutables por anon sin que nadie lo pidiera explícitamente.
--
-- nearby_helper_ids ya no es explotable hoy (helpers no tiene política RLS
-- para anon, así que devuelve 0 filas), pero se revoca igual como
-- defensa en profundidad. purgar_datos_caducados es SECURITY DEFINER y sí
-- era un vector de DoS real: cualquiera podía dispararla sin autenticarse.

revoke execute on function public.is_admin() from anon;
revoke execute on function public.nearby_helper_ids(double precision, double precision, double precision) from anon;
revoke execute on function public.purgar_datos_caducados() from anon;
revoke execute on function public.aceptar_peticion(uuid, text, text) from anon;

-- F6: admins y api_rate_limits tenían GRANT ALL a anon/authenticated sin
-- ninguna política RLS que lo compensara. admin_audit_log NO estaba afectada
-- (nunca tuvo grants a anon/authenticated) pese a lo que decía el audit.
revoke all on public.admins from anon, authenticated;
revoke all on public.api_rate_limits from anon, authenticated;

-- Para que esto no se repita con la próxima tabla o función que se cree en
-- public: sin este ALTER DEFAULT PRIVILEGES, cada CREATE FUNCTION/TABLE nuevo
-- vuelve a heredar acceso de anon por defecto.
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public revoke all on tables from anon;

-- F5: admin_audit_log tiene RLS activado pero sin política de SELECT, así que
-- ni siquiera los admins podían leer su propio registro de auditoría.
create policy admins_leen_el_registro
  on public.admin_audit_log
  for select
  to authenticated
  using (public.is_admin());
