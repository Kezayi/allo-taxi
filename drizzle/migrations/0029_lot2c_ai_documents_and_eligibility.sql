-- LOT 2C : analyse IA documentaire (serveur) + moteur d'éligibilité + gate SHADOW/ENFORCED

-- 1. Contrôle de bascule (singleton, service_role uniquement)
CREATE TABLE public.onboarding_control (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enforcement_mode text NOT NULL DEFAULT 'shadow' CHECK (enforcement_mode IN ('shadow','enforced')),
  ai_auto_approve_enabled boolean NOT NULL DEFAULT true,
  ai_auto_approve_min_confidence numeric NOT NULL DEFAULT 0.92 CHECK (ai_auto_approve_min_confidence > 0.5 AND ai_auto_approve_min_confidence <= 1),
  enforced_at timestamptz,
  enforced_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.onboarding_control TO service_role;
ALTER TABLE public.onboarding_control ENABLE ROW LEVEL SECURITY;
INSERT INTO public.onboarding_control(id) VALUES (true);
COMMENT ON TABLE public.onboarding_control IS 'Gate de migration TEMPORAIRE LOT 2C : shadow -> enforced, sens unique.';

CREATE OR REPLACE FUNCTION public.onboarding_control_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'ONBOARDING_CONTROL_UNDELETABLE'; END IF;
  IF OLD.enforcement_mode = 'enforced' AND NEW.enforcement_mode <> 'enforced' THEN
    RAISE EXCEPTION 'ENFORCEMENT_IS_ONE_WAY';
  END IF;
  IF OLD.enforcement_mode = 'enforced' AND (NEW.enforced_at IS DISTINCT FROM OLD.enforced_at OR NEW.enforced_by IS DISTINCT FROM OLD.enforced_by) THEN
    RAISE EXCEPTION 'ENFORCEMENT_IS_ONE_WAY';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER onboarding_control_guard BEFORE UPDATE OR DELETE ON public.onboarding_control
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_control_guard();

-- 2. Suivi des analyses IA (idempotence, état "en cours")
CREATE TABLE public.driver_document_ai_runs (
  document_id uuid PRIMARY KEY REFERENCES public.driver_documents(id) ON DELETE RESTRICT,
  status text NOT NULL CHECK (status IN ('pending','done','failed')),
  attempts integer NOT NULL DEFAULT 1,
  error_code text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
GRANT ALL ON public.driver_document_ai_runs TO service_role;
ALTER TABLE public.driver_document_ai_runs ENABLE ROW LEVEL SECURITY;

-- Une seule analyse IA par version de document (idempotence / coût)
CREATE UNIQUE INDEX driver_document_checks_one_ai_per_version
  ON public.driver_document_checks(document_id) WHERE method = 'ai';

-- 3. Mode courant
CREATE OR REPLACE FUNCTION public.onboarding_enforcement_mode()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT enforcement_mode FROM public.onboarding_control WHERE id), 'shadow')
$$;

