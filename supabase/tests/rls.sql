-- Pruebas de las puertas de autorización: RLS y funciones con permisos.
--
-- Audit 2026-08-31, hallazgo 6: la suite de XCTest cubre criptografía,
-- redondeos y aritmética de turnos, pero CERO puertas de auth. El CI estaba en
-- verde precisamente porque nadie probaba eso, y no era teórico: la primera vez
-- que se ejecutó este fichero encontró que ningún ayudante podía aceptar una
-- petición en producción desde hacía un día.
--
-- Esto no se puede probar desde XCTest sin red. Se prueba donde vive la regla:
-- en Postgres, suplantando roles con `set local role` y claims de JWT.
--
-- OJO, error que ya cometí una vez: un bloque DO corre como superusuario y se
-- SALTA el RLS. Toda comprobación de política tiene que ir con
-- `set local role authenticated` y hacer el SELECT fuera del DO, o no prueba
-- nada y da un falso verde.
--
-- Uso:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls.sql
-- Todo ocurre dentro de una transacción que termina en ROLLBACK: no deja rastro
-- y puede correrse contra producción.

\set ON_ERROR_STOP on
BEGIN;

-- ============================================================
-- Fixtures
-- ============================================================
CREATE TEMP TABLE t (nombre text, ok boolean);

DO $$
DECLARE v_pide uuid; v_ayuda uuid; v_ayuda2 uuid; v_tercero uuid; v_admin uuid; v_peticion uuid := gen_random_uuid();
BEGIN
    SELECT user_id INTO v_admin FROM public.admins LIMIT 1;
    SELECT id INTO v_pide    FROM auth.users WHERE id <> v_admin ORDER BY created_at LIMIT 1;
    SELECT id INTO v_ayuda   FROM auth.users WHERE id NOT IN (v_admin, v_pide) ORDER BY created_at LIMIT 1;
    SELECT id INTO v_ayuda2  FROM auth.users WHERE id NOT IN (v_admin, v_pide, v_ayuda) ORDER BY created_at LIMIT 1;
    SELECT id INTO v_tercero FROM auth.users WHERE id NOT IN (v_admin, v_pide, v_ayuda, v_ayuda2) ORDER BY created_at LIMIT 1;

    IF v_tercero IS NULL THEN
        RAISE EXCEPTION 'Hacen falta al menos 5 usuarios para estas pruebas';
    END IF;

    CREATE TEMP TABLE actores AS
        SELECT v_pide AS pide, v_ayuda AS ayuda, v_ayuda2 AS ayuda2, v_tercero AS tercero,
               v_admin AS admin, v_peticion AS peticion;

    -- El ayudante existe y está disponible; el tercero no es ayudante.
    INSERT INTO public.helpers (user_id, available, available_until, latitude, longitude, location)
    VALUES (v_ayuda, true, now() + interval '2 hours', 40.42, -3.70,
            extensions.st_setsrid(extensions.st_point(-3.70, 40.42), 4326)::extensions.geography)
    ON CONFLICT (user_id) DO UPDATE
        SET available = true, available_until = now() + interval '2 hours';

    INSERT INTO public.helpers (user_id, available, available_until)
    VALUES (v_ayuda2, true, now() + interval '2 hours')
    ON CONFLICT (user_id) DO UPDATE SET available = true;

    INSERT INTO public.help_requests
        (id, requester_id, disability_type, status, place_name, requester_pubkey,
         area_latitude, area_longitude)
    VALUES (v_peticion, v_pide, 'visual', 'pending', 'PRUEBA RLS', 'x', 40.42, -3.70);
END $$;

-- Las tablas temporales las crea el rol de la conexión; sin esto, al cambiar a
-- `authenticated` para probar las políticas, el propio andamiaje da
-- "permission denied" y parece un fallo de la prueba.
GRANT ALL ON t, actores TO authenticated, anon;

-- ============================================================
-- 1. Un no-ayudante no ve peticiones cercanas
-- ============================================================
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims TO '{"role":"authenticated"}';
DO $$ DECLARE c int; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.nearby_pending_requests(40.42, -3.70, 10);
    INSERT INTO t VALUES ('no-ayudante no ve peticiones cercanas', c = 0);

    -- El caso positivo importa tanto como el negativo: una política que no deja
    -- pasar a nadie también da "0 filas" y parecería segura.
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.nearby_pending_requests(40.42, -3.70, 10);
    INSERT INTO t VALUES ('un ayudante SI ve la peticion cercana', c >= 1);
