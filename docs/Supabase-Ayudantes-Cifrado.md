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
