# Red de ayudantes CIFRADA de extremo a extremo — recrear tablas

A partir de 2026-07-13 las peticiones de ayuda y el chat van cifrados de
extremo a extremo: **Supabase solo ve una zona aproximada (~1 km), el lugar de
destino, claves públicas y texto cifrado**. Nombres, trayecto exacto, punto de
encuentro y mensajes solo se descifran en los dos dispositivos implicados
(claves efímeras Curve25519 + AES-GCM; las privadas viven en el Llavero).
Al completar o cancelar, la petición y su chat se BORRAN del servidor.

Ejecutar en Supabase → SQL Editor (borra las tablas antiguas de prueba):

```sql
drop table if exists public.help_messages;
drop table if exists public.help_requests;

create table public.help_requests (
  id                uuid primary key,
  requester_id      uuid not null default auth.uid(),
  helper_id         uuid,
  status            text not null default 'pending',  -- pending | accepted
  disability_type   text not null,
  -- Lo único legible: zona aproximada de recogida (~1 km) y lugar de destino.
  area_latitude     double precision not null,
  area_longitude    double precision not null,
  place_name        text not null,
  -- Intercambio de claves y contenido cifrado de extremo a extremo.
  requester_pubkey  text not null,
  helper_pubkey     text,
  requester_payload text,   -- cifrado: nombre y trayecto exacto del solicitante
  helper_payload    text,   -- cifrado: nombre del ayudante
  created_at        timestamptz not null default now()
);

alter table public.help_requests enable row level security;

create policy "leer_autenticados"
  on public.help_requests for select
  to authenticated using (true);

create policy "crear_propias"
  on public.help_requests for insert
  to authenticated with check (auth.uid() = requester_id);

-- Los implicados gestionan su propia petición.
create policy "actualizar_propios"
  on public.help_requests for update
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = helper_id);

-- Aceptar: solo ayudantes dados de alta, asignándose a sí mismos.
create policy "aceptar_pendientes"
  on public.help_requests for update
  to authenticated
  using (
    status = 'pending'
    and exists (select 1 from public.helpers h where h.user_id = auth.uid())
  )
  with check (helper_id = auth.uid() and status = 'accepted');

-- Terminar la ayuda borra la petición (y el chat, en cascada).
create policy "borrar_implicados"
  on public.help_requests for delete
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = helper_id);

create index help_requests_status_idx
  on public.help_requests (status, created_at desc);

create table public.help_messages (
  id         uuid primary key,
  request_id uuid not null references public.help_requests(id) on delete cascade,
  sender_id  uuid not null default auth.uid(),
  ciphertext text not null,   -- mensaje cifrado de extremo a extremo
  created_at timestamptz not null default now()
);

alter table public.help_messages enable row level security;

create policy "leer_implicados"
  on public.help_messages for select
  to authenticated using (
    exists (
      select 1 from public.help_requests r
      where r.id = request_id
        and (r.requester_id = auth.uid() or r.helper_id = auth.uid())
    )
  );

create policy "escribir_implicados"
  on public.help_messages for insert
  to authenticated with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.help_requests r
      where r.id = request_id
        and (r.requester_id = auth.uid() or r.helper_id = auth.uid())
    )
  );

create index help_messages_request_idx
  on public.help_messages (request_id, created_at);
```

## Qué puede ver cada cual

| Quién                  | Qué ve                                                        |
|------------------------|---------------------------------------------------------------|
| Supabase / operador    | Zona ~1 km, lugar de destino, tipo de discapacidad, cifrado   |
| Ayudante SIN aceptar   | Lo mismo que Supabase (+ distancia a la zona)                 |
| Ayudante tras aceptar  | Nombre, trayecto exacto y punto de encuentro (descifrados)    |
| Tras completar/cancelar| Nada: las filas se borran                                     |