END $$;

-- ============================================================
-- 2. Nadie lee la petición de otra persona
-- ============================================================
DO $$ DECLARE c int; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.help_requests WHERE id = (SELECT peticion FROM actores);
    INSERT INTO t VALUES ('un tercero no lee la peticion ajena', c = 0);

    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT pide FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.help_requests WHERE id = (SELECT peticion FROM actores);
    INSERT INTO t VALUES ('quien pide SI lee la suya', c = 1);
END $$;

-- ============================================================
-- 3. Nadie escribe mensajes en una conversación ajena
-- ============================================================
DO $$ DECLARE bloqueado boolean := false; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    BEGIN
        INSERT INTO public.help_messages (id, request_id, sender_id, ciphertext)
        VALUES (gen_random_uuid(), (SELECT peticion FROM actores),
                (SELECT tercero FROM actores), 'x');
    EXCEPTION WHEN insufficient_privilege OR check_violation THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('un tercero no escribe en conversacion ajena', bloqueado);
END $$;

-- ============================================================
-- 4. Solo un admin aprueba ayudantes
-- ============================================================
DO $$ DECLARE bloqueado boolean := false; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    INSERT INTO t VALUES ('is_admin() es falso para quien no lo es', public.is_admin() = false);
    BEGIN
        PERFORM public.admin_approve_helper(gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN bloqueado := (SQLERRM = 'Unauthorized');
    END;
    INSERT INTO t VALUES ('admin_approve_helper rechaza a un no-admin', bloqueado);
END $$;

-- ============================================================
-- 4b. Aprobar un ayudante exige que Didit lo haya verificado de verdad
-- ============================================================
-- Auditoria de especialistas 2026-09-06: kyc_session_id lo escribia el
-- cliente y nadie lo comprobaba contra Didit. Sin este gate, un cliente
-- modificado podia mandar cualquier texto y la solicitud se aprobaba igual.
RESET ROLE;
DO $$ DECLARE v_solicitante uuid; v_app uuid := gen_random_uuid(); bloqueado boolean := false; n int; BEGIN
    SELECT id INTO v_solicitante FROM auth.users WHERE id NOT IN (SELECT user_id FROM public.admins) ORDER BY created_at LIMIT 1;
    INSERT INTO public.helper_applications (id, user_id, display_name, city, status, kyc_session_id)
    VALUES (v_app, v_solicitante, 'Prueba KYC', 'Madrid', 'pending', 'sesion-sin-verificar');

    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', (SELECT user_id FROM public.admins LIMIT 1), 'role', 'authenticated')::text, true);
    BEGIN
        PERFORM public.admin_approve_helper(v_app);
    EXCEPTION WHEN OTHERS THEN bloqueado := (SQLERRM LIKE 'KYC not verified%');
    END;
    INSERT INTO t VALUES ('sin kyc_verified, no se puede aprobar', bloqueado);

    UPDATE public.helper_applications SET kyc_verified = true, kyc_status = 'Approved' WHERE id = v_app;
    PERFORM public.admin_approve_helper(v_app);
    SELECT count(*) INTO n FROM public.helpers WHERE user_id = v_solicitante;
    INSERT INTO t VALUES ('tras verificar de verdad, si se aprueba', n = 1);
END $$;
SET LOCAL ROLE authenticated;

-- ============================================================
-- 5. Aceptar: hace falta ser ayudante, y solo gana el primero
-- ============================================================
-- Como el ayudante, no como superusuario: guard_helper_id exige que quien pone
-- helper_id sea esa misma persona, así que sin identidad la prueba mide otra
-- cosa.
DO $$ DECLARE bloqueado boolean := false; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    BEGIN
        PERFORM public.aceptar_peticion((SELECT peticion FROM actores), 'pk', 'p');
    EXCEPTION WHEN OTHERS THEN bloqueado := (SQLERRM = 'Unauthorized');
    END;
    INSERT INTO t VALUES ('un no-ayudante no puede aceptar', bloqueado);

    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);
    -- Por la RPC, que es como acepta la app: un UPDATE directo no puede
    -- funcionar, porque el ayudante todavía no puede LEER esa fila.
    INSERT INTO t VALUES ('el primero en aceptar se la queda',
                          public.aceptar_peticion((SELECT peticion FROM actores), 'pk', 'payload'));

    -- Segundo ayudante DE VERDAD sobre la misma petición: tiene permiso para
    -- aceptar, pero ya no está pendiente. Debe enterarse (false), no reventar.
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda2 FROM actores), 'role', 'authenticated')::text);
    INSERT INTO t VALUES ('el segundo ayudante llega tarde y lo sabe',
                          public.aceptar_peticion((SELECT peticion FROM actores), 'pk', 'payload') = false);
