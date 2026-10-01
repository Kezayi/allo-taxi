-- LOT 6: Back-Office / Finance / Audit

-- 1. Restriction helper (dates-derived active state)
CREATE OR REPLACE FUNCTION public.driver_restriction_active(_driver uuid, _type text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.driver_restrictions r
    WHERE r.driver_id = _driver AND r.restriction_type = _type AND r.lifted_at IS NULL
      AND r.starts_at <= now() AND (r.ends_at IS NULL OR r.ends_at > now()));
$$;
REVOKE ALL ON FUNCTION public.driver_restriction_active(uuid, text) FROM PUBLIC, anon, authenticated;

-- 2. Gates: ONLINE / pool / take (never drop-off/close)
CREATE OR REPLACE FUNCTION public.set_driver_availability(_online boolean, _has_ac boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF _online THEN
    IF public.driver_restriction_active(auth.uid(), 'access_blocked') THEN RAISE EXCEPTION 'DRIVER_ACCESS_BLOCKED' USING ERRCODE = 'P0001'; END IF;
    IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
    PERFORM public.assert_driver_documents_gate(auth.uid());
  END IF;
  UPDATE public.drivers SET is_online=_online, has_ac=_has_ac, updated_at=now() WHERE user_id=auth.uid();
END $$;

CREATE OR REPLACE FUNCTION public.assert_driver_not_restricted_for_new_ride(_uid uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.driver_restriction_active(_uid, 'access_blocked') THEN RAISE EXCEPTION 'DRIVER_ACCESS_BLOCKED' USING ERRCODE = 'P0001'; END IF;
  IF public.driver_restriction_active(_uid, 'pool_blocked') THEN RAISE EXCEPTION 'DRIVER_POOL_BLOCKED' USING ERRCODE = 'P0001'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.assert_driver_not_restricted_for_new_ride(uuid) FROM PUBLIC, anon, authenticated;

-- ride_v1_assert_driver_ready is only used by get_pool_v1 and reserve_ride_v1 (new rides)
CREATE OR REPLACE FUNCTION public.ride_v1_assert_driver_ready(_uid uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF _uid IS NULL OR NOT public.is_active_driver(_uid) THEN RAISE EXCEPTION 'DRIVER_NOT_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.assert_driver_not_restricted_for_new_ride(_uid);
  IF NOT public.has_valid_driver_day_access(_uid) THEN RAISE EXCEPTION 'DAY_ACCESS_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.assert_driver_documents_gate(_uid);
END $$;

CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
 RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE a public.rides; c public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  PERFORM public.assert_driver_not_restricted_for_new_ride(auth.uid());
  IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  IF EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  IF EXISTS (SELECT 1 FROM public.ride_assignments ra WHERE ra.driver_id=auth.uid() AND ra.source='v1' AND ra.status IN ('reserved','confirmed')) THEN
    RAISE EXCEPTION 'Clôturez votre course en cours';
  END IF;
  SELECT count(*) INTO n_active FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='onboard';
  SELECT * INTO c FROM public.rides x WHERE x.id=_ride_id AND x.workflow_version='legacy' AND x.status='pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  IF n_active > 0 AND public.driver_restriction_active(auth.uid(), 'shared_blocked') THEN RAISE EXCEPTION 'SHARED_BLOCKED'; END IF;
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
  WHERE r.id=_ride_id AND r.workflow_version='legacy' AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $function$;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision)
 RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE d public.drivers%ROWTYPE;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
  a public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  PERFORM public.assert_driver_not_restricted_for_new_ride(auth.uid());
  IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=coalesce(_lat,last_lat), last_lng=coalesce(_lng,last_lng), last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  SELECT count(*) INTO n_active FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard');
  IF n_active > 0 THEN
    IF public.driver_restriction_active(auth.uid(), 'shared_blocked') THEN RETURN; END IF;
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
  WHERE r.workflow_version='legacy' AND r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND (n_active = 0 OR NOT lock_on OR (r.allow_sharing AND public.ride_same_direction(a, r)))
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $function$;

-- shared_blocked: only blocks an additional (shared) ride
CREATE OR REPLACE FUNCTION public.shared_v1_rejection(_uid uuid, c rides)
 RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE n_active int; n_onboard int; n_nosharing int; seats int; cap int; acc boolean; thr numeric; a public.rides; det double precision;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE r.status_v2 = 'ONBOARD'), count(*) FILTER (WHERE NOT r.allow_sharing),
         coalesce(sum(coalesce(r.passenger_count, 1)), 0)
    INTO n_active, n_onboard, n_nosharing, seats
  FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id
  WHERE x.driver_id = _uid AND x.source = 'v1' AND x.status IN ('reserved','confirmed') AND r.id <> c.id;
  SELECT v.passenger_capacity INTO cap FROM public.drivers d
    JOIN public.vehicles v ON v.id = d.active_vehicle_id AND v.driver_id = d.user_id AND v.deleted_at IS NULL
   WHERE d.user_id = _uid;

  IF n_active = 0 THEN
    IF cap IS NOT NULL AND coalesce(c.passenger_count, 1) > cap THEN RETURN 'CAPACITY_EXCEEDED'; END IF;
    RETURN NULL;
  END IF;
  IF public.driver_restriction_active(_uid, 'shared_blocked') THEN RETURN 'SHARED_BLOCKED'; END IF;
  IF n_nosharing > 0 THEN RETURN 'SHARING_NOT_ALLOWED'; END IF;
  IF n_onboard = 0 THEN RETURN 'SHARED_WAIT_ONBOARD'; END IF;
  SELECT p.accepting_new_shared INTO acc FROM public.driver_presence p WHERE p.driver_id = _uid;
  IF NOT coalesce(acc, false) THEN RETURN 'SHARED_CLOSED'; END IF;
  IF NOT c.allow_sharing THEN RETURN 'SHARING_NOT_ALLOWED'; END IF;
  FOR a IN SELECT r.* FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id
           WHERE x.driver_id = _uid AND x.source = 'v1' AND x.status IN ('reserved','confirmed') AND r.id <> c.id LOOP
    IF NOT public.ride_same_direction(a, c) THEN RETURN 'DIRECTION_INCOMPATIBLE'; END IF;
  END LOOP;
  thr := public.shared_detour_threshold_km();
  IF thr IS NULL THEN RETURN 'SHARED_DETOUR_THRESHOLD_REQUIRED'; END IF;
  FOR a IN SELECT r.* FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id
           WHERE x.driver_id = _uid AND x.source = 'v1' AND x.status IN ('reserved','confirmed') AND r.id <> c.id LOOP
    det := public.ride_shared_detour_km(a, c);
    IF det IS NULL OR det > thr THEN RETURN 'DETOUR_EXCEEDED'; END IF;
  END LOOP;
  IF cap IS NULL THEN RETURN 'CAPACITY_UNKNOWN'; END IF;
  IF seats + coalesce(c.passenger_count, 1) > cap THEN RETURN 'CAPACITY_EXCEEDED'; END IF;
  RETURN NULL;
END $function$;

-- 3. Admin restrictions
CREATE OR REPLACE FUNCTION public.admin_create_driver_restriction_v1(_driver uuid, _type text, _reason text, _ends_at timestamptz DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_uid uuid := auth.uid();
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _reason IS NULL OR btrim(_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  IF public.driver_restriction_active(_driver, _type) THEN RAISE EXCEPTION 'RESTRICTION_ALREADY_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO public.driver_restrictions(driver_id, restriction_type, reason, ends_at, created_by, source)
  VALUES (_driver, _type, btrim(_reason), _ends_at, v_uid, 'admin') RETURNING id INTO v_id;
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, reason, metadata)
  VALUES ('driver_restriction_created', 'driver', _driver::text, 'admin', v_uid, 'rpc', btrim(_reason),
          jsonb_build_object('restriction_id', v_id, 'restriction_type', _type, 'ends_at', _ends_at));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_lift_driver_restriction_v1(_restriction uuid, _reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.driver_restrictions; v_uid uuid := auth.uid();
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _reason IS NULL OR btrim(_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.driver_restrictions WHERE id = _restriction FOR UPDATE;
  IF NOT FOUND OR r.lifted_at IS NOT NULL THEN RAISE EXCEPTION 'RESTRICTION_NOT_LIFTABLE' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.driver_restrictions SET lifted_at = now(), lifted_by = v_uid, lift_reason = btrim(_reason) WHERE id = _restriction;
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, reason, metadata)
  VALUES ('driver_restriction_lifted', 'driver', r.driver_id::text, 'admin', v_uid, 'rpc', btrim(_reason),
          jsonb_build_object('restriction_id', r.id, 'restriction_type', r.restriction_type));
END $$;

CREATE OR REPLACE FUNCTION public.admin_list_driver_restrictions_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'drivers', coalesce((SELECT jsonb_agg(jsonb_build_object('driver_id', d.user_id, 'first_name', d.first_name,
        'last_name', d.last_name, 'vehicle_plate', d.vehicle_plate, 'is_online', d.is_online) ORDER BY d.first_name)
      FROM public.drivers d WHERE NOT d.is_demo AND d.deleted_at IS NULL), '[]'::jsonb),
    'restrictions', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'driver_id', r.driver_id,
        'driver_name', d.first_name, 'restriction_type', r.restriction_type, 'reason', r.reason,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'lifted_at', r.lifted_at, 'lift_reason', r.lift_reason,
        'active', r.lifted_at IS NULL AND r.starts_at <= now() AND (r.ends_at IS NULL OR r.ends_at > now()))
        ORDER BY r.created_at DESC)
      FROM public.driver_restrictions r JOIN public.drivers d ON d.user_id = r.driver_id), '[]'::jsonb));
