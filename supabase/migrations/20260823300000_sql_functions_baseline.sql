-- Baseline idempotente de funciones SQL y triggers que existían en producción
-- antes de que existiera el directorio supabase/migrations/.
-- No cambia el comportamiento; solo pone en git lo que ya está deployed.
-- Documentado el 2026-08-23 (audit #3 — schema drift MEDIUM).

-- ============================================================
-- FUNCIONES SQL
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_own_account()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  DELETE FROM public.help_messages     WHERE sender_id    = uid;
  DELETE FROM public.help_requests     WHERE requester_id = uid OR helper_id = uid;
  DELETE FROM public.helper_ratings    WHERE rater_id     = uid OR helper_id = uid;
  DELETE FROM public.helper_applications WHERE user_id    = uid;
  DELETE FROM public.accessibility_reports WHERE user_id  = uid;
  DELETE FROM public.helpers           WHERE user_id      = uid;
  DELETE FROM public.profiles          WHERE id           = uid::text;
  DELETE FROM auth.users               WHERE id           = uid;
END;
$$;

CREATE OR REPLACE FUNCTION public.nearby_helper_ids(
    p_lat       double precision,
    p_lng       double precision,
    p_radius_km double precision
)
RETURNS TABLE(user_id uuid) LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT h.user_id
  FROM public.helpers h
  WHERE h.location IS NOT NULL
    AND extensions.st_dwithin(
      h.location,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
      p_radius_km * 1000
    );
$$;

-- rls_auto_enable: event trigger que activa RLS en toda tabla nueva de public.
-- REVOKE desde anon/public aplicado en 20260823200000_audit3_fixes.sql.
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'pg_catalog' AS $$
DECLARE cmd record;
BEGIN
  FOR cmd IN
    SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
    IF cmd.schema_name IS NOT NULL
       AND cmd.schema_name IN ('public')
       AND cmd.schema_name NOT IN ('pg_catalog','information_schema')
       AND cmd.schema_name NOT LIKE 'pg_toast%'
       AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('ALTER TABLE IF EXISTS %s ENABLE ROW LEVEL SECURITY', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION WHEN OTHERS THEN
        RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
    ELSE
      RAISE LOG 'rls_auto_enable: skip % (schema: %.)', cmd.object_identity, cmd.schema_name;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.touch_helper_location()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
    NEW.location := extensions.st_setsrid(
      extensions.st_point(NEW.longitude, NEW.latitude), 4326
    )::extensions.geography;
    NEW.location_updated_at := now();
  ELSE
    NEW.location := NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.touch_push_token()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.wheelp_send_push()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public', 'extensions', 'net', 'vault' AS $$
DECLARE
  v_service_key text;
  v_url         text := 'https://olkvvidnnurjzwlgsuic.supabase.co/functions/v1/send-push';
  v_body        jsonb;
  v_request_id  bigint;
BEGIN
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'wheelp_service_role_key';

  IF v_service_key IS NULL THEN
    RAISE WARNING 'wheelp_send_push: missing wheelp_service_role_key in vault, skipping push';
    RETURN COALESCE(NEW, OLD);
  END IF;

  v_body := jsonb_build_object(
    'type',   TG_OP,
    'table',  TG_TABLE_NAME,
    'record', row_to_json(NEW)
  );
  IF TG_OP = 'UPDATE' THEN
    v_body := v_body || jsonb_build_object('old_record', row_to_json(OLD));
  END IF;

  SELECT net.http_post(
    url     := v_url,
    body    := v_body,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    timeout_milliseconds := 5000
  ) INTO v_request_id;

  RETURN NEW;
END;
$$;

-- ============================================================
-- TRIGGERS (idempotentes — DROP IF EXISTS antes de CREATE)
-- ============================================================

DROP TRIGGER IF EXISTS push_new_message ON public.help_messages;
CREATE TRIGGER push_new_message
    AFTER INSERT ON public.help_messages
    FOR EACH ROW EXECUTE FUNCTION public.wheelp_send_push();

DROP TRIGGER IF EXISTS push_new_request ON public.help_requests;
CREATE TRIGGER push_new_request
    AFTER INSERT ON public.help_requests
    FOR EACH ROW EXECUTE FUNCTION public.wheelp_send_push();

DROP TRIGGER IF EXISTS push_request_accepted ON public.help_requests;
CREATE TRIGGER push_request_accepted
    AFTER UPDATE ON public.help_requests
    FOR EACH ROW EXECUTE FUNCTION public.wheelp_send_push();

DROP TRIGGER IF EXISTS push_new_helper_application ON public.helper_applications;
CREATE TRIGGER push_new_helper_application
    AFTER INSERT ON public.helper_applications
    FOR EACH ROW EXECUTE FUNCTION public.wheelp_send_push();

DROP TRIGGER IF EXISTS touch_helper_location ON public.helpers;
CREATE TRIGGER touch_helper_location
    BEFORE INSERT OR UPDATE OF latitude, longitude ON public.helpers
    FOR EACH ROW EXECUTE FUNCTION public.touch_helper_location();

DROP TRIGGER IF EXISTS push_token_updated ON public.push_tokens;
CREATE TRIGGER push_token_updated
    BEFORE UPDATE ON public.push_tokens
    FOR EACH ROW EXECUTE FUNCTION public.touch_push_token();
