-- LOT 2A : stockage privé + backend onboarding Chauffeur (aucun écran, aucune IA, aucun blocage)

-- ============================================================
-- 1. Référentiel documentaire : ajout de identity_document (8e type, portée Chauffeur)
-- ============================================================
ALTER TABLE public.driver_documents DROP CONSTRAINT driver_documents_doc_type_check;
ALTER TABLE public.driver_documents DROP CONSTRAINT driver_documents_scope_check;

ALTER TABLE public.driver_documents
  ADD CONSTRAINT driver_documents_doc_type_check CHECK (doc_type IN (
    'identity_document','driver_photo','driving_license',
    'registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo'
  )),
  ADD CONSTRAINT driver_documents_scope_check CHECK (
    (doc_type IN ('identity_document','driving_license','driver_photo') AND vehicle_id IS NULL)
    OR (doc_type IN ('registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo') AND vehicle_id IS NOT NULL)
  );

COMMENT ON COLUMN public.driver_documents.status IS 'submitted = pending_review ; rejected = correction_required ; approved ; expired ; superseded (ancienne version).';

-- ============================================================
-- 2. Helpers
-- ============================================================
CREATE OR REPLACE FUNCTION public.libreville_today()
RETURNS date LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT (now() AT TIME ZONE 'Africa/Libreville')::date
$$;

-- Lecture seule : un document approuvé dont l'échéance est passée est considéré expiré.
-- Aucune ligne n'est modifiée par le simple passage du temps.
CREATE OR REPLACE FUNCTION public.document_effective_status(_status text, _expires_on date)
RETURNS text LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT CASE
    WHEN _status = 'approved' AND _expires_on IS NOT NULL AND _expires_on < public.libreville_today() THEN 'expired'
    ELSE _status
  END
$$;

CREATE OR REPLACE FUNCTION public.doc_type_requires_expiry(_doc_type text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT _doc_type IN ('driving_license','insurance','technical_inspection')
$$;

-- Journalisation interne (audit_events) sans secret ni PII.
CREATE OR REPLACE FUNCTION public.log_audit_event(
  _event_type text, _entity_type text, _entity_id text,
  _actor_type text, _actor_id uuid, _source text, _metadata jsonb DEFAULT '{}'::jsonb
) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, metadata)
  VALUES (_event_type, _entity_type, _entity_id, _actor_type, _actor_id, _source, COALESCE(_metadata,'{}'::jsonb));
$$;