END $$;

-- 4. Force offline (no cancellation of engaged rides)
CREATE OR REPLACE FUNCTION public.admin_force_driver_offline_v1(_driver uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); n_engaged int;
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _reason IS NULL OR btrim(_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.drivers SET is_online = false, updated_at = now() WHERE user_id = _driver AND NOT is_demo;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRIVER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT count(*) INTO n_engaged FROM public.ride_assignments WHERE driver_id = _driver AND status IN ('reserved','confirmed');
  n_engaged := n_engaged + (SELECT count(*) FROM public.rides WHERE chauffeur_id = _driver AND status IN ('negotiating','onboard'));
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, reason, metadata)
  VALUES ('driver_forced_offline', 'driver', _driver::text, 'admin', v_uid, 'rpc', btrim(_reason),
          jsonb_build_object('engaged_rides_kept', n_engaged));
  RETURN jsonb_build_object('driver_id', _driver, 'engaged_rides_kept', n_engaged);
END $$;

-- 5. Administrative price correction
CREATE OR REPLACE FUNCTION public.rides_v1_workflow_guard()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.workflow_version IS DISTINCT FROM OLD.workflow_version THEN
      RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE' USING ERRCODE = '23514';
    END IF;
    IF OLD.price_final_confirmed_at IS NOT NULL THEN
      IF NEW.price_final_confirmed_at IS DISTINCT FROM OLD.price_final_confirmed_at THEN
        RAISE EXCEPTION 'PRICE_FINAL_IMMUTABLE' USING ERRCODE = '23514';
      END IF;
      IF NEW.price_final IS DISTINCT FROM OLD.price_final
         AND coalesce(current_setting('app.admin_price_correction', true), '') <> '1' THEN
        RAISE EXCEPTION 'PRICE_FINAL_IMMUTABLE' USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;

  IF NEW.workflow_version <> 'v1' THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    IF coalesce(current_setting('app.ride_v1_rpc', true), '') <> '1' THEN
      RAISE EXCEPTION 'V1_RPC_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF NEW.status_v2 IS NULL OR NEW.status_v2 NOT IN ('DRAFT','PENDING') OR NEW.chauffeur_id IS NOT NULL
       OR NEW.price_final IS NOT NULL OR NEW.passenger_count IS NULL THEN
      RAISE EXCEPTION 'V1_INVALID_INITIAL_STATE' USING ERRCODE = '23514';
    END IF;
    NEW.status := public.ride_v1_legacy_status(NEW.status_v2);
    NEW.status_v2_changed_at := coalesce(NEW.created_at, now());
    RETURN NEW;
  END IF;

  IF NEW.chauffeur_id IS NOT NULL OR NEW.anchor_ride_id IS NOT NULL THEN
    RAISE EXCEPTION 'V1_LEGACY_FIELDS_FORBIDDEN' USING ERRCODE = '23514';
  END IF;
  IF NEW.status_v2 IS DISTINCT FROM OLD.status_v2 THEN
    IF coalesce(current_setting('app.ride_v1_rpc', true), '') <> '1' THEN
      RAISE EXCEPTION 'V1_RPC_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF NOT public.ride_v1_transition_allowed(OLD.status_v2, NEW.status_v2) THEN
      RAISE EXCEPTION 'V1_INVALID_TRANSITION % -> %', OLD.status_v2, NEW.status_v2 USING ERRCODE = '23514';
    END IF;
    NEW.status_v2_changed_at := now();
  END IF;
  IF NEW.status IS DISTINCT FROM public.ride_v1_legacy_status(NEW.status_v2) THEN
    IF NEW.status_v2 IS NOT DISTINCT FROM OLD.status_v2 AND NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'V1_LEGACY_STATUS_FORBIDDEN' USING ERRCODE = '23514';
    END IF;
    NEW.status := public.ride_v1_legacy_status(NEW.status_v2);
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.admin_correct_price_final_v1(_ride uuid, _new_price integer, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.rides;
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _reason IS NULL OR btrim(_reason) = '' THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  IF _new_price IS NULL OR _new_price < 0 OR _new_price > 1000000 THEN RAISE EXCEPTION 'INVALID_PRICE' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND OR r.is_demo THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF r.price_final_confirmed_at IS NULL OR r.price_final IS NULL THEN RAISE EXCEPTION 'PRICE_NOT_CONFIRMED' USING ERRCODE = 'P0001'; END IF;
  IF r.price_final = _new_price THEN RAISE EXCEPTION 'PRICE_UNCHANGED' USING ERRCODE = 'P0001'; END IF;
  PERFORM set_config('app.admin_price_correction', '1', true);
  UPDATE public.rides SET price_final = _new_price, updated_at = now() WHERE id = _ride;
  PERFORM set_config('app.admin_price_correction', '', true);
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, reason, metadata)
  VALUES ('administrative_price_correction', 'ride', _ride::text, 'admin', v_uid, 'rpc', btrim(_reason),
          jsonb_build_object('old_price_final', r.price_final, 'new_price_final', _new_price,
                             'price_final_confirmed_at', r.price_final_confirmed_at));
  RETURN jsonb_build_object('ride_id', _ride, 'old_price_final', r.price_final, 'new_price_final', _new_price);