-- 4. Moteur central d'éligibilité (calcul interne, sans contrôle d'appelant)
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
  IF v_driver.status = 'suspended' THEN v_reasons := v_reasons || 'DRIVER_SUSPENDED'; END IF;
  IF v_driver.onboarding_status = 'rejected' THEN v_reasons := v_reasons || 'DRIVER_REJECTED'; END IF;
  IF v_driver.status <> 'approved' OR NOT v_driver.is_active OR v_driver.deleted_at IS NOT NULL THEN
    v_reasons := v_reasons || 'DRIVER_NOT_APPROVED';
  END IF;

  SELECT * INTO v_vehicle FROM public.vehicles
   WHERE driver_id = _driver_id AND is_active AND deleted_at IS NULL;
  IF v_vehicle.id IS NULL OR v_vehicle.validation_status <> 'approved' THEN
    v_reasons := v_reasons || 'VEHICLE_NOT_APPROVED';
  END IF;
  IF v_vehicle.id IS NULL OR v_vehicle.registered_seats IS NULL
     OR v_vehicle.passenger_capacity IS DISTINCT FROM v_vehicle.registered_seats - 1
     OR v_vehicle.passenger_capacity < 1 THEN
    v_reasons := v_reasons || 'INVALID_CAPACITY';
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

  IF v_missing > 0 THEN v_reasons := v_reasons || 'DOCUMENT_MISSING'; END IF;
  IF v_pending > 0 THEN v_reasons := v_reasons || 'DOCUMENT_PENDING'; END IF;
  IF v_corr > 0 THEN v_reasons := v_reasons || 'DOCUMENT_CORRECTION_REQUIRED'; END IF;
  IF v_exp > 0 THEN v_reasons := v_reasons || 'DOCUMENT_EXPIRED'; END IF;
  -- Filet : toute autre anomalie (ex. statut inattendu) empêche l'éligibilité
  IF v_ok < array_length(v_types,1) AND cardinality(v_reasons) = 0 THEN
    v_reasons := v_reasons || 'DOCUMENT_PENDING';
  END IF;

  RETURN jsonb_build_object(
    'eligible', cardinality(v_reasons) = 0,
    'reasons', to_jsonb(v_reasons),
    'documents', jsonb_build_object('required', array_length(v_types,1), 'approved', v_ok,
       'missing', v_missing, 'pending', v_pending, 'correction', v_corr, 'expired', v_exp)
  );
END $$;
REVOKE ALL ON FUNCTION public.compute_driver_operational_eligibility(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_driver_operational_eligibility(uuid) TO service_role;

-- Point d'entrée public : soi-même ou Superadmin
CREATE OR REPLACE FUNCTION public.evaluate_driver_operational_eligibility(_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF v_uid <> _driver_id AND NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN public.compute_driver_operational_eligibility(_driver_id)
         || jsonb_build_object('mode', public.onboarding_enforcement_mode());
END $$;
REVOKE ALL ON FUNCTION public.evaluate_driver_operational_eligibility(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.evaluate_driver_operational_eligibility(uuid) TO authenticated, service_role;

-- Gate : n'agit qu'en ENFORCED
CREATE OR REPLACE FUNCTION public.assert_driver_documents_gate(_driver_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF public.onboarding_enforcement_mode() <> 'enforced' THEN RETURN; END IF;
  v := public.compute_driver_operational_eligibility(_driver_id);
  IF NOT (v->>'eligible')::boolean THEN
    RAISE EXCEPTION 'DOSSIER_NON_ELIGIBLE: %', (SELECT string_agg(x, ',') FROM jsonb_array_elements_text(v->'reasons') x);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.assert_driver_documents_gate(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_driver_documents_gate(uuid) TO service_role;

-- 5. Points de contrôle : ONLINE, pool, take_ride (corps legacy inchangés + gate)
CREATE OR REPLACE FUNCTION public.set_driver_availability(_online boolean, _has_ac boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF _online THEN PERFORM public.assert_driver_documents_gate(auth.uid()); END IF;
  UPDATE public.drivers SET is_online=_online, has_ac=_has_ac, updated_at=now() WHERE user_id=auth.uid();
END $function$;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision)
 RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE d public.drivers%ROWTYPE; today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
  a public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=today AND s.status='active') THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=coalesce(_lat,last_lat), last_lng=coalesce(_lng,last_lng), last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  SELECT count(*) INTO n_active FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard');
  IF n_active > 0 THEN
    IF n_active >= 3 OR EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN
      RETURN;
    END IF;
    IF lock_on THEN
      a := public.driver_anchor_ride(auth.uid());
      IF a.id IS NULL OR NOT a.allow_sharing OR a.status <> 'onboard' THEN
        RETURN;
      END IF;
    END IF;
  END IF;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL THEN NULL ELSE public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) END,
    r.created_at
  FROM public.rides r
  WHERE r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND (n_active = 0 OR NOT lock_on OR (r.allow_sharing AND public.ride_same_direction(a, r)))
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $function$;

CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
 RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE a public.rides; c public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=(now() AT TIME ZONE 'Africa/Libreville')::date) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  IF EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  SELECT count(*) INTO n_active FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='onboard';
  SELECT * INTO c FROM public.rides x WHERE x.id=_ride_id AND x.status='pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  IF n_active > 0 AND lock_on THEN
    a := public.driver_anchor_ride(auth.uid());
    IF a.id IS NULL OR NOT a.allow_sharing THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: le client principal n''a pas accepté le partage'; END IF;
    IF n_active >= 3 THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: véhicule complet'; END IF;
    IF NOT c.allow_sharing OR NOT public.ride_same_direction(a, c) THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: course hors de votre trajet'; END IF;
  ELSIF n_active >= 3 THEN
    RAISE EXCEPTION 'Véhicule complet';
  END IF;
  UPDATE public.rides r SET status='negotiating', chauffeur_id=auth.uid(), started_negotiation_at=now(), updated_at=now(),
    anchor_ride_id = CASE WHEN n_active > 0 AND lock_on THEN a.id ELSE NULL END
  WHERE r.id=_ride_id AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $function$;

-- 6. Bascule SHADOW -> ENFORCED (Superadmin, auditée, sens unique)
CREATE OR REPLACE FUNCTION public.get_onboarding_enforcement_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_drivers jsonb; v_ready boolean; c public.onboarding_control;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO c FROM public.onboarding_control WHERE id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'driver_id', d.user_id, 'first_name', d.first_name, 'last_name', d.last_name,
           'onboarding_status', d.onboarding_status,
           'eligibility', public.compute_driver_operational_eligibility(d.user_id)) ORDER BY d.first_name), '[]'::jsonb)
    INTO v_drivers
  FROM public.drivers d
  WHERE NOT d.is_demo AND d.is_active AND d.deleted_at IS NULL AND d.status = 'approved';
  SELECT jsonb_array_length(v_drivers) > 0
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_drivers) e WHERE NOT (e->'eligibility'->>'eligible')::boolean)
    INTO v_ready;
  RETURN jsonb_build_object('mode', c.enforcement_mode, 'enforced_at', c.enforced_at,
    'ai_auto_approve_enabled', c.ai_auto_approve_enabled,
    'ai_auto_approve_min_confidence', c.ai_auto_approve_min_confidence,
    'ready_for_enforcement', v_ready, 'real_drivers', v_drivers);