END $$;

-- ============================================================
-- 5b. El ayudante puede empezar el trayecto
-- ============================================================
-- El cierre de la sesión (completada/cancelada, sin DELETE) se prueba en el
-- bloque 8 más abajo, junto con el resto del hallazgo 2 del audit — antes
-- este bloque esperaba que el DELETE del ayudante tuviera éxito, que es
-- justo la vulnerabilidad que el bloque 8 comprueba que ya no existe.
DO $$ DECLARE n int; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);
    UPDATE public.help_requests SET status = 'in_progress'
     WHERE id = (SELECT peticion FROM actores);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO t VALUES ('el ayudante puede empezar el trayecto', n = 1);
END $$;

-- ============================================================
-- 6. La petición es inmutable (hallazgo 2 del audit)
-- ============================================================
RESET ROLE;
DO $$ DECLARE bloqueado boolean := false; v_otra uuid := gen_random_uuid(); BEGIN
    -- Petición nueva e independiente de la de los bloques 5/5b/8.
    INSERT INTO public.help_requests
        (id, requester_id, disability_type, status, place_name, requester_pubkey,
         area_latitude, area_longitude)
    VALUES (v_otra, (SELECT pide FROM actores), 'visual', 'pending', 'PRUEBA RLS 2', 'x', 40.42, -3.70);
    BEGIN
        UPDATE public.help_requests SET requester_id = (SELECT ayuda FROM actores)
        WHERE id = v_otra;
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('requester_id es inmutable', bloqueado);
END $$;

-- ============================================================
-- 7. El turno no puede pasar de 8 horas
-- ============================================================
DO $$ DECLARE v_hasta timestamptz; BEGIN
    UPDATE public.helpers SET available = true, available_until = now() + interval '30 days'
     WHERE user_id = (SELECT ayuda FROM actores)
    RETURNING available_until INTO v_hasta;
    INSERT INTO t VALUES ('el turno se recorta a 8 h en el servidor',
                          v_hasta <= now() + interval '8 hours' + interval '1 minute');
END $$;

-- Los bloques 6 y 7 corren tras un RESET ROLE (7 modifica helpers como
-- superusuario a propósito, para probar el trigger sin que RLS estorbe). Los
-- de aquí en adelante SÍ necesitan ser 'authenticated' de verdad, o el propio
-- superusuario se salta las políticas que se quieren comprobar — el aviso del
-- principio de este fichero, en el que ya caí una vez al añadir estos bloques.
SET LOCAL ROLE authenticated;

-- ============================================================
-- 8. Terminar una peticion asignada: nunca se borra, y deja rastro
-- ============================================================
-- Auditoria de especialistas 2026-09-06: terminar un servicio borraba la fila
-- entera y cualquier ayudante podia hacerlo en cualquier momento. Media hora
-- despues no quedaba ningun registro de que la ayuda hubiera ocurrido.
DO $$ DECLARE n int; v_ended timestamptz; ok_rating boolean := false; BEGIN
    -- Reutiliza la peticion de los bloques 5/6, ya aceptada por 'ayuda'.
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);

    DELETE FROM public.help_requests WHERE id = (SELECT peticion FROM actores);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO t VALUES ('el ayudante no puede borrar una peticion asignada', n = 0);

    UPDATE public.help_requests SET status = 'completed' WHERE id = (SELECT peticion FROM actores);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO t VALUES ('el ayudante SI puede marcarla completada', n = 1);

    SELECT ended_at INTO v_ended FROM public.help_requests WHERE id = (SELECT peticion FROM actores);
    INSERT INTO t VALUES ('ended_at se estampa solo al terminar', v_ended IS NOT NULL);

    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT pide FROM actores), 'role', 'authenticated')::text);
    BEGIN
        INSERT INTO public.helper_ratings (id, helper_id, rater_id, rating)
        VALUES (gen_random_uuid(), (SELECT ayuda FROM actores), (SELECT pide FROM actores), 5);
        ok_rating := true;
    EXCEPTION WHEN OTHERS THEN ok_rating := false;
    END;
    INSERT INTO t VALUES ('valorar al ayudante ya es posible tras completar', ok_rating);