END $$;

-- 6. Dashboard V1
CREATE OR REPLACE FUNCTION public.admin_dashboard_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'v1_active', (SELECT count(*) FROM public.rides WHERE workflow_version='v1' AND NOT is_demo
                  AND status_v2 IN ('PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED','ONBOARD')),
    'v1_completed_today', (SELECT count(*) FROM public.rides WHERE workflow_version='v1' AND NOT is_demo
                  AND status_v2 = 'COMPLETED' AND (status_v2_changed_at AT TIME ZONE 'Africa/Libreville')::date = today),
    'legacy_total', (SELECT count(*) FROM public.rides WHERE workflow_version='legacy' AND NOT is_demo),
    'legacy_active', (SELECT count(*) FROM public.rides WHERE workflow_version='legacy' AND NOT is_demo AND status IN ('pending','negotiating','onboard')),
    'demo_total', (SELECT count(*) FROM public.rides WHERE is_demo),
    'drivers_online', (SELECT count(*) FROM public.drivers WHERE is_online AND NOT is_demo AND deleted_at IS NULL),
    'drivers_engaged', (SELECT count(DISTINCT driver_id) FROM public.ride_assignments WHERE source='v1' AND status IN ('reserved','confirmed')),
    'shared_rides', (SELECT count(*) FROM public.ride_assignments WHERE source='v1' AND status IN ('reserved','confirmed')),
    'shared_seats', (SELECT coalesce(sum(coalesce(r.passenger_count,1)),0) FROM public.ride_assignments x JOIN public.rides r ON r.id=x.ride_id
                     WHERE x.source='v1' AND x.status IN ('reserved','confirmed')),
    'shared_capacity', (SELECT coalesce(sum(v.passenger_capacity),0) FROM public.vehicles v JOIN public.drivers d ON d.active_vehicle_id = v.id
                     WHERE d.user_id IN (SELECT driver_id FROM public.ride_assignments WHERE source='v1' AND status IN ('reserved','confirmed'))),
    'capacity_unknown', (SELECT count(*) FROM public.drivers d LEFT JOIN public.vehicles v ON v.id = d.active_vehicle_id
                     WHERE d.user_id IN (SELECT driver_id FROM public.ride_assignments WHERE source='v1' AND status IN ('reserved','confirmed'))
                       AND v.passenger_capacity IS NULL));