END $$;
REVOKE ALL ON FUNCTION public.get_onboarding_enforcement_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_onboarding_enforcement_status() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enable_onboarding_enforcement(_confirmation text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); s jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF _confirmation IS DISTINCT FROM 'ACTIVER' THEN RAISE EXCEPTION 'CONFIRMATION_REQUIRED'; END IF;
  PERFORM 1 FROM public.onboarding_control WHERE id FOR UPDATE;
  IF public.onboarding_enforcement_mode() = 'enforced' THEN RAISE EXCEPTION 'ALREADY_ENFORCED'; END IF;
  s := public.get_onboarding_enforcement_status();
  IF NOT (s->>'ready_for_enforcement')::boolean THEN RAISE EXCEPTION 'NOT_READY_FOR_ENFORCEMENT'; END IF;
  UPDATE public.onboarding_control SET enforcement_mode='enforced', enforced_at=now(), enforced_by=v_uid WHERE id;
  PERFORM public.log_audit_event('onboarding_enforcement_enabled', 'onboarding_control', 'singleton',
    'admin', v_uid, 'rpc', jsonb_build_object('from', 'shadow', 'to', 'enforced',
      'real_drivers', jsonb_array_length(s->'real_drivers')));
  RETURN jsonb_build_object('mode', 'enforced');
