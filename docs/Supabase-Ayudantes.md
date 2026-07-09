# Ayudantes (versión de prueba) — tablas en Supabase

Red de ayudantes en versión de prueba, con **chat interno** y **alta de ayudantes
gestionada fuera de la app** (tabla `helpers`). Las listas se actualizan por sondeo.

> Notificaciones: la app muestra notificaciones locales cuando aceptan tu petición
> o llega un mensaje, PERO solo mientras está en ejecución. El push real (APNs)
> requiere la cuenta de pago del Apple Developer Program.

## 3ª parte — NUEVAS columnas de trayecto y punto de encuentro (ejecutar si ya creaste `help_requests`)

La petición ahora lleva el **origen** del usuario y el **punto de encuentro** que
elige (inicio, destino u otro punto de la ruta). Los ayudantes ven el trayecto
completo y la distancia se calcula hasta el punto de encuentro.

```sql
alter table public.help_requests
  add column if not exists origin_latitude   double precision,
  add column if not exists origin_longitude  double precision,
  add column if not exists meeting_point     text,   -- origin | destination | route
  add column if not exists meeting_name      text,
  add column if not exists meeting_latitude  double precision,
  add column if not exists meeting_longitude double precision;
```

(Las peticiones antiguas sin estas columnas se siguen mostrando: la app usa el
destino como punto de encuentro por defecto.)

## 2ª parte — NUEVAS tablas `helpers` y `help_messages` (ejecutar si ya creaste `help_requests`)

```sql
-- Ayudantes verificados: el alta la haces TÚ desde el panel de Supabase
-- (Table Editor → helpers → Insert), pegando el user_id del usuario
-- (Authentication → Users → copiar UUID).
create table if not exists public.helpers (
  user_id    uuid primary key,
  name       text,
  created_at timestamptz not null default now()
);

alter table public.helpers enable row level security;

-- Los usuarios solo pueden COMPROBAR si ellos mismos son ayudantes.
create policy "leer_propio"
  on public.helpers for select
  to authenticated using (auth.uid() = user_id);

-- Chat de cada petición de ayuda.
create table if not exists public.help_messages (
  id          uuid primary key,
  request_id  uuid not null references public.help_requests(id) on delete cascade,
  sender_id   uuid not null default auth.uid(),
  sender_name text,
  text        text not null,
  created_at  timestamptz not null default now()
);

alter table public.help_messages enable row level security;

-- Solo los implicados en la petición (solicitante o ayudante) ven y escriben.
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

create index if not exists help_messages_request_idx
  on public.help_messages (request_id, created_at);
```

## Cómo dar de alta a un ayudante (fuera de la app)

1. Supabase → **Authentication → Users** → copia el UUID del usuario.
2. **Table Editor → helpers → Insert row** → pega el UUID en `user_id` (y su nombre).
3. La próxima vez que esa persona abra Wheelp, verá el botón ✋ y la sección
   "Eres ayudante verificado" en Ajustes. Ya no existe el toggle en la app.

## Crear la tabla (una sola vez)

Supabase → **SQL Editor** → pega y ejecuta:

```sql
create table if not exists public.help_requests (
  id              uuid primary key,
  requester_id    uuid not null default auth.uid(),
  requester_name  text,
  place_name      text not null,
  latitude        double precision not null,
  longitude       double precision not null,
  disability_type text not null,                  -- physical | hearing | visual | none
  status          text not null default 'pending', -- pending | accepted | completed | cancelled
  helper_id       uuid,
  helper_name     text,
  created_at      timestamptz not null default now()
);

alter table public.help_requests enable row level security;

-- Cualquier usuario autenticado puede ver las peticiones
-- (los ayudantes necesitan ver las de otros).
create policy "leer_autenticados"
  on public.help_requests for select
  to authenticated using (true);

-- Solo puedes crear peticiones a tu nombre.
create policy "crear_propias"
  on public.help_requests for insert
  to authenticated with check (auth.uid() = requester_id);

-- Puede actualizar: el solicitante (cancelar), el ayudante asignado (completar),
-- o cualquiera si la petición sigue pendiente (para aceptarla).
create policy "actualizar_implicados"
  on public.help_requests for update
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = helper_id or status = 'pending');

create index if not exists help_requests_status_idx
  on public.help_requests (status, created_at desc);
```

## Cómo funciona en la app

**Quien necesita ayuda:**
- En la **ficha del destino** o **durante la navegación**: botón "Pedir ayudante".
- En la versión de voz también con el comando **"ayuda"**.
- Verá "Buscando ayudante…" y, cuando alguien acepte, "Te ayudará X"
  (en la versión de voz se anuncia en alto).
- Puede cancelar en cualquier momento. Si cancela el destino con la petición
  aún pendiente, se cancela sola.

**Quien ayuda:**
- Activa **Ajustes → Ayudantes → Modo ayudante**.
- Aparece un botón ✋ junto al buscador del mapa: abre las **peticiones cercanas**
  (radio 20 km), con nombre, lugar y distancia.
- Al **aceptar**, la petición pasa a "Estás ayudando a…" y puede marcarla como
  **completada** al terminar.

## Probarlo con dos cuentas

1. Ejecuta el SQL de arriba.
2. En un dispositivo/cuenta A: activa el **Modo ayudante** en Ajustes.
3. En la cuenta B (otro dispositivo, u otra sesión): busca un destino y pulsa
   **"Pedir ayudante"**.
4. En la cuenta A: abre el botón ✋ → verás la petición de B → **Aceptar**.
5. En la cuenta B: en unos segundos aparecerá "Te ayudará A".

## Limitaciones conocidas (por diseño, es una prueba)

- Sin verificación de identidad ni fotos: cualquiera puede ser ayudante.
- Sin chat ni llamada: el punto de encuentro es el lugar de la petición.
- Sin push: si la app está cerrada no te enteras (se actualiza al abrirla).
- Radio fijo de 20 km y sondeo cada ~10 s.
```