END $$;

-- 7. V1 ride register (no token/hash, no phone)
CREATE OR REPLACE FUNCTION public.admin_list_rides_v1(_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x) FROM (
    SELECT jsonb_build_object(
      'ride_id', r.id, 'workflow_version', r.workflow_version, 'is_demo', r.is_demo,
      'state', CASE WHEN r.workflow_version='v1' THEN r.status_v2 ELSE r.status END,
      'client_first_name', split_part(btrim(r.client_name), ' ', 1),
      'driver_name', d.first_name, 'vehicle_plate', coalesce(v.plate, d.vehicle_plate),
      'price_proposed', r.price_proposed, 'price_final', r.price_final,
      'price_final_confirmed_at', r.price_final_confirmed_at,
      'payment_method', r.payment_method, 'allow_sharing', r.allow_sharing,
      'created_at', r.created_at, 'boarded_at', r.boarded_at, 'resolved_at', r.resolved_at,
      'status_changed_at', r.status_v2_changed_at,
      'cancel_reason', (SELECT e.event_type FROM public.ride_events e WHERE e.ride_id = r.id
                         AND e.event_type IN ('canceled_by_client','canceled_by_driver','expired','contact_failed','legacy_canceled_unknown')
                         ORDER BY e.occurred_at DESC, e.id DESC LIMIT 1)) AS x
    FROM public.rides r
    LEFT JOIN LATERAL (SELECT a.driver_id, a.vehicle_id FROM public.ride_assignments a WHERE a.ride_id = r.id
                       ORDER BY a.started_at DESC LIMIT 1) a ON true
    LEFT JOIN public.drivers d ON d.user_id = coalesce(a.driver_id, r.chauffeur_id)
    LEFT JOIN public.vehicles v ON v.id = coalesce(a.vehicle_id, r.vehicle_id)
    ORDER BY r.created_at DESC LIMIT least(greatest(coalesce(_limit,100),1),500)) s), '[]'::jsonb);
