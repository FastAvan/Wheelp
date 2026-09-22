-- Audit 2026-09-21, F2 (mitad real): helper_applications conservaba para siempre
-- teléfono y referencia de verificación tras la decisión. Plazos = propuesta de
-- wheelp-legal, pendiente de validar por abogado.
create or replace function public.purgar_datos_caducados()
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
    delete from public.help_requests
     where status = 'pending'
       and coalesce(scheduled_at, created_at) < now() - interval '24 hours';

    delete from public.help_requests
     where status in ('completed', 'cancelled')
       and ended_at < now() - interval '7 days';

    update public.helpers
       set available = false,
           latitude = null, longitude = null, location = null,
           location_updated_at = null
     where available_until is not null
       and available_until < now() - interval '1 hour'
       and (location is not null or available);

    -- Rechazadas: 12 meses (defensa frente a reclamación), luego borrado.
    delete from public.helper_applications
     where status = 'rejected'
       and coalesce(kyc_checked_at, created_at) < now() - interval '12 months';

    -- Aprobadas: el teléfono solo servía al admin para revisar; se quita a los
    -- 30 días. Se conserva el hecho verificado y la referencia del proveedor.
    update public.helper_applications
       set phone = null
     where status = 'approved'
       and phone is not null
       and coalesce(kyc_checked_at, created_at) < now() - interval '30 days';
end;
$function$;
