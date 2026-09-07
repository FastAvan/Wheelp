-- Audit 2026-09-07 (F7): supabase/functions/send-push/index.ts decodificaba
-- el JWT del Authorization sin comprobar su firma. La comprobación real ahora
-- vive en una cabecera aparte, X-Wheelp-Push-Secret, con un secreto que solo
-- controla Wheelp (vault: wheelp_push_secret) y que Supabase no puede rotar
-- por su cuenta — a diferencia de SUPABASE_SERVICE_ROLE_KEY, cuya copia
-- inyectada por la plataforma y la copia legada guardada en vault
-- (wheelp_service_role_key) pueden desincronizarse sin aviso.
--
-- El Authorization: Bearer sigue mandándose igual: hace falta para que el
-- gateway de la función (verify_jwt: true) deje pasar la petición. El
-- secreto en sí (wheelp_push_secret) se crea con vault.create_secret y NO
-- va en este archivo — solo su nombre, que es seguro de commitear.
create or replace function public.wheelp_send_push()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions', 'net', 'vault'
as $function$
declare
  v_service_key text;
  v_push_secret text;
  v_url         text := 'https://olkvvidnnurjzwlgsuic.supabase.co/functions/v1/send-push';
  v_body        jsonb;
  v_request_id  bigint;
begin
  select decrypted_secret into v_service_key
  from vault.decrypted_secrets
  where name = 'wheelp_service_role_key';

  select decrypted_secret into v_push_secret
  from vault.decrypted_secrets
  where name = 'wheelp_push_secret';

  if v_service_key is null or v_push_secret is null then
    raise warning 'wheelp_send_push: falta un secreto en vault, se salta el push';
    return coalesce(new, old);
  end if;

  v_body := jsonb_build_object(
    'type',   tg_op,
    'table',  tg_table_name,
    'record', row_to_json(new)
  );

  if tg_op = 'UPDATE' then
    v_body := v_body || jsonb_build_object('old_record', row_to_json(old));
  end if;

  select net.http_post(
    url := v_url,
    body := v_body,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key,
      'X-Wheelp-Push-Secret', v_push_secret
    ),
    timeout_milliseconds := 5000
  ) into v_request_id;

  return new;
end;
$function$;