END $$;

-- 8. Financial truth (payment_transactions only)
CREATE OR REPLACE FUNCTION public.finance_eligible_payments_v1()
RETURNS TABLE(id uuid, paid_day date, amount_base_fcfa integer, fees_fcfa integer, amount_total_fcfa integer, provider_net_amount_fcfa integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, (coalesce(p.provider_completed_at, p.resolved_at, p.created_at) AT TIME ZONE 'Africa/Libreville')::date,
         p.amount_base_fcfa, p.fees_fcfa, p.amount_total_fcfa, p.provider_net_amount_fcfa
  FROM public.payment_transactions p
  WHERE p.status = 'success' AND p.operation_type <> 'refund'
    AND NOT EXISTS (SELECT 1 FROM public.payment_transactions f WHERE f.refund_of_id = p.id AND f.status = 'success');
$$;
REVOKE ALL ON FUNCTION public.finance_eligible_payments_v1() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_finance_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'net_revenue', (SELECT coalesce(sum(amount_base_fcfa),0) FROM public.finance_eligible_payments_v1()),
    'net_revenue_today', (SELECT coalesce(sum(amount_base_fcfa),0) FROM public.finance_eligible_payments_v1() WHERE paid_day = today),
    'fees_total', (SELECT coalesce(sum(fees_fcfa),0) FROM public.finance_eligible_payments_v1()),
    'debited_total', (SELECT coalesce(sum(amount_total_fcfa),0) FROM public.finance_eligible_payments_v1()),
    'provider_net_total', (SELECT sum(provider_net_amount_fcfa) FROM public.finance_eligible_payments_v1()),
    'by_status', coalesce((SELECT jsonb_object_agg(status, jsonb_build_object('count', n, 'amount', amt)) FROM (
        SELECT status, count(*) n, sum(amount_base_fcfa) amt FROM public.payment_transactions GROUP BY status) s), '{}'::jsonb),
    'free_passes_today', (SELECT count(*) FROM public.driver_day_passes WHERE service_day = today AND mode = 'FREE'),
    'legacy_simulation', jsonb_build_object('label', 'Legacy / simulation non encaissée',
        'count', (SELECT count(*) FROM public.subscriptions WHERE NOT is_demo),
        'amount', (SELECT coalesce(sum(amount),0) FROM public.subscriptions WHERE NOT is_demo)),
    'transactions', coalesce((SELECT jsonb_agg(t ORDER BY t->>'created_at' DESC) FROM (
        SELECT jsonb_build_object('id', p.id, 'internal_reference', p.internal_reference, 'operation_type', p.operation_type,
          'provider', p.provider, 'status', p.status, 'amount_base_fcfa', p.amount_base_fcfa, 'fees_fcfa', p.fees_fcfa,
          'amount_total_fcfa', p.amount_total_fcfa, 'provider_net_amount_fcfa', p.provider_net_amount_fcfa,
          'counted', p.id IN (SELECT e.id FROM public.finance_eligible_payments_v1() e), 'created_at', p.created_at) t
        FROM public.payment_transactions p ORDER BY p.created_at DESC LIMIT 100) s), '[]'::jsonb));
