-- LOT 2B : immutabilité des fichiers + validation humaine + état global d'onboarding

-- ============================================================
-- 1. STORAGE : un fichier déposé devient immuable
-- ============================================================
DROP POLICY IF EXISTS "driver updates own documents" ON storage.objects;

-- Le Superadmin peut consulter les pièces (lien signé temporaire, jamais d'URL publique).
CREATE POLICY "superadmin reads driver documents"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'driver-documents' AND public.has_role(auth.uid(), 'super_admin'));

-- ============================================================
-- 2. État d'onboarding : nomenclature étendue sur la colonne existante
-- ============================================================
ALTER TABLE public.drivers DROP CONSTRAINT drivers_onboarding_status_check;
ALTER TABLE public.drivers ADD CONSTRAINT drivers_onboarding_status_check CHECK (
  onboarding_status = ANY (ARRAY[
    'legacy','draft','submitted','under_review','approved','rejected','expired',
    'pending_review','correction_required','document_expired'
  ])
);

-- Calcul déterministe, sans effet de bord. Seule la version courante compte.
CREATE OR REPLACE FUNCTION public.compute_driver_onboarding_state(_driver_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_types text[] := ARRAY['identity_document','driver_photo','driving_license','registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo'];
  v_vehicle public.vehicles;
  v_expired int; v_correction int; v_approved int;
BEGIN
  SELECT * INTO v_vehicle FROM public.vehicles
   WHERE driver_id = _driver_id AND is_active AND deleted_at IS NULL;

  SELECT
    count(*) FILTER (WHERE public.document_effective_status(d.status, d.expires_on) = 'expired'),
    count(*) FILTER (WHERE d.status = 'rejected'),
    count(*) FILTER (WHERE public.document_effective_status(d.status, d.expires_on) = 'approved')
    INTO v_expired, v_correction, v_approved
  FROM unnest(v_types) AS t(doc_type)
  JOIN public.driver_documents d
    ON d.doc_type = t.doc_type AND d.driver_id = _driver_id AND d.is_current
   AND (d.vehicle_id IS NULL OR d.vehicle_id = v_vehicle.id);

  IF v_expired > 0 THEN RETURN 'document_expired'; END IF;
  IF v_correction > 0 OR v_vehicle.validation_status = 'rejected' THEN RETURN 'correction_required'; END IF;
  IF v_vehicle.id IS NOT NULL
     AND v_vehicle.validation_status = 'approved'
     AND v_approved = array_length(v_types, 1)
     AND v_vehicle.registered_seats IS NOT NULL
     AND v_vehicle.passenger_capacity = v_vehicle.registered_seats - 1
  THEN RETURN 'approved'; END IF;
  RETURN 'pending_review';
END $$;

-- Écrit l'état calculé. Les décisions administratives ne sont jamais écrasées.
CREATE OR REPLACE FUNCTION public.refresh_driver_onboarding_status(_driver_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_driver public.drivers; v_state text;
BEGIN
  SELECT * INTO v_driver FROM public.drivers WHERE user_id = _driver_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_state := public.compute_driver_onboarding_state(_driver_id);
  -- 'rejected' (décision administrative) et un chauffeur suspendu restent intacts.
  IF v_driver.onboarding_status = 'rejected' OR v_driver.status = 'suspended' THEN
    RETURN v_driver.onboarding_status;
  END IF;
  UPDATE public.drivers SET onboarding_status = v_state WHERE user_id = _driver_id;
  RETURN v_state;
END $$;

REVOKE ALL ON FUNCTION public.compute_driver_onboarding_state(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_driver_onboarding_status(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_driver_onboarding_state(uuid), public.refresh_driver_onboarding_status(uuid) TO service_role;

-- ============================================================
-- 3. register_my_document : l'objet Storage réel fait foi
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
  v_obj record;
  v_mime text; v_size integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = v_uid) THEN RAISE EXCEPTION 'NOT_A_DRIVER'; END IF;

  IF _doc_type NOT IN ('identity_document','driver_photo','driving_license',
                       'registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo') THEN
    RAISE EXCEPTION 'INVALID_DOC_TYPE';
  END IF;
  v_vehicle_scope := _doc_type IN ('registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo');

  IF _storage_path IS NULL OR _storage_path NOT LIKE v_uid::text || '/%' THEN
    RAISE EXCEPTION 'INVALID_STORAGE_PATH';
  END IF;
  IF EXISTS (SELECT 1 FROM public.driver_documents WHERE storage_path = _storage_path) THEN
    RAISE EXCEPTION 'STORAGE_PATH_ALREADY_REGISTERED';
  END IF;

  -- Le fichier doit réellement exister dans le bucket privé ; ses métadonnées font foi.
  SELECT o.metadata INTO v_obj
    FROM storage.objects o
   WHERE o.bucket_id = 'driver-documents' AND o.name = _storage_path;
  IF NOT FOUND THEN RAISE EXCEPTION 'STORAGE_OBJECT_NOT_FOUND'; END IF;

  v_mime := COALESCE(v_obj.metadata->>'mimetype', _mime_type);
  v_size := COALESCE((v_obj.metadata->>'size')::integer, _size_bytes);

  IF v_mime IS NULL OR v_mime NOT IN ('image/jpeg','image/png','image/webp','application/pdf') THEN
    RAISE EXCEPTION 'INVALID_MIME_TYPE';
  END IF;
  IF v_size IS NULL OR v_size <= 0 OR v_size > 8388608 THEN
    RAISE EXCEPTION 'INVALID_FILE_SIZE';
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
  VALUES (v_uid, _vehicle_id, _doc_type, _storage_path, v_mime, v_size, _sha256,
    _issued_on, _expires_on, 'submitted', COALESCE(v_prev.version, 0) + 1, v_prev.id, true, v_uid)
  RETURNING * INTO v_new;

  PERFORM public.log_audit_event(
    'driver_document_version_created', 'driver_document', v_new.id::text, 'driver', v_uid, 'rpc',
    jsonb_build_object('doc_type', v_new.doc_type, 'version', v_new.version, 'vehicle_id', v_new.vehicle_id,
                       'supersedes_id', v_new.supersedes_id, 'status', v_new.status, 'expires_on', v_new.expires_on));

  PERFORM public.refresh_driver_onboarding_status(v_uid);

  RETURN jsonb_build_object('document_id', v_new.id, 'doc_type', v_new.doc_type, 'version', v_new.version,
    'status', v_new.status, 'supersedes_id', v_new.supersedes_id, 'mime_type', v_new.mime_type, 'size_bytes', v_new.size_bytes);
END $$;

REVOKE ALL ON FUNCTION public.register_my_document(text,text,text,integer,uuid,date,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_my_document(text,text,text,integer,uuid,date,date,text) TO authenticated, service_role;

-- ============================================================
-- 4. upsert_my_vehicle : recalcul de l'état après modification
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
      -- Une donnée d'identification modifiée ramène le véhicule en attente de validation.
      validation_status = CASE WHEN v_major AND validation_status IN ('approved','rejected') THEN 'pending' ELSE validation_status END,
      validated_by = CASE WHEN v_major THEN NULL ELSE validated_by END,
      validated_at = CASE WHEN v_major THEN NULL ELSE validated_at END
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

  PERFORM public.refresh_driver_onboarding_status(v_uid);

  RETURN jsonb_build_object('id', v_new.id, 'plate', v_new.plate, 'plate_normalized', v_new.plate_normalized,
    'registered_seats', v_new.registered_seats, 'passenger_capacity', v_new.passenger_capacity,
    'is_active', v_new.is_active, 'validation_status', v_new.validation_status);
END $$;

REVOKE ALL ON FUNCTION public.upsert_my_vehicle(uuid,text,text,text,text,boolean,smallint,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_my_vehicle(uuid,text,text,text,text,boolean,smallint,boolean) TO authenticated, service_role;

-- ============================================================
-- 5. get_my_driver_onboarding : ajoute l'état global et le motif de correction
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
               SELECT c.anomalies->>'reason' FROM public.driver_document_checks c
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
    'global_state', public.compute_driver_onboarding_state(v_uid),
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
-- 6. Validation humaine d'un document (Superadmin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.review_driver_document(
  _document_id uuid, _decision text, _reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc public.driver_documents;
  v_status text; v_result text; v_check text; v_state text;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF _decision NOT IN ('approve','request_correction') THEN RAISE EXCEPTION 'INVALID_DECISION'; END IF;
  IF _decision = 'request_correction' AND (_reason IS NULL OR btrim(_reason) = '') THEN
    RAISE EXCEPTION 'REASON_REQUIRED';
  END IF;

  SELECT * INTO v_doc FROM public.driver_documents WHERE id = _document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENT_NOT_FOUND'; END IF;
  IF NOT v_doc.is_current THEN RAISE EXCEPTION 'DOCUMENT_NOT_CURRENT'; END IF;

  IF _decision = 'approve' THEN
    v_status := 'approved'; v_result := 'pass'; v_check := 'approve';
  ELSE
    v_status := 'rejected'; v_result := 'needs_review'; v_check := 'request_resubmission';
  END IF;

  -- Journal des contrôles : append-only, jamais écrasé.
  INSERT INTO public.driver_document_checks(document_id, method, reviewer_id, result, decision, extracted_data, anomalies)
  VALUES (_document_id, 'human', v_uid, v_result, v_check, '{}'::jsonb,
          CASE WHEN _reason IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('reason', btrim(_reason)) END);

  UPDATE public.driver_documents SET status = v_status WHERE id = _document_id;

  PERFORM public.log_audit_event(
    CASE WHEN _decision = 'approve' THEN 'document_approved' ELSE 'document_correction_requested' END,
    'driver_document', _document_id::text, 'admin', v_uid, 'rpc',
    jsonb_build_object('doc_type', v_doc.doc_type, 'version', v_doc.version, 'driver_id', v_doc.driver_id,
                       'decision', _decision, 'reason', CASE WHEN _reason IS NULL THEN NULL ELSE btrim(_reason) END));

  v_state := public.refresh_driver_onboarding_status(v_doc.driver_id);
  RETURN jsonb_build_object('document_id', _document_id, 'status', v_status, 'onboarding_state', v_state);
END $$;

REVOKE ALL ON FUNCTION public.review_driver_document(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_driver_document(uuid,text,text) TO authenticated, service_role;

-- ============================================================
-- 7. Validation humaine du véhicule (Superadmin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.review_driver_vehicle(
  _vehicle_id uuid, _decision text, _reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid(); v_veh public.vehicles; v_status text; v_state text;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF _decision NOT IN ('approve','request_correction') THEN RAISE EXCEPTION 'INVALID_DECISION'; END IF;
  IF _decision = 'request_correction' AND (_reason IS NULL OR btrim(_reason) = '') THEN
    RAISE EXCEPTION 'REASON_REQUIRED';
  END IF;

  SELECT * INTO v_veh FROM public.vehicles WHERE id = _vehicle_id AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;

  IF _decision = 'approve' THEN
    IF v_veh.plate IS NULL OR btrim(v_veh.plate) = '' THEN RAISE EXCEPTION 'VEHICLE_PLATE_MISSING'; END IF;
    IF v_veh.model IS NULL OR btrim(v_veh.model) = '' THEN RAISE EXCEPTION 'VEHICLE_MODEL_MISSING'; END IF;
    IF v_veh.registered_seats IS NULL THEN RAISE EXCEPTION 'VEHICLE_SEATS_MISSING'; END IF;
    IF v_veh.passenger_capacity IS DISTINCT FROM (v_veh.registered_seats - 1) THEN RAISE EXCEPTION 'VEHICLE_CAPACITY_INCONSISTENT'; END IF;
    v_status := 'approved';
  ELSE
    v_status := 'rejected';
  END IF;

  UPDATE public.vehicles
     SET validation_status = v_status,
         validated_by = CASE WHEN v_status = 'approved' THEN v_uid ELSE NULL END,
         validated_at = CASE WHEN v_status = 'approved' THEN now() ELSE NULL END
   WHERE id = _vehicle_id;

  PERFORM public.log_audit_event(
    CASE WHEN _decision = 'approve' THEN 'vehicle_approved' ELSE 'vehicle_correction_requested' END,
    'vehicle', _vehicle_id::text, 'admin', v_uid, 'rpc',
    jsonb_build_object('driver_id', v_veh.driver_id, 'decision', _decision,
                       'registered_seats', v_veh.registered_seats, 'passenger_capacity', v_veh.passenger_capacity,
                       'reason', CASE WHEN _reason IS NULL THEN NULL ELSE btrim(_reason) END));

  v_state := public.refresh_driver_onboarding_status(v_veh.driver_id);
  RETURN jsonb_build_object('vehicle_id', _vehicle_id, 'validation_status', v_status, 'onboarding_state', v_state);
END $$;

REVOKE ALL ON FUNCTION public.review_driver_vehicle(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_driver_vehicle(uuid,text,text) TO authenticated, service_role;

-- ============================================================
-- 8. Back-Office : liste des dossiers + fiche détaillée (Superadmin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_list_driver_dossiers()
RETURNS TABLE(
  driver_id uuid, first_name text, last_name text, driver_status text,
  onboarding_status text, global_state text,
  vehicle_id uuid, vehicle_label text, vehicle_plate text, vehicle_validation text,
  registered_seats smallint, passenger_capacity smallint,
  approved_docs int, pending_docs int, correction_docs int, expired_docs int, is_demo boolean
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.user_id, d.first_name, d.last_name, d.status,
         d.onboarding_status, public.compute_driver_onboarding_state(d.user_id),
         v.id, COALESCE(v.make || ' ' || v.model, v.model), v.plate, v.validation_status,
         v.registered_seats, v.passenger_capacity,
         COALESCE(s.approved,0), COALESCE(s.pending,0), COALESCE(s.correction,0), COALESCE(s.expired,0), d.is_demo
    FROM public.drivers d
    LEFT JOIN public.vehicles v ON v.driver_id = d.user_id AND v.is_active AND v.deleted_at IS NULL
    LEFT JOIN LATERAL (
      SELECT count(*) FILTER (WHERE public.document_effective_status(x.status, x.expires_on) = 'approved')::int AS approved,
             count(*) FILTER (WHERE x.status = 'submitted')::int AS pending,
             count(*) FILTER (WHERE x.status = 'rejected')::int AS correction,
             count(*) FILTER (WHERE public.document_effective_status(x.status, x.expires_on) = 'expired')::int AS expired
        FROM public.driver_documents x
       WHERE x.driver_id = d.user_id AND x.is_current
    ) s ON true
   WHERE d.deleted_at IS NULL
     AND public.has_role(auth.uid(), 'super_admin')
   ORDER BY d.created_at DESC
$$;

CREATE OR REPLACE FUNCTION public.admin_get_driver_dossier(_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid(); v_driver public.drivers; v_vehicle public.vehicles; v_docs jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO v_driver FROM public.drivers WHERE user_id = _driver_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRIVER_NOT_FOUND'; END IF;
  SELECT * INTO v_vehicle FROM public.vehicles WHERE driver_id = _driver_id AND is_active AND deleted_at IS NULL;

  SELECT jsonb_agg(jsonb_build_object(
           'document_id', d.id, 'doc_type', d.doc_type, 'version', d.version, 'is_current', d.is_current,
           'status', public.document_effective_status(d.status, d.expires_on),
           'raw_status', d.status, 'expires_on', d.expires_on, 'issued_on', d.issued_on,
           'mime_type', d.mime_type, 'size_bytes', d.size_bytes, 'created_at', d.created_at,
           'checks', COALESCE((
              SELECT jsonb_agg(jsonb_build_object(
                       'method', c.method, 'result', c.result, 'decision', c.decision,
                       'reason', c.anomalies->>'reason', 'created_at', c.created_at) ORDER BY c.created_at DESC)
                FROM public.driver_document_checks c WHERE c.document_id = d.id), '[]'::jsonb)
         ) ORDER BY d.doc_type, d.version DESC)
    INTO v_docs
    FROM public.driver_documents d
   WHERE d.driver_id = _driver_id;

  RETURN jsonb_build_object(
    'driver', jsonb_build_object('user_id', v_driver.user_id, 'first_name', v_driver.first_name,
       'last_name', v_driver.last_name, 'status', v_driver.status,
       'onboarding_status', v_driver.onboarding_status, 'is_demo', v_driver.is_demo),
    'global_state', public.compute_driver_onboarding_state(_driver_id),
    'vehicle', CASE WHEN v_vehicle.id IS NULL THEN NULL ELSE jsonb_build_object(
       'id', v_vehicle.id, 'make', v_vehicle.make, 'model', v_vehicle.model, 'color', v_vehicle.color,
       'plate', v_vehicle.plate, 'has_ac', v_vehicle.has_ac, 'registered_seats', v_vehicle.registered_seats,
       'passenger_capacity', v_vehicle.passenger_capacity, 'validation_status', v_vehicle.validation_status,
       'validated_at', v_vehicle.validated_at) END,
    'documents', COALESCE(v_docs, '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION public.admin_list_driver_dossiers() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_get_driver_dossier(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_driver_dossiers(), public.admin_get_driver_dossier(uuid) TO authenticated, service_role;