REVOKE ALL ON FUNCTION public.log_audit_event(text,text,text,text,uuid,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_audit_event(text,text,text,text,uuid,text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.libreville_today() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.document_effective_status(text,date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.doc_type_requires_expiry(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.libreville_today(), public.document_effective_status(text,date), public.doc_type_requires_expiry(text) TO authenticated, service_role;

-- ============================================================
-- 3. Storage : bucket privé driver-documents, cloisonné par Chauffeur
--    Chemin imposé : <driver_id>/<document_id>/<filename>
-- ============================================================
CREATE POLICY "driver reads own documents"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'driver-documents' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "driver uploads own documents"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'driver-documents'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND array_length(storage.foldername(name), 1) = 2
  AND name ~* '\.(jpe?g|png|webp|pdf)$'
  AND EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = auth.uid())
);

CREATE POLICY "driver updates own documents"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'driver-documents' AND (storage.foldername(name))[1] = auth.uid()::text)
WITH CHECK (
  bucket_id = 'driver-documents'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND name ~* '\.(jpe?g|png|webp|pdf)$'
);

-- ============================================================
-- 4. RPC Chauffeur : lecture de SON onboarding
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_driver_onboarding()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_driver public.drivers;
  v_vehicle public.vehicles;
  v_docs jsonb;
  v_types text[] := ARRAY['identity_document','driver_photo','driving_license','registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo'];
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  SELECT * INTO v_driver FROM public.drivers WHERE user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_A_DRIVER'; END IF;

  SELECT * INTO v_vehicle FROM public.vehicles
   WHERE driver_id = v_uid AND is_active AND deleted_at IS NULL;

  SELECT jsonb_agg(jsonb_build_object(
           'doc_type', t.doc_type,
           'scope', CASE WHEN t.doc_type IN ('identity_document','driver_photo','driving_license') THEN 'driver' ELSE 'vehicle' END,
           'required_expiry', public.doc_type_requires_expiry(t.doc_type),
           'present', d.id IS NOT NULL,
           'document_id', d.id,
           'status', CASE WHEN d.id IS NULL THEN NULL ELSE public.document_effective_status(d.status, d.expires_on) END,
           'expires_on', d.expires_on,
           'version', d.version,
           'submitted_at', d.created_at,
           'correction_reason', CASE WHEN d.status = 'rejected' THEN (
               SELECT c.anomalies FROM public.driver_document_checks c
                WHERE c.document_id = d.id AND c.method = 'human'
                ORDER BY c.created_at DESC LIMIT 1) ELSE NULL END
         ) ORDER BY t.ord)
    INTO v_docs
  FROM unnest(v_types) WITH ORDINALITY AS t(doc_type, ord)
  LEFT JOIN public.driver_documents d
    ON d.doc_type = t.doc_type AND d.driver_id = v_uid AND d.is_current
   AND (d.vehicle_id IS NULL OR d.vehicle_id = v_vehicle.id);

  RETURN jsonb_build_object(
    'driver', jsonb_build_object(
       'onboarding_status', v_driver.onboarding_status,
       'status', v_driver.status,
       'first_name', v_driver.first_name,
       'last_name', v_driver.last_name
    ),
    'active_vehicle', CASE WHEN v_vehicle.id IS NULL THEN NULL ELSE jsonb_build_object(
       'id', v_vehicle.id, 'make', v_vehicle.make, 'model', v_vehicle.model, 'color', v_vehicle.color,
       'plate', v_vehicle.plate, 'has_ac', v_vehicle.has_ac,
       'registered_seats', v_vehicle.registered_seats, 'passenger_capacity', v_vehicle.passenger_capacity,
       'validation_status', v_vehicle.validation_status
    ) END,
    'documents', COALESCE(v_docs, '[]'::jsonb),
    'summary', jsonb_build_object(
       'total_required', array_length(v_types,1),
       'approved', (SELECT count(*) FROM jsonb_array_elements(COALESCE(v_docs,'[]'::jsonb)) e WHERE e->>'status' = 'approved'),
       'missing',  (SELECT count(*) FROM jsonb_array_elements(COALESCE(v_docs,'[]'::jsonb)) e WHERE (e->>'present')::boolean = false)
    )
  );
END $$;

REVOKE ALL ON FUNCTION public.get_my_driver_onboarding() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_driver_onboarding() TO authenticated, service_role;

-- ============================================================
-- 5. RPC Chauffeur : créer / modifier SON véhicule
-- ============================================================
CREATE OR REPLACE FUNCTION public.upsert_my_vehicle(
  _vehicle_id uuid DEFAULT NULL,
  _make text DEFAULT NULL,
  _model text DEFAULT NULL,
  _color text DEFAULT NULL,
  _plate text DEFAULT NULL,
  _has_ac boolean DEFAULT NULL,
  _registered_seats smallint DEFAULT NULL,
  _set_active boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old public.vehicles;
  v_new public.vehicles;
  v_major boolean := false;
  v_event text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = v_uid) THEN RAISE EXCEPTION 'NOT_A_DRIVER'; END IF;
  IF _registered_seats IS NOT NULL AND _registered_seats < 2 THEN RAISE EXCEPTION 'INVALID_REGISTERED_SEATS'; END IF;

  IF _vehicle_id IS NULL THEN
    IF _model IS NULL OR btrim(_model) = '' OR _plate IS NULL OR btrim(_plate) = '' THEN
      RAISE EXCEPTION 'VEHICLE_MODEL_AND_PLATE_REQUIRED';
    END IF;
    INSERT INTO public.vehicles(driver_id, make, model, color, plate, has_ac, registered_seats, is_active)
    VALUES (v_uid, _make, btrim(_model), _color, btrim(_plate), COALESCE(_has_ac,false), _registered_seats, false)
    RETURNING * INTO v_new;
    v_event := 'driver_vehicle_created';
  ELSE
    SELECT * INTO v_old FROM public.vehicles WHERE id = _vehicle_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;
    IF v_old.driver_id <> v_uid THEN RAISE EXCEPTION 'VEHICLE_NOT_OWNED'; END IF;

    v_major := (_plate IS NOT NULL AND public.normalize_plate(btrim(_plate)) IS DISTINCT FROM v_old.plate_normalized)
            OR (_registered_seats IS NOT NULL AND _registered_seats IS DISTINCT FROM v_old.registered_seats)
            OR (_model IS NOT NULL AND btrim(_model) IS DISTINCT FROM v_old.model)
            OR (_make IS NOT NULL AND _make IS DISTINCT FROM v_old.make);

    UPDATE public.vehicles SET
      make = COALESCE(_make, make),
      model = COALESCE(btrim(_model), model),
      color = COALESCE(_color, color),
      plate = COALESCE(btrim(_plate), plate),
      has_ac = COALESCE(_has_ac, has_ac),
      registered_seats = COALESCE(_registered_seats, registered_seats),
      -- une donnée d'identification modifiée prépare une revalidation, sans bloquer le Chauffeur
      validation_status = CASE WHEN v_major AND validation_status = 'approved' THEN 'pending' ELSE validation_status END,
      validated_by = CASE WHEN v_major AND validation_status = 'approved' THEN NULL ELSE validated_by END,
      validated_at = CASE WHEN v_major AND validation_status = 'approved' THEN NULL ELSE validated_at END
    WHERE id = _vehicle_id
    RETURNING * INTO v_new;
    v_event := 'driver_vehicle_updated';
  END IF;

  IF COALESCE(_set_active, false) THEN
    UPDATE public.vehicles SET is_active = false
     WHERE driver_id = v_uid AND id <> v_new.id AND is_active AND deleted_at IS NULL;
    UPDATE public.vehicles SET is_active = true WHERE id = v_new.id RETURNING * INTO v_new;
    UPDATE public.drivers SET active_vehicle_id = v_new.id WHERE user_id = v_uid;
  END IF;

  -- Compatibilité legacy : la fiche Chauffeur affichée reste alignée sur le véhicule actif.
  IF v_new.is_active THEN
    UPDATE public.drivers
       SET vehicle_model = v_new.model, vehicle_plate = v_new.plate, has_ac = v_new.has_ac
     WHERE user_id = v_uid;
  END IF;

  PERFORM public.log_audit_event(
    v_event, 'vehicle', v_new.id::text, 'driver', v_uid, 'rpc',
    jsonb_build_object('is_active', v_new.is_active, 'registered_seats', v_new.registered_seats,
                       'passenger_capacity', v_new.passenger_capacity, 'major_change', v_major,
                       'validation_status', v_new.validation_status));

  RETURN jsonb_build_object('id', v_new.id, 'plate', v_new.plate, 'plate_normalized', v_new.plate_normalized,
    'registered_seats', v_new.registered_seats, 'passenger_capacity', v_new.passenger_capacity,
    'is_active', v_new.is_active, 'validation_status', v_new.validation_status);
END $$;

REVOKE ALL ON FUNCTION public.upsert_my_vehicle(uuid,text,text,text,text,boolean,smallint,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_my_vehicle(uuid,text,text,text,text,boolean,smallint,boolean) TO authenticated, service_role;

-- ============================================================
-- 6. RPC Chauffeur : enregistrer une pièce après upload (nouvelle version)
-- ============================================================
CREATE OR REPLACE FUNCTION public.register_my_document(
  _doc_type text,
  _storage_path text,
  _mime_type text,
  _size_bytes integer,
  _vehicle_id uuid DEFAULT NULL,
  _issued_on date DEFAULT NULL,
  _expires_on date DEFAULT NULL,
  _sha256 text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_prev public.driver_documents;
  v_new public.driver_documents;
  v_vehicle_scope boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = v_uid) THEN RAISE EXCEPTION 'NOT_A_DRIVER'; END IF;

  IF _doc_type NOT IN ('identity_document','driver_photo','driving_license',
                       'registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo') THEN
    RAISE EXCEPTION 'INVALID_DOC_TYPE';
  END IF;
  v_vehicle_scope := _doc_type IN ('registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo');

  IF _mime_type IS NULL OR _mime_type NOT IN ('image/jpeg','image/png','image/webp','application/pdf') THEN
    RAISE EXCEPTION 'INVALID_MIME_TYPE';
  END IF;
  IF _size_bytes IS NULL OR _size_bytes <= 0 OR _size_bytes > 8388608 THEN
    RAISE EXCEPTION 'INVALID_FILE_SIZE';
  END IF;
  IF _storage_path IS NULL OR _storage_path NOT LIKE v_uid::text || '/%' THEN
    RAISE EXCEPTION 'INVALID_STORAGE_PATH';
  END IF;
  IF public.doc_type_requires_expiry(_doc_type) AND _expires_on IS NULL THEN
    RAISE EXCEPTION 'EXPIRY_DATE_REQUIRED';
  END IF;

  IF v_vehicle_scope THEN
    IF _vehicle_id IS NULL THEN RAISE EXCEPTION 'VEHICLE_REQUIRED_FOR_DOC_TYPE'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.vehicles WHERE id = _vehicle_id AND driver_id = v_uid AND deleted_at IS NULL) THEN
      RAISE EXCEPTION 'VEHICLE_NOT_OWNED';
    END IF;
  ELSE
    _vehicle_id := NULL;
  END IF;

  SELECT * INTO v_prev FROM public.driver_documents
   WHERE driver_id = v_uid AND doc_type = _doc_type AND is_current
     AND _vehicle_id IS NOT DISTINCT FROM vehicle_id
   FOR UPDATE;

  IF FOUND THEN
    UPDATE public.driver_documents SET is_current = false, status = 'superseded' WHERE id = v_prev.id;
  END IF;

  INSERT INTO public.driver_documents(
    driver_id, vehicle_id, doc_type, storage_path, mime_type, size_bytes, sha256,
    issued_on, expires_on, status, version, supersedes_id, is_current, uploaded_by)
  VALUES (v_uid, _vehicle_id, _doc_type, _storage_path, _mime_type, _size_bytes, _sha256,
    _issued_on, _expires_on, 'submitted', COALESCE(v_prev.version, 0) + 1, v_prev.id, true, v_uid)
  RETURNING * INTO v_new;

  PERFORM public.log_audit_event(
    'driver_document_version_created', 'driver_document', v_new.id::text, 'driver', v_uid, 'rpc',
    jsonb_build_object('doc_type', v_new.doc_type, 'version', v_new.version, 'vehicle_id', v_new.vehicle_id,
                       'supersedes_id', v_new.supersedes_id, 'status', v_new.status, 'expires_on', v_new.expires_on));

  RETURN jsonb_build_object('document_id', v_new.id, 'doc_type', v_new.doc_type, 'version', v_new.version,
    'status', v_new.status, 'supersedes_id', v_new.supersedes_id);
END $$;

REVOKE ALL ON FUNCTION public.register_my_document(text,text,text,integer,uuid,date,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_my_document(text,text,text,integer,uuid,date,date,text) TO authenticated, service_role;

-- ============================================================
-- 7. Consultation Back-Office : référence de stockage uniquement (URL signée côté serveur, jamais stockée)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_document_storage_ref(_document_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_doc public.driver_documents;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO v_doc FROM public.driver_documents WHERE id = _document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENT_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('bucket', v_doc.storage_bucket, 'path', v_doc.storage_path,
    'mime_type', v_doc.mime_type, 'doc_type', v_doc.doc_type, 'driver_id', v_doc.driver_id);
END $$;

REVOKE ALL ON FUNCTION public.get_document_storage_ref(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_document_storage_ref(uuid) TO authenticated, service_role;