END $$;

-- 9. Associate shares (rule valid at payment date)
CREATE OR REPLACE FUNCTION public.admin_associate_shares_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'associates', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'display_name', a.display_name, 'partner_key', a.partner_key, 'is_active', a.is_active) ORDER BY a.display_name)
        FROM public.associates a WHERE a.deleted_at IS NULL), '[]'::jsonb),
    'rules', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'associate_id', r.associate_id, 'display_name', a.display_name,
        'share_percent', r.share_percent, 'effective_from', r.effective_from, 'effective_to', r.effective_to, 'source', r.source) ORDER BY r.effective_from DESC)
        FROM public.associate_share_rules r JOIN public.associates a ON a.id = r.associate_id), '[]'::jsonb),
    'shares', coalesce((SELECT jsonb_agg(jsonb_build_object('period', s.period, 'associate', s.display_name, 'rule_id', s.rule_id,
        'share_percent', s.share_percent, 'eligible_revenue', s.revenue, 'share_amount', s.amount) ORDER BY s.period DESC, s.display_name)
      FROM (SELECT to_char(e.paid_day, 'YYYY-MM') period, a.display_name, r.id rule_id, r.share_percent,
                   sum(e.amount_base_fcfa) revenue, round(sum(e.amount_base_fcfa * r.share_percent / 100), 0) amount
            FROM public.finance_eligible_payments_v1() e
            JOIN public.associate_share_rules r ON r.effective_from <= e.paid_day AND e.paid_day < coalesce(r.effective_to, 'infinity'::date)
            JOIN public.associates a ON a.id = r.associate_id
            GROUP BY 1, 2, 3, 4) s), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.admin_create_associate_rule_v1(_associate uuid, _percent numeric, _from date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_id uuid;
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  INSERT INTO public.associate_share_rules(associate_id, share_percent, effective_from, source, created_by)
  VALUES (_associate, _percent, _from, 'admin', v_uid) RETURNING id INTO v_id;
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, metadata)
  VALUES ('associate_rule_created', 'associate', _associate::text, 'admin', v_uid, 'rpc',
          jsonb_build_object('rule_id', v_id, 'share_percent', _percent, 'effective_from', _from));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_close_associate_rule_v1(_rule uuid, _to date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.associate_share_rules;
BEGIN
  IF NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.associate_share_rules WHERE id = _rule;
  IF NOT FOUND THEN RAISE EXCEPTION 'RULE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.associate_share_rules SET effective_to = _to WHERE id = _rule;
  INSERT INTO public.audit_events(event_type, entity_type, entity_id, actor_type, actor_id, source, metadata)
  VALUES ('associate_rule_closed', 'associate', r.associate_id::text, 'admin', v_uid, 'rpc',
          jsonb_build_object('rule_id', _rule, 'old_effective_to', r.effective_to, 'new_effective_to', _to));
END $$;

-- 10. Audit read
CREATE OR REPLACE FUNCTION public.admin_list_audit_events_v1(_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x) FROM (
    SELECT jsonb_build_object('id', e.id, 'event_type', e.event_type, 'entity_type', e.entity_type, 'entity_id', e.entity_id,
      'actor_type', e.actor_type, 'reason', e.reason, 'metadata', e.metadata, 'occurred_at', e.occurred_at) x
    FROM public.audit_events e ORDER BY e.occurred_at DESC, e.id DESC LIMIT least(greatest(coalesce(_limit,100),1),500)) s), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_create_driver_restriction_v1(uuid, text, text, timestamptz), public.admin_lift_driver_restriction_v1(uuid, text),
  public.admin_list_driver_restrictions_v1(), public.admin_force_driver_offline_v1(uuid, text), public.admin_correct_price_final_v1(uuid, integer, text),
  public.admin_dashboard_v1(), public.admin_list_rides_v1(integer), public.admin_finance_v1(), public.admin_associate_shares_v1(),
  public.admin_create_associate_rule_v1(uuid, numeric, date), public.admin_close_associate_rule_v1(uuid, date), public.admin_list_audit_events_v1(integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_driver_restriction_v1(uuid, text, text, timestamptz), public.admin_lift_driver_restriction_v1(uuid, text),
  public.admin_list_driver_restrictions_v1(), public.admin_force_driver_offline_v1(uuid, text), public.admin_correct_price_final_v1(uuid, integer, text),
  public.admin_dashboard_v1(), public.admin_list_rides_v1(integer), public.admin_finance_v1(), public.admin_associate_shares_v1(),
  public.admin_create_associate_rule_v1(uuid, numeric, date), public.admin_close_associate_rule_v1(uuid, date), public.admin_list_audit_events_v1(integer)
  TO authenticated, service_role;
