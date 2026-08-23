-- Elimina políticas duplicadas en help_requests que anulaban la granularidad
-- de las más nuevas mediante OR-logic PERMISSIVE.
-- Aplicada manualmente el 2026-08-23 (audit session #2).

DROP POLICY IF EXISTS crear_propias    ON public.help_requests;  -- duplicado de insert_own
DROP POLICY IF EXISTS borrar_implicados ON public.help_requests; -- duplicado de delete_own_or_helper