Nota: el servidor sigue conociendo los `user_id` (necesarios para las
políticas de seguridad) y las horas. Con la app llegando a cientos de
usuarios, Supabase queda como un "buzón" reemplazable: todo pasa por
`HelperService` y el contenido ya viaja cifrado, así que migrar a un servidor
propio solo requiere cambiar esa pieza.

---

## 5ª parte — CITAS PROGRAMADAS (añadir columna, 2026-07-14)

Ejecutar si ya tienes la tabla creada con el esquema de la 1ª parte:

```sql
alter table public.help_requests
  add column if not exists scheduled_at timestamptz;

-- Índice para ordenar las citas por fecha.
create index if not exists help_requests_scheduled_idx
  on public.help_requests (scheduled_at asc)
  where scheduled_at is not null;
```

Si prefieres recrear la tabla desde cero, añade la columna al `create table`
de la 1ª parte (justo después de `created_at`):

```sql
  scheduled_at      timestamptz,          -- null = inmediata, fecha = cita programada
```

### Cómo funciona

- **Petición inmediata**: `scheduled_at IS NULL`. Los ayudantes la ven en "Peticiones cercanas".
- **Cita programada**: `scheduled_at` tiene una fecha/hora futura (mínimo 30 min desde ahora, máximo 7 días). Los ayudantes la ven en "Citas programadas", ordenadas por hora más próxima primero.
- Al aceptar una cita, el ayudante recibe dos recordatorios locales: 30 minutos antes y en el momento exacto.
- La fecha es legible por Supabase (timestamp plano), pero el trayecto y los nombres siguen cifrados.

---

## 6ª parte — VALORACIONES DE AYUDANTES (nueva tabla, 2026-07-15)

Ejecutar en Supabase → SQL Editor:

```sql
create table public.helper_ratings (
  id          uuid primary key,
  helper_id   uuid not null,
  rater_id    uuid not null default auth.uid(),
  rating      int  not null check (rating between 1 and 5),
  created_at  timestamptz not null default now(),
  unique (rater_id, helper_id)   -- un usuario = una valoración por ayudante
);

alter table public.helper_ratings enable row level security;

-- Cualquier usuario autenticado puede leer valoraciones (para mostrar la media).
create policy "leer_valoraciones"
  on public.helper_ratings for select
  to authenticated using (true);

-- Cada usuario solo inserta/modifica sus propias valoraciones.
create policy "escribir_propias"
  on public.helper_ratings for insert
  to authenticated with check (rater_id = auth.uid());

create policy "actualizar_propias"
  on public.helper_ratings for update
  to authenticated using (rater_id = auth.uid());

create index helper_ratings_helper_idx
  on public.helper_ratings (helper_id);
```

### Cómo funciona

- Al terminar una ruta con ayudante (botón "Finalizar"), se muestra una hoja modal con 1-5 estrellas y un botón "Ahora no".
- La valoración se guarda con `upsert` por `(rater_id, helper_id)`: si el usuario ya había valorado a ese ayudante, se actualiza la nota.
- El ayudante ve su nota media en Ajustes → sección "Ayudantes".
- **Privacidad**: Supabase ve `helper_id`, `rater_id` y `rating` (todo público por diseño; las valoraciones son datos voluntarios, no sensibles).

---

## 7ª parte — Foto de perfil del ayudante (columna + política RLS)

### SQL necesario (ejecutar en Supabase → SQL Editor)

```sql
-- Añade la columna para la foto del ayudante (puede ser NULL).
alter table public.helpers
  add column if not exists avatar_url text;

-- Permite al ayudante actualizar su propia foto.
create policy "helpers_update_own"
  on public.helpers for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
```

### Cómo funciona en la app

