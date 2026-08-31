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
GRANT ALL ON t, actores TO authenticated;

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
-- 5b. El ayudante puede cerrar la sesión ya empezada
-- ============================================================
-- El "Completada" del ayudante borra la fila, y la desaparición de la fila es
-- lo que le dice al solicitante que la ayuda ha terminado. Si el DELETE no
-- pasara, la pantalla del solicitante se quedaría colgada sin que nadie se
-- entere: no hay error visible en ningún lado.
DO $$ DECLARE n int; BEGIN
    EXECUTE format('set local request.jwt.claims to %L',
                   json_build_object('sub', (SELECT ayuda FROM actores), 'role', 'authenticated')::text);
    UPDATE public.help_requests SET status = 'in_progress'
     WHERE id = (SELECT peticion FROM actores);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO t VALUES ('el ayudante puede empezar el trayecto', n = 1);

    DELETE FROM public.help_requests WHERE id = (SELECT peticion FROM actores);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO t VALUES ('el ayudante puede cerrar la sesion empezada', n = 1);
END $$;

-- ============================================================
-- 6. La petición es inmutable (hallazgo 2 del audit)
-- ============================================================
RESET ROLE;
DO $$ DECLARE bloqueado boolean := false; v_otra uuid := gen_random_uuid(); BEGIN
    -- Petición nueva: la anterior la cerró el ayudante en 5b.
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
