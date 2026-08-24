-- Audit #5 del 2026-08-24 — hallazgos preexistentes (no regresiones propias).

-- 4. HIGH: helper_ratings.leer_valoraciones exponía rater_id a cualquier
--    usuario autenticado (USING (true)). Permite identificar quién puso una
--    nota baja a un ayudante y facilita represalias.
--    Fix: restringir SELECT a las propias valoraciones + función agregada
--    para el caso de "ver nota media de un ayudante".
DROP POLICY IF EXISTS leer_valoraciones ON public.helper_ratings;
CREATE POLICY leer_valoraciones ON public.helper_ratings
    FOR SELECT TO authenticated
    USING (rater_id = auth.uid());

CREATE OR REPLACE FUNCTION public.helper_rating_summary(p_helper_id uuid)
RETURNS TABLE(avg numeric, count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT avg(rating)::numeric, count(*)
    FROM public.helper_ratings
    WHERE helper_id = p_helper_id;
$$;
REVOKE ALL ON FUNCTION public.helper_rating_summary(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.helper_rating_summary(uuid) TO authenticated;

-- 3. HIGH: bucket helper-avatars sin límite de tamaño/MIME y sin nombre de
--    archivo canónico — cualquier usuario podía subir ficheros arbitrarios
--    de cualquier tamaño/tipo bajo su carpeta y servirlos con URL pública
--    de wheelp.app. Fix: límite 2MB, solo imágenes, un archivo por usuario.
UPDATE storage.buckets
SET file_size_limit = 2097152,
    allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp']
WHERE id = 'helper-avatars';

DROP POLICY IF EXISTS upload_own_avatar ON storage.objects;
CREATE POLICY upload_own_avatar ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'helper-avatars'
        AND name = (auth.uid())::text || '/avatar.jpg'
    );

DROP POLICY IF EXISTS update_own_avatar ON storage.objects;
CREATE POLICY update_own_avatar ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'helper-avatars'
        AND name = (auth.uid())::text || '/avatar.jpg'
    );

-- No existía política DELETE: el archivo sobrevivía indefinidamente al
-- borrar la cuenta. delete_own_account() borra la fila de helpers, pero
-- nunca el objeto de Storage.
DROP POLICY IF EXISTS delete_own_avatar ON storage.objects;
CREATE POLICY delete_own_avatar ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'helper-avatars'
        AND name = (auth.uid())::text || '/avatar.jpg'
    );

-- 12. LOW: helper_applications.phone se escribe y lee desde el cliente Swift
--    pero la columna no existe en la tabla — PostgREST rechaza el upsert con
--    error de schema cache. El formulario de solicitud de ayudante está roto.
ALTER TABLE public.helper_applications
    ADD COLUMN IF NOT EXISTS phone text;

ALTER TABLE public.helper_applications
    DROP CONSTRAINT IF EXISTS helper_applications_phone_format;
ALTER TABLE public.helper_applications
    ADD CONSTRAINT helper_applications_phone_format
    CHECK (phone IS NULL OR phone ~ '^[0-9+ ]{9,20}$');