- El ayudante abre **Ajustes → Ayudantes** y toca el icono de cámara junto a su foto.
- Se abre `AvatarCropView`: el usuario ajusta el recorte circular con pellizco y arrastre; al confirmar se genera un JPEG 512×512 recortado al píxel.
- La imagen se convierte a `data:image/jpeg;base64,…` y se guarda directamente en `helpers.avatar_url` (sin Supabase Storage). Esto simplifica la configuración y no requiere bucket ni políticas de Storage.
- `HelperAvatarView` detecta el prefijo `data:image/jpeg;base64,` y decodifica la imagen en background; en caso contrario usa `AsyncImage` para URLs HTTP normales (por si se migra a Storage en el futuro).
- Sin foto, el ayudante ve el aviso naranja en la lista de peticiones y no puede aceptar ninguna hasta añadirla.

---

## 8ª parte — Eliminación de cuenta por el propio usuario (RGPD + App Store)

La app llama a `supabase.rpc("delete_own_account")` desde `AppState.deleteAccount()`.
Esta función SQL se ejecuta como `security definer` (con privilegios elevados), pero
solo actúa sobre el `auth.uid()` del usuario autenticado — nunca sobre otra cuenta.

### SQL necesario (ejecutar en Supabase → SQL Editor)

```sql
-- Elimina todos los datos del usuario autenticado y su cuenta de auth.
-- Seguro: usa auth.uid() para identificar al solicitante; no acepta parámetros externos.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
as $$
declare
  uid uuid := auth.uid();
begin
  -- Cancelar peticiones de ayuda activas (como solicitante o como ayudante).
  delete from public.help_requests
    where requester_id = uid or helper_id = uid;

  -- Eliminar valoraciones emitidas.
  delete from public.helper_ratings
    where rater_id = uid;

  -- Eliminar perfil de ayudante.
  delete from public.helpers
    where user_id = uid;

  -- Eliminar la cuenta de autenticación (paso final).
  delete from auth.users
    where id = uid;
end;
$$;

-- Solo usuarios autenticados pueden invocar la función (y solo borra su propia cuenta).
grant execute on function public.delete_own_account() to authenticated;
```

### Cómo funciona en la app

- El usuario abre **Ajustes → Eliminar mi cuenta** (sección al final de la lista).
- Aparece un alert de confirmación destructivo.
- Al confirmar: se llama a `delete_own_account()` en Supabase, que borra
  peticiones activas, valoraciones, perfil de ayudante y la cuenta de auth.
- A continuación se borran todos los `UserDefaults` locales y el estado en memoria.
- La app vuelve automáticamente a la pantalla de login.
- Si la función SQL no está creada aún, el RPC falla y se muestra un alert de error.

---

## 9ª parte — Solicitudes de alta como ayudante desde la app

Los usuarios pueden pedir ser ayudantes desde **Ajustes → Red de ayudantes**.
El equipo de Wheelp revisa en Supabase y aprueba insertando en `helpers`.

### SQL necesario (ejecutar en Supabase → SQL Editor)

```sql
-- Tabla de solicitudes de alta como ayudante.
create table public.helper_applications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid(),
  display_name text not null,
  city         text not null,
  motivation   text,
  status       text not null default 'pending',  -- pending | approved | rejected
  created_at   timestamptz not null default now(),
  unique (user_id)  -- un usuario = una solicitud (upsert para re-solicitar)
);

alter table public.helper_applications enable row level security;

-- El usuario solo ve su propia solicitud.
create policy "ver_propia_solicitud"
  on public.helper_applications for select
  to authenticated using (auth.uid() = user_id);

-- El usuario solo puede insertar/actualizar su propia solicitud.
create policy "crear_solicitud"
  on public.helper_applications for insert
  to authenticated with check (auth.uid() = user_id);

create policy "actualizar_solicitud"
  on public.helper_applications for update
  to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

### Actualizar `delete_own_account` para borrar también la solicitud

Volver a ejecutar la función de la 8ª parte con esta línea añadida:

```sql
create or replace function public.delete_own_account()
returns void language plpgsql security definer as $$
declare uid uuid := auth.uid();
begin
  delete from public.help_requests
    where requester_id = uid or helper_id = uid;
  delete from public.helper_ratings
    where rater_id = uid;
  delete from public.helper_applications
    where user_id = uid;
  delete from public.helpers
    where user_id = uid;
  delete from auth.users
    where id = uid;
