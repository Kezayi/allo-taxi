CREATE OR REPLACE FUNCTION public.compute_driver_operational_eligibility(_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_types text[] := ARRAY['identity_document','driver_photo','driving_license','registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo'];
  v_driver public.drivers; v_vehicle public.vehicles;
  v_reasons text[] := ARRAY[]::text[];
  v_missing int; v_pending int; v_corr int; v_exp int; v_ok int;
BEGIN
  SELECT * INTO v_driver FROM public.drivers WHERE user_id = _driver_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('eligible', false, 'reasons', jsonb_build_array('DRIVER_NOT_FOUND'));
  END IF;
  IF v_driver.status = 'suspended' THEN v_reasons := array_append(v_reasons, 'DRIVER_SUSPENDED'); END IF;
  IF v_driver.onboarding_status = 'rejected' THEN v_reasons := array_append(v_reasons, 'DRIVER_REJECTED'); END IF;
  IF v_driver.status <> 'approved' OR NOT v_driver.is_active OR v_driver.deleted_at IS NOT NULL THEN
    v_reasons := array_append(v_reasons, 'DRIVER_NOT_APPROVED');
  END IF;
  SELECT * INTO v_vehicle FROM public.vehicles WHERE driver_id = _driver_id AND is_active AND deleted_at IS NULL;
  IF v_vehicle.id IS NULL OR v_vehicle.validation_status <> 'approved' THEN
    v_reasons := array_append(v_reasons, 'VEHICLE_NOT_APPROVED');
  END IF;
  IF v_vehicle.id IS NULL OR v_vehicle.registered_seats IS NULL
     OR v_vehicle.passenger_capacity IS DISTINCT FROM v_vehicle.registered_seats - 1
     OR v_vehicle.passenger_capacity < 1 THEN
    v_reasons := array_append(v_reasons, 'INVALID_CAPACITY');
  END IF;
  SELECT
    count(*) FILTER (WHERE d.id IS NULL),
    count(*) FILTER (WHERE d.status IN ('submitted','under_review')),
    count(*) FILTER (WHERE d.status = 'rejected'),
    count(*) FILTER (WHERE public.document_effective_status(d.status, d.expires_on) = 'expired'),
    count(*) FILTER (WHERE public.document_effective_status(d.status, d.expires_on) = 'approved')
    INTO v_missing, v_pending, v_corr, v_exp, v_ok
  FROM unnest(v_types) t(doc_type)
  LEFT JOIN public.driver_documents d
    ON d.doc_type = t.doc_type AND d.driver_id = _driver_id AND d.is_current
   AND (d.vehicle_id IS NULL OR d.vehicle_id = v_vehicle.id);
  IF v_missing > 0 THEN v_reasons := array_append(v_reasons, 'DOCUMENT_MISSING'); END IF;
  IF v_pending > 0 THEN v_reasons := array_append(v_reasons, 'DOCUMENT_PENDING'); END IF;
  IF v_corr > 0 THEN v_reasons := array_append(v_reasons, 'DOCUMENT_CORRECTION_REQUIRED'); END IF;
  IF v_exp > 0 THEN v_reasons := array_append(v_reasons, 'DOCUMENT_EXPIRED'); END IF;
  IF v_ok < array_length(v_types,1) AND cardinality(v_reasons) = 0 THEN
    v_reasons := array_append(v_reasons, 'DOCUMENT_PENDING');
  END IF;
  RETURN jsonb_build_object(
    'eligible', cardinality(v_reasons) = 0,
    'reasons', to_jsonb(v_reasons),
    'documents', jsonb_build_object('required', array_length(v_types,1), 'approved', v_ok,
       'missing', v_missing, 'pending', v_pending, 'correction', v_corr, 'expired', v_exp));
END $$;

CREATE OR REPLACE FUNCTION public.ai_complete_document_analysis(_document_id uuid, _model text, _result jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_doc public.driver_documents; v_vehicle public.vehicles; c public.onboarding_control;
  f jsonb := COALESCE(_result->'extracted_fields', '{}'::jsonb);
  v_conf numeric; v_issues jsonb := COALESCE(_result->'inconsistencies', '[]'::jsonb);
  v_srv text[] := ARRAY[]::text[]; v_ok boolean; v_exp date; v_auto boolean := false; v_state text;
BEGIN
  SELECT * INTO v_doc FROM public.driver_documents WHERE id = _document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENT_NOT_FOUND'; END IF;
  SELECT * INTO v_vehicle FROM public.vehicles WHERE id = v_doc.vehicle_id;
  SELECT * INTO c FROM public.onboarding_control WHERE id;
  v_conf := LEAST(1, GREATEST(0, COALESCE((_result->>'overall_confidence')::numeric, 0)));
  BEGIN v_exp := NULLIF(f->>'expiry_date','')::date; EXCEPTION WHEN others THEN v_exp := NULL; v_srv := array_append(v_srv, 'expiry_unparseable'); END;
  IF COALESCE(_result->>'document_type','') <> v_doc.doc_type THEN v_srv := array_append(v_srv, 'document_type_mismatch'); END IF;
  IF NOT COALESCE((_result->>'readable')::boolean, false) THEN v_srv := array_append(v_srv, 'unreadable'); END IF;
  IF v_doc.doc_type IN ('registration_card','insurance','technical_inspection','vehicle_plate_photo') THEN
    IF f->>'plate' IS NULL THEN v_srv := array_append(v_srv, 'plate_unreadable');
    ELSIF v_vehicle.plate IS NULL OR public.normalize_plate(f->>'plate') <> public.normalize_plate(v_vehicle.plate) THEN v_srv := array_append(v_srv, 'plate_mismatch'); END IF;
  END IF;
  IF v_doc.doc_type = 'registration_card' THEN
    IF f->>'registered_seats' IS NULL THEN v_srv := array_append(v_srv, 'seats_unreadable');
    ELSIF v_vehicle.registered_seats IS NULL OR (f->>'registered_seats')::numeric <> v_vehicle.registered_seats THEN v_srv := array_append(v_srv, 'seats_mismatch'); END IF;
  END IF;
  IF v_doc.doc_type IN ('driving_license','insurance','technical_inspection') THEN
    IF v_exp IS NULL THEN v_srv := array_append(v_srv, 'expiry_unreadable');
    ELSE
      IF v_exp < public.libreville_today() THEN v_srv := array_append(v_srv, 'expired'); END IF;
      IF v_doc.expires_on IS NOT NULL AND v_exp <> v_doc.expires_on THEN v_srv := array_append(v_srv, 'expiry_mismatch'); END IF;
    END IF;
  END IF;
  IF v_doc.doc_type IN ('identity_document','driving_license') AND f->>'full_name' IS NULL THEN v_srv := array_append(v_srv, 'name_unreadable'); END IF;
  IF v_doc.doc_type = 'driving_license' AND f->>'document_number' IS NULL THEN v_srv := array_append(v_srv, 'number_unreadable'); END IF;
  IF v_doc.doc_type = 'driver_photo' AND NOT (COALESCE((f->>'person_visible')::boolean,false) AND COALESCE((f->>'face_visible')::boolean,false)) THEN v_srv := array_append(v_srv, 'face_not_visible'); END IF;
  IF v_doc.doc_type = 'vehicle_photo' AND NOT COALESCE((f->>'vehicle_visible')::boolean,false) THEN v_srv := array_append(v_srv, 'vehicle_not_visible'); END IF;
  IF v_doc.doc_type IN ('driver_photo','vehicle_photo') AND NOT COALESCE((f->>'quality_ok')::boolean,false) THEN v_srv := array_append(v_srv, 'low_quality'); END IF;
  v_ok := cardinality(v_srv) = 0 AND jsonb_array_length(v_issues) = 0
      AND _result->>'recommended_decision' = 'AI_APPROVE'
      AND v_conf >= c.ai_auto_approve_min_confidence;
  INSERT INTO public.driver_document_checks(document_id, method, reviewer_id, ai_model, result, confidence, decision, extracted_data, anomalies)
  VALUES (_document_id, 'ai', NULL, left(_model, 80), CASE WHEN v_ok THEN 'pass' ELSE 'needs_review' END, v_conf,
          CASE WHEN v_ok THEN 'approve' ELSE 'manual_review_required' END,
          jsonb_build_object('document_type', _result->'document_type', 'readable', _result->'readable',
            'extracted_fields', f, 'field_confidences', COALESCE(_result->'field_confidences','[]'::jsonb),
            'warnings', COALESCE(_result->'warnings','[]'::jsonb),
            'recommended_decision', _result->'recommended_decision'),
          jsonb_build_object('inconsistencies', v_issues, 'server_checks', to_jsonb(v_srv)));
  UPDATE public.driver_document_ai_runs SET status='done', finished_at=now() WHERE document_id = _document_id;
  IF v_ok AND c.ai_auto_approve_enabled AND v_doc.is_current
     AND v_doc.status IN ('submitted','under_review')
     AND NOT EXISTS (SELECT 1 FROM public.driver_document_checks h WHERE h.document_id = _document_id AND h.method = 'human') THEN
    UPDATE public.driver_documents SET status = 'approved' WHERE id = _document_id;
    v_auto := true;
    PERFORM public.log_audit_event('document_ai_approved', 'driver_document', _document_id::text,
      'system', NULL, 'system', jsonb_build_object('doc_type', v_doc.doc_type, 'version', v_doc.version,
        'driver_id', v_doc.driver_id, 'confidence', v_conf, 'ai_model', left(_model, 80)));
    v_state := public.refresh_driver_onboarding_status(v_doc.driver_id);
  END IF;
  RETURN jsonb_build_object('auto_approved', v_auto,
    'recommended', CASE WHEN v_ok THEN 'AI_APPROVE' ELSE 'MANUAL_REVIEW_REQUIRED' END,
    'onboarding_state', v_state);
END $$;