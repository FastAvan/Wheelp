-- Audit 2026-09-28, hallazgo 3: 20 políticas RLS llaman a auth.uid() sin
-- envolverlo en un subselect, así que Postgres lo reevalúa por cada fila en
-- vez de una vez por consulta. Se reescriben todas con (select auth.uid()),
-- que es equivalente en semántica y lo que recomienda la propia guía de
-- Supabase. Ninguna condición cambia, solo cómo se evalúa.
--
-- Hallazgo 4 (y una tercera que el audit no vio, ver abajo): tres políticas
-- estaban en el rol {public} en vez de {authenticated}. No eran explotables
-- —todas exigen auth.uid() = algo o is_admin(), que dan NULL/false sin JWT—
-- pero el rol correcto es authenticated, y se aprovecha esta misma migración
-- para corregirlo. own_token (push_tokens) tiene el mismo problema y no
-- estaba en la lista del audit: incluida aquí por consistencia.

drop policy if exists insercion_comunidad on public.accessibility_reports;
create policy insercion_comunidad on public.accessibility_reports
  for insert to authenticated
  with check (((select auth.uid()) = user_id) and (source = 'community'::text));

drop policy if exists escribir_implicados on public.help_messages;
create policy escribir_implicados on public.help_messages
  for insert to authenticated
  with check (
    (sender_id = (select auth.uid()))
    and exists (
      select 1 from public.help_requests r
      where r.id = help_messages.request_id
        and (r.requester_id = (select auth.uid()) or r.helper_id = (select auth.uid()))
    )
  );

drop policy if exists leer_implicados on public.help_messages;
create policy leer_implicados on public.help_messages
  for select to authenticated
  using (
    exists (
      select 1 from public.help_requests r
      where r.id = help_messages.request_id
        and (r.requester_id = (select auth.uid()) or r.helper_id = (select auth.uid()))
    )
  );

drop policy if exists aceptar_pendientes on public.help_requests;
create policy aceptar_pendientes on public.help_requests
  for update to authenticated
  using (
    status = 'pending'::text
    and exists (select 1 from public.helpers h where h.user_id = (select auth.uid()))
  )
  with check (helper_id = (select auth.uid()) and status = 'accepted'::text);

drop policy if exists borrar_solo_pendiente_sin_asignar on public.help_requests;
create policy borrar_solo_pendiente_sin_asignar on public.help_requests
  for delete to authenticated
  using (
    requester_id = (select auth.uid())
    and status = 'pending'::text
    and helper_id is null
  );

drop policy if exists insert_own on public.help_requests;
create policy insert_own on public.help_requests
  for insert to authenticated
  with check (requester_id = (select auth.uid()));

drop policy if exists liberar_asignacion on public.help_requests;
create policy liberar_asignacion on public.help_requests
  for update to authenticated
  using (
    helper_id = (select auth.uid())
    and status = any (array['accepted'::text, 'in_progress'::text])
  )
  with check (status = 'pending'::text and helper_id is null);

drop policy if exists select_own_or_helper on public.help_requests;
create policy select_own_or_helper on public.help_requests
  for select to authenticated
  using (requester_id = (select auth.uid()) or helper_id = (select auth.uid()));

drop policy if exists update_own_or_helper on public.help_requests;
create policy update_own_or_helper on public.help_requests
  for update to authenticated
  using (
    requester_id = (select auth.uid())
    or helper_id = (select auth.uid())
    or (status = 'pending'::text and exists (select 1 from public.helpers where helpers.user_id = (select auth.uid())))
  )
  with check (requester_id = (select auth.uid()) or helper_id = (select auth.uid()));

drop policy if exists actualizar_solicitud_pendiente on public.helper_applications;
create policy actualizar_solicitud_pendiente on public.helper_applications
  for update to authenticated
  using ((select auth.uid()) = user_id and status = 'pending'::text)
  with check ((select auth.uid()) = user_id and status = 'pending'::text);

drop policy if exists admin_read_helper_applications on public.helper_applications;
create policy admin_read_helper_applications on public.helper_applications
  for select to authenticated
  using (is_admin());

drop policy if exists crear_solicitud on public.helper_applications;
create policy crear_solicitud on public.helper_applications
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists ver_propia_solicitud on public.helper_applications;
create policy ver_propia_solicitud on public.helper_applications
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists actualizar_propias on public.helper_ratings;
create policy actualizar_propias on public.helper_ratings
  for update to authenticated
  using (rater_id = (select auth.uid()))
  with check (rater_id = (select auth.uid()));

drop policy if exists escribir_propias on public.helper_ratings;
create policy escribir_propias on public.helper_ratings
  for insert to authenticated
  with check (
    rater_id = (select auth.uid())
    and exists (
      select 1 from public.help_requests r
      where r.requester_id = (select auth.uid())
        and r.helper_id = helper_ratings.helper_id
        and r.status = 'completed'::text
    )
  );

drop policy if exists leer_valoraciones on public.helper_ratings;
create policy leer_valoraciones on public.helper_ratings
  for select to authenticated
  using (rater_id = (select auth.uid()));

drop policy if exists helpers_update_own on public.helpers;
create policy helpers_update_own on public.helpers
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists leer_propio on public.helpers;
create policy leer_propio on public.helpers
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists insertar_propio_perfil on public.profiles;
create policy insertar_propio_perfil on public.profiles
  for insert to authenticated
  with check (((select auth.uid()))::text = id);

drop policy if exists leer_propio_perfil on public.profiles;
create policy leer_propio_perfil on public.profiles
  for select to authenticated
  using (((select auth.uid()))::text = id);

drop policy if exists own_token on public.push_tokens;
create policy own_token on public.push_tokens
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