end;
$$;

grant execute on function public.delete_own_account() to authenticated;
```

### Flujo de aprobación (manual en Supabase)

1. Usuario envía solicitud → fila en `helper_applications` con `status = 'pending'`
2. Tú abres Supabase → Table Editor → `helper_applications` → ves nombre, ciudad y motivación
3. Para aprobar: inserta una fila en `helpers (user_id, display_name)` y cambia `status = 'approved'` en `helper_applications`
4. La app detecta el cambio en el próximo arranque y activa la versión ayudante
5. Para rechazar: cambia `status = 'rejected'`; el usuario verá "Solicitud no aprobada" en Ajustes

---

## 10ª parte — Panel de administrador en la app

Permite aprobar/rechazar solicitudes directamente desde **Ajustes → Administración**
(solo visible para la cuenta administrador). No hay que entrar a Supabase.

### SQL necesario (ejecutar en Supabase → SQL Editor)

```sql
-- Actualizar RLS: el admin puede leer todas las solicitudes.
drop policy if exists "ver_propia_solicitud" on public.helper_applications;
drop policy if exists "ver_solicitudes"      on public.helper_applications;

create policy "ver_solicitudes"
  on public.helper_applications for select
  to authenticated
  using (
    auth.uid() = user_id
    or (select email from auth.users where id = auth.uid()) = 'aelguer@icloud.com'
  );

-- Función: aprobar solicitud e insertar en helpers.
-- Cambia 'aelguer@icloud.com' si en el futuro hay más admins.
create or replace function public.approve_helper_application(application_id uuid)
returns void language plpgsql security definer as $$
declare
  app public.helper_applications%rowtype;
begin
  if (select email from auth.users where id = auth.uid()) != 'aelguer@icloud.com' then
    raise exception 'No autorizado';
  end if;

  select * into app from public.helper_applications where id = application_id;

  insert into public.helpers (user_id, display_name)
    values (app.user_id, app.display_name)
    on conflict (user_id) do nothing;

  update public.helper_applications
    set status = 'approved'
    where id = application_id;
end;
$$;

-- Función: rechazar solicitud.
create or replace function public.reject_helper_application(application_id uuid)
returns void language plpgsql security definer as $$
begin
  if (select email from auth.users where id = auth.uid()) != 'aelguer@icloud.com' then
    raise exception 'No autorizado';
  end if;

  update public.helper_applications
    set status = 'rejected'
    where id = application_id;
end;
$$;

grant execute on function public.approve_helper_application(uuid) to authenticated;
grant execute on function public.reject_helper_application(uuid) to authenticated;
```

> **Nota:** `approve_helper_application` asume que `helpers` tiene columna `display_name TEXT`.
> Si no existe, añádela: `alter table public.helpers add column if not exists display_name text;`

---

## 11ª parte — Documentación obligatoria en la solicitud de ayudante

Los solicitantes deben adjuntar DNI (dos caras) y certificado de antecedentes penales,
además de su número de teléfono. Las imágenes se guardan como data URI (base64 JPEG)
directamente en la tabla.

### SQL necesario (ejecutar en Supabase → SQL Editor)

```sql
alter table public.helper_applications
  add column if not exists phone           text,
  add column if not exists dni_front       text,
  add column if not exists dni_back        text,
  add column if not exists criminal_record text;
```

### Notas

- Las columnas son `text` nullable: los valores llegaron de la app en formato `data:image/jpeg;base64,…`
- El dashboard web carga los documentos **bajo demanda** (no en el listado inicial) para evitar transferir datos innecesariamente
- Al hacer clic en un documento en el dashboard se abre en pantalla completa para revisarlo con comodidad
- Las imágenes se comprimen en el dispositivo a ≤ 1600 px / 65 % JPEG antes de subirlas
