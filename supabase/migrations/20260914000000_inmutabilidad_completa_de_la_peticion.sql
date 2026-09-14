-- Audit 2026-09-14, hallazgo 2: peticion_inmutable() solo protegía requester_id,
-- disability_type, area_latitude y area_longitude. Un ayudante ya asignado
-- (helper_id = auth.uid(), permitido por la política update_own_or_helper)
-- podía sobrescribir place_name, requester_pubkey y anular requester_payload
-- sin que el trigger lo impidiera. Verificado explotable en una transacción
-- revertida antes de este fix.
--
-- requester_payload sigue siendo escribible, pero solo por quien pide (lo
-- manda tras que el ayudante acepta, por el canal cifrado) — se bloquea que
-- lo toque cualquier otra identidad, incluido el propio ayudante.
create or replace function public.peticion_inmutable()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
    if new.requester_id    is distinct from old.requester_id
    or new.disability_type is distinct from old.disability_type
    or new.area_latitude   is distinct from old.area_latitude
    or new.area_longitude  is distinct from old.area_longitude
    or new.requester_pubkey is distinct from old.requester_pubkey
    or new.place_name      is distinct from old.place_name then
        raise exception 'Estos campos de la petición no se pueden cambiar'
            using errcode = 'insufficient_privilege';
    end if;

    if new.requester_payload is distinct from old.requester_payload
       and auth.uid() is distinct from old.requester_id then
        raise exception 'Solo el solicitante puede actualizar requester_payload'
            using errcode = 'insufficient_privilege';
    end if;

    return new;
end;
$function$;