END $$;

-- ============================================================
-- 9. El radio de busqueda no se puede usar para barrer toda España
-- ============================================================
DO $$ DECLARE c_normal int; c_absurdo int; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c_normal  FROM public.nearby_pending_requests(40.42, -3.70, 21);
    SELECT count(*) INTO c_absurdo FROM public.nearby_pending_requests(40.42, -3.70, 5000);
    INSERT INTO t VALUES ('un radio absurdo se recorta y no cambia el resultado',
                          c_normal = c_absurdo);
END $$;

-- ============================================================
-- 10. Minimo privilegio: anon no ejecuta funciones sensibles (audit 2026-09-07)
-- ============================================================
-- Hallazgos F1-F4: CREATE FUNCTION concede EXECUTE a PUBLIC por defecto, y eso
-- dejaba is_admin(), nearby_helper_ids(), aceptar_peticion() y la purga
-- (SECURITY DEFINER, vector de DoS real) ejecutables sin autenticarse.
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ DECLARE bloqueado boolean := false; BEGIN
    BEGIN
        PERFORM public.is_admin();
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('anon no puede ejecutar is_admin()', bloqueado);

    bloqueado := false;
    BEGIN
        PERFORM public.nearby_helper_ids(40.42, -3.70, 10);
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('anon no puede ejecutar nearby_helper_ids()', bloqueado);

    bloqueado := false;
    BEGIN
        PERFORM public.aceptar_peticion(gen_random_uuid(), 'pk', 'p');
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('anon no puede ejecutar aceptar_peticion()', bloqueado);

    bloqueado := false;
    BEGIN
        PERFORM public.purgar_datos_caducados();
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    INSERT INTO t VALUES ('anon no puede ejecutar purgar_datos_caducados()', bloqueado);
END $$;
SET LOCAL ROLE authenticated;

-- ============================================================
-- 11. admin_audit_log: solo admins la leen, nadie escribe desde el cliente
-- ============================================================
-- Hallazgo F5: RLS estaba activado pero sin politica de SELECT, asi que ni
-- los admins podian leer su propio registro de auditoria.
RESET ROLE;
DO $$ DECLARE v_fila uuid := gen_random_uuid(); BEGIN
    INSERT INTO public.admin_audit_log (id, actor_id, accion)
    VALUES (v_fila, (SELECT admin FROM actores), 'prueba_rls');
    CREATE TEMP TABLE fila_auditoria AS SELECT v_fila AS id;
END $$;
GRANT ALL ON fila_auditoria TO authenticated;
SET LOCAL ROLE authenticated;
DO $$ DECLARE c int; escrito boolean := false; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT admin FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.admin_audit_log WHERE id = (SELECT id FROM fila_auditoria);
    INSERT INTO t VALUES ('un admin SI lee el registro de auditoria', c = 1);

    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT tercero FROM actores), 'role', 'authenticated')::text);
    SELECT count(*) INTO c FROM public.admin_audit_log WHERE id = (SELECT id FROM fila_auditoria);
    INSERT INTO t VALUES ('un no-admin no lee el registro de auditoria', c = 0);

    BEGIN
        INSERT INTO public.admin_audit_log (id, actor_id, accion)
        VALUES (gen_random_uuid(), (SELECT tercero FROM actores), 'prueba_desde_cliente');
        escrito := true;
    EXCEPTION WHEN insufficient_privilege THEN escrito := false;
    END;
    INSERT INTO t VALUES ('nadie escribe en el registro de auditoria desde el cliente', escrito = false);
END $$;

-- ============================================================
-- Resultado
-- ============================================================
SELECT nombre, CASE WHEN ok THEN 'OK' ELSE 'FALLO' END AS resultado FROM t ORDER BY nombre;

DO $$ DECLARE fallos int; BEGIN
    SELECT count(*) INTO fallos FROM t WHERE NOT ok;
    IF fallos > 0 THEN
        RAISE EXCEPTION '% pruebas de autorizacion FALLAN', fallos;
    END IF;
    RAISE NOTICE 'Las % puertas de autorizacion pasan', (SELECT count(*) FROM t);
END $$;

ROLLBACK;
