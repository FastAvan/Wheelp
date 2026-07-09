# Accesibilidad en Supabase — tabla y sembrado de datos (ONCE / comunidad)

Este documento explica cómo crear la tabla `accessibility_reports` en Supabase y cómo
**sembrar** datos oficiales (por ejemplo de la Fundación ONCE) cargando un CSV.

La app ya está preparada: lee esta tabla y, si una fila tiene `source = 'once'`, la
muestra con prioridad y la etiqueta como **"Fundación ONCE"** en la ficha del destino.

---

## 1. Crear la tabla (una sola vez)

En Supabase → **SQL Editor** → pega y ejecuta:

```sql
create table if not exists public.accessibility_reports (
  id              uuid primary key default gen_random_uuid(),
  place_key       text not null,
  place_name      text,
  latitude        double precision,
  longitude       double precision,
  disability_type text not null,                 -- physical | hearing | visual | none
  features        jsonb not null default '{}',   -- { "Criterio": "available|limited|unavailable|unknown" }
  source          text not null default 'community',  -- community | once
  user_id         uuid default auth.uid(),
  created_at      timestamptz not null default now()
);

alter table public.accessibility_reports enable row level security;

-- Cualquier usuario autenticado puede leer.
create policy "lectura_autenticados"
  on public.accessibility_reports for select
  to authenticated using (true);

-- Los usuarios solo pueden insertar aportaciones propias de la comunidad.
create policy "insercion_comunidad"
  on public.accessibility_reports for insert
  to authenticated
  with check (auth.uid() = user_id and source = 'community');

create index if not exists accessibility_reports_lookup_idx
  on public.accessibility_reports (place_key, disability_type);
```

> Los datos oficiales (`source = 'once'`) se cargan desde el panel de Supabase
> (rol service_role), que **omite** las políticas RLS. Por eso la política de
> inserción de usuarios solo permite `source = 'community'`.

---

## 2. El campo clave: `place_key`

La app busca cada lugar por un identificador **estable** que genera así:

```
place_key = "<nombre en minúsculas y sin acentos> | <lat con 4 decimales> | <lon con 4 decimales>"
```

Ejemplo para el Museo del Prado (lat 40.4138, lon −3.6921):

```
museo nacional del prado|40.4138|-3.6921
```

⚠️ **Importante:** para que un dato sembrado "haga match" con lo que busca el usuario,
el `place_key` debe generarse igual. Como es fácil equivocarse a mano, lo más cómodo es:

> Pásame tu lista de sitios de la ONCE con **nombre + latitud + longitud** y yo te
> genero el CSV con los `place_key` ya calculados, listo para importar.

---

## 3. Formato del CSV a importar

Columnas: `place_key, place_name, latitude, longitude, disability_type, features, source`

- `disability_type`: normalmente `visual` para datos de la ONCE.
- `features`: un objeto JSON (entre comillas en el CSV) con los criterios de esa versión.
  Criterios de la versión **visual**: `Señalización en braille`, `Pavimento podotáctil`,
  `Audioguía`, `Admite perro guía`. Valores: `available`, `limited`, `unavailable`, `unknown`.
- `source`: `once`.

Ejemplo (`once_madrid.csv`):

```csv
place_key,place_name,latitude,longitude,disability_type,features,source
museo nacional del prado|40.4138|-3.6921,Museo Nacional del Prado,40.4138,-3.6921,visual,"{""Señalización en braille"":""available"",""Pavimento podotáctil"":""available"",""Audioguía"":""available"",""Admite perro guía"":""available""}",once
estadio santiago bernabeu|40.4531|-3.6883,Estadio Santiago Bernabéu,40.4531,-3.6883,visual,"{""Audioguía"":""available"",""Admite perro guía"":""available""}",once
```

(En CSV, las comillas dobles dentro de un campo se escriben duplicadas `""`.)

---

## 4. Importar el CSV

Supabase → **Table Editor** → tabla `accessibility_reports` → botón **Insert → Import data from CSV**
→ sube el archivo → comprueba que `features` se reconoce como JSON → **Import**.

Tras importar, abre la app en versión **Visual**, busca uno de esos sitios y verás los
datos con la etiqueta *"Basado en datos de Fundación ONCE"*.

---

## 5. Verificación rápida (SQL)

```sql
select place_name, disability_type, source, features
from public.accessibility_reports
where source = 'once'
order by created_at desc;
```