END $$;
REVOKE ALL ON FUNCTION public.enable_onboarding_enforcement(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enable_onboarding_enforcement(text) TO authenticated, service_role;

-- 7. IA : réservation de l'analyse (propriétaire ou Superadmin)
CREATE OR REPLACE FUNCTION public.request_document_ai_analysis(_document_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_doc public.driver_documents; v_admin boolean; v_run public.driver_document_ai_runs; v_vehicle public.vehicles;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  v_admin := public.has_role(v_uid, 'super_admin');
  SELECT * INTO v_doc FROM public.driver_documents WHERE id = _document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENT_NOT_FOUND'; END IF;
  IF v_doc.driver_id <> v_uid AND NOT v_admin THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF NOT v_doc.is_current THEN RETURN jsonb_build_object('status', 'not_current'); END IF;
  IF EXISTS (SELECT 1 FROM public.driver_document_checks WHERE document_id = _document_id AND method = 'ai') THEN
    RETURN jsonb_build_object('status', 'already_analyzed');
  END IF;

  SELECT * INTO v_run FROM public.driver_document_ai_runs WHERE document_id = _document_id FOR UPDATE;
  IF FOUND THEN
    IF v_run.status = 'pending' AND v_run.started_at > now() - interval '10 minutes' THEN
      RETURN jsonb_build_object('status', 'in_progress');
    END IF;
    -- Pas de relance automatique : seul le Superadmin relance après échec, 3 essais max.
    IF v_run.status = 'failed' AND (NOT v_admin OR v_run.attempts >= 3) THEN
      RETURN jsonb_build_object('status', 'failed', 'error_code', v_run.error_code);
    END IF;
    IF v_run.status = 'done' THEN RETURN jsonb_build_object('status', 'already_analyzed'); END IF;
    UPDATE public.driver_document_ai_runs SET status='pending', attempts=attempts+1, error_code=NULL, started_at=now(), finished_at=NULL
     WHERE document_id = _document_id;
  ELSE
    INSERT INTO public.driver_document_ai_runs(document_id, status) VALUES (_document_id, 'pending');
  END IF;

  SELECT * INTO v_vehicle FROM public.vehicles WHERE id = v_doc.vehicle_id;
  RETURN jsonb_build_object('status', 'claimed', 'doc_type', v_doc.doc_type,
    'bucket', v_doc.storage_bucket, 'path', v_doc.storage_path, 'mime_type', v_doc.mime_type,
    'expires_on', v_doc.expires_on, 'vehicle_plate', v_vehicle.plate,
    'vehicle_model', v_vehicle.model, 'registered_seats', v_vehicle.registered_seats);
END $$;
REVOKE ALL ON FUNCTION public.request_document_ai_analysis(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_document_ai_analysis(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.ai_fail_document_analysis(_document_id uuid, _error_code text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.driver_document_ai_runs SET status='failed', error_code=left(_error_code, 60), finished_at=now()
   WHERE document_id = _document_id AND status = 'pending';
$$;
REVOKE ALL ON FUNCTION public.ai_fail_document_analysis(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_fail_document_analysis(uuid, text) TO service_role;

-- 8. IA : enregistrement du résultat + auto-approbation conservatrice (vérifiée en base)
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
  BEGIN v_exp := NULLIF(f->>'expiry_date','')::date; EXCEPTION WHEN others THEN v_exp := NULL; v_srv := v_srv || 'expiry_unparseable'; END;

  -- Contrôles serveur indépendants du modèle
  IF COALESCE(_result->>'document_type','') <> v_doc.doc_type THEN v_srv := v_srv || 'document_type_mismatch'; END IF;
  IF NOT COALESCE((_result->>'readable')::boolean, false) THEN v_srv := v_srv || 'unreadable'; END IF;
  IF v_doc.doc_type IN ('registration_card','insurance','technical_inspection','vehicle_plate_photo') THEN
    IF f->>'plate' IS NULL THEN v_srv := v_srv || 'plate_unreadable';
    ELSIF v_vehicle.plate IS NULL OR public.normalize_plate(f->>'plate') <> public.normalize_plate(v_vehicle.plate) THEN v_srv := v_srv || 'plate_mismatch'; END IF;
  END IF;
  IF v_doc.doc_type = 'registration_card' THEN
    IF f->>'registered_seats' IS NULL THEN v_srv := v_srv || 'seats_unreadable';
    ELSIF v_vehicle.registered_seats IS NULL OR (f->>'registered_seats')::numeric <> v_vehicle.registered_seats THEN v_srv := v_srv || 'seats_mismatch'; END IF;
  END IF;
  IF v_doc.doc_type IN ('driving_license','insurance','technical_inspection') THEN
    IF v_exp IS NULL THEN v_srv := v_srv || 'expiry_unreadable';
    ELSE
      IF v_exp < public.libreville_today() THEN v_srv := v_srv || 'expired'; END IF;
      IF v_doc.expires_on IS NOT NULL AND v_exp <> v_doc.expires_on THEN v_srv := v_srv || 'expiry_mismatch'; END IF;
    END IF;
  END IF;
  IF v_doc.doc_type IN ('identity_document','driving_license') AND f->>'full_name' IS NULL THEN v_srv := v_srv || 'name_unreadable'; END IF;
  IF v_doc.doc_type = 'driving_license' AND f->>'document_number' IS NULL THEN v_srv := v_srv || 'number_unreadable'; END IF;
  IF v_doc.doc_type = 'driver_photo' AND NOT (COALESCE((f->>'person_visible')::boolean,false) AND COALESCE((f->>'face_visible')::boolean,false)) THEN v_srv := v_srv || 'face_not_visible'; END IF;
  IF v_doc.doc_type = 'vehicle_photo' AND NOT COALESCE((f->>'vehicle_visible')::boolean,false) THEN v_srv := v_srv || 'vehicle_not_visible'; END IF;
  IF v_doc.doc_type IN ('driver_photo','vehicle_photo') AND NOT COALESCE((f->>'quality_ok')::boolean,false) THEN v_srv := v_srv || 'low_quality'; END IF;

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

  -- HUMAIN > IA : jamais de changement de statut si une décision humaine existe, si la version
  -- n'est plus courante, ou si le document n'est plus en attente. Jamais d'auto-rejet.
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
REVOKE ALL ON FUNCTION public.ai_complete_document_analysis(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_complete_document_analysis(uuid, text, jsonb) TO service_role;

-- 9. Vue Chauffeur : état "en cours d'analyse" + éligibilité (sans détail IA)
CREATE OR REPLACE FUNCTION public.get_my_driver_onboarding()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
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
  SELECT * INTO v_vehicle FROM public.vehicles WHERE driver_id = v_uid AND is_active AND deleted_at IS NULL;

  SELECT jsonb_agg(jsonb_build_object(
           'doc_type', t.doc_type,
           'scope', CASE WHEN t.doc_type IN ('identity_document','driver_photo','driving_license') THEN 'driver' ELSE 'vehicle' END,
           'required_expiry', public.doc_type_requires_expiry(t.doc_type),
           'present', d.id IS NOT NULL,
           'document_id', d.id,
           'status', CASE WHEN d.id IS NULL THEN NULL ELSE public.document_effective_status(d.status, d.expires_on) END,
           'analysis_pending', COALESCE((SELECT r.status = 'pending' AND r.started_at > now() - interval '10 minutes'
                                          FROM public.driver_document_ai_runs r WHERE r.document_id = d.id), false),
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
    'driver', jsonb_build_object('onboarding_status', v_driver.onboarding_status, 'status', v_driver.status,
       'first_name', v_driver.first_name, 'last_name', v_driver.last_name),
    'global_state', public.compute_driver_onboarding_state(v_uid),
    'eligibility', public.compute_driver_operational_eligibility(v_uid) || jsonb_build_object('mode', public.onboarding_enforcement_mode()),
    'active_vehicle', CASE WHEN v_vehicle.id IS NULL THEN NULL ELSE jsonb_build_object(
       'id', v_vehicle.id, 'make', v_vehicle.make, 'model', v_vehicle.model, 'color', v_vehicle.color,
       'plate', v_vehicle.plate, 'has_ac', v_vehicle.has_ac,
       'registered_seats', v_vehicle.registered_seats, 'passenger_capacity', v_vehicle.passenger_capacity,
       'validation_status', v_vehicle.validation_status) END,
    'documents', COALESCE(v_docs, '[]'::jsonb),
    'summary', jsonb_build_object(
       'total_required', array_length(v_types,1),
       'approved', (SELECT count(*) FROM jsonb_array_elements(COALESCE(v_docs,'[]'::jsonb)) e WHERE e->>'status' = 'approved'),
       'missing',  (SELECT count(*) FROM jsonb_array_elements(COALESCE(v_docs,'[]'::jsonb)) e WHERE (e->>'present')::boolean = false))
  );
END $function$;
