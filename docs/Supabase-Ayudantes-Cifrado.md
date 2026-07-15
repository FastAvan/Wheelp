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
