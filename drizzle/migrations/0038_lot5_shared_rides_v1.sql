-- LOT 5 : taxi partagé V1. Chaque course reste indépendante (aucune ancre, aucun parent).
-- Compatibilité calculée uniquement côté serveur, recalculée à chaque appel depuis les courses réellement actives.

-- Seuil de détour : paramètre serveur dédié, AUCUNE valeur par défaut inventée (NULL => partage non activable).
CREATE OR REPLACE FUNCTION public.shared_detour_threshold_km() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN jsonb_typeof(value) = 'number' AND (value #>> '{}')::numeric > 0 THEN (value #>> '{}')::numeric END
  FROM public.system_settings WHERE key = 'shared_max_detour_km' $$;
REVOKE ALL ON FUNCTION public.shared_detour_threshold_km() FROM PUBLIC, anon, authenticated;

-- Détour (km) imposé à la course a par l'insertion de c : a.départ -> c.départ -> c.dépose -> a.dépose, moins le trajet direct de a.
CREATE OR REPLACE FUNCTION public.ride_shared_detour_km(a public.rides, c public.rides) RETURNS double precision
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
BEGIN
  IF a.pickup_lat IS NULL OR a.dropoff_lat IS NULL OR c.pickup_lat IS NULL OR c.dropoff_lat IS NULL THEN RETURN NULL; END IF;
  RETURN public.km_between(a.pickup_lat, a.pickup_lng, c.pickup_lat, c.pickup_lng)
       + public.km_between(c.pickup_lat, c.pickup_lng, c.dropoff_lat, c.dropoff_lng)
       + public.km_between(c.dropoff_lat, c.dropoff_lng, a.dropoff_lat, a.dropoff_lng)
       - public.km_between(a.pickup_lat, a.pickup_lng, a.dropoff_lat, a.dropoff_lng);
END $$;
REVOKE ALL ON FUNCTION public.ride_shared_detour_km(public.rides, public.rides) FROM PUBLIC, anon, authenticated;

-- Motif de refus (NULL = la course c peut être proposée/réservée par le Chauffeur _uid).
-- Ordre imposé : A consentement, B direction (±45°, règle legacy), C détour, D capacité.
CREATE OR REPLACE FUNCTION public.shared_v1_rejection(_uid uuid, c public.rides) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
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
END $$;
REVOKE ALL ON FUNCTION public.shared_v1_rejection(uuid, public.rides) FROM PUBLIC, anon, authenticated;

-- Pool V1 : ne renvoie que les demandes compatibles côté serveur.
CREATE OR REPLACE FUNCTION public.get_pool_v1(_lat double precision, _lng double precision, _radius_km double precision)
RETURNS TABLE(ride_id uuid, pickup_location text, pickup_landmark text, dropoff_location text, dropoff_note text,
  passenger_count smallint, wants_ac boolean, allow_sharing boolean, payment_method text, price_proposed integer,
  distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_ac boolean;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
BEGIN
  PERFORM public.ride_v1_assert_driver_ready(v_uid);
  IF EXISTS (SELECT 1 FROM public.rides WHERE chauffeur_id = v_uid AND status IN ('negotiating','onboard')) THEN RETURN; END IF;
  SELECT has_ac INTO v_ac FROM public.drivers WHERE user_id = v_uid;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.pickup_landmark, r.dropoff_location, r.dropoff_note,
    r.passenger_count, r.wants_ac, r.allow_sharing, public.ride_v1_payment_code(r.payment_method), r.price_proposed,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL OR _lng IS NULL THEN NULL ELSE public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) END,
    r.created_at
  FROM public.rides r
  WHERE r.workflow_version = 'v1' AND r.status_v2 = 'PENDING' AND NOT r.is_demo
    AND (v_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR _lng IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND public.shared_v1_rejection(v_uid, r) IS NULL
  ORDER BY 11 NULLS LAST, r.created_at DESC LIMIT 30;
END $$;

-- Réservation : tout est revérifié atomiquement (verrou Chauffeur + verrou de la course).
CREATE OR REPLACE FUNCTION public.reserve_ride_v1(_ride_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.rides; d public.drivers; v_vehicle uuid; v_asg uuid; v_rej text;
BEGIN
  PERFORM public.ride_v1_assert_driver_ready(v_uid);
  PERFORM pg_advisory_xact_lock(hashtext('driver_engage:' || v_uid::text));
  SELECT * INTO d FROM public.drivers WHERE user_id = v_uid;
  IF NOT d.is_online THEN RAISE EXCEPTION 'DRIVER_OFFLINE' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM public.rides WHERE chauffeur_id = v_uid AND status IN ('negotiating','onboard')) THEN
    RAISE EXCEPTION 'DRIVER_ALREADY_ENGAGED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND OR r.status_v2 <> 'PENDING' THEN RAISE EXCEPTION 'RIDE_UNAVAILABLE' USING ERRCODE = 'P0001'; END IF;
  IF r.wants_ac AND NOT d.has_ac THEN RAISE EXCEPTION 'RIDE_REQUIRES_AC' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM public.ride_assignments WHERE ride_id = r.id AND status IN ('reserved','confirmed')) THEN
    RAISE EXCEPTION 'RIDE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  v_rej := public.shared_v1_rejection(v_uid, r);
  IF v_rej IS NOT NULL THEN RAISE EXCEPTION '%', v_rej USING ERRCODE = 'P0001'; END IF;
  SELECT v.id INTO v_vehicle FROM public.vehicles v
   WHERE v.id = d.active_vehicle_id AND v.driver_id = v_uid AND v.deleted_at IS NULL;
  INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at)
  VALUES (r.id, v_uid, v_vehicle, 'reserved', 'v1', now()) RETURNING id INTO v_asg;
  PERFORM public.ride_v1_set_status(r.id, 'CONTACT_PENDING');
  PERFORM public.ride_v1_event(r.id, v_asg, 'driver_reserved', 'driver', v_uid, 'PENDING', 'CONTACT_PENDING');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CONTACT_PENDING', 'assignment_id', v_asg);
END $$;

-- Interrupteur Chauffeur : SHARED_CLOSED sans interrompre les courses acceptées.
CREATE OR REPLACE FUNCTION public.set_accepting_new_shared_v1(_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'chauffeur') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _on IS NULL THEN RAISE EXCEPTION 'INVALID_DATA' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.driver_presence SET accepting_new_shared = _on WHERE driver_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRIVER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  RETURN jsonb_build_object('accepting_new_shared', _on);
END $$;

-- État de partage du Chauffeur (capacité homologuée, places réservées, places occupées).
CREATE OR REPLACE FUNCTION public.get_my_shared_state_v1() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); res jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'chauffeur') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  SELECT jsonb_build_object(
    'passenger_capacity', (SELECT v.passenger_capacity FROM public.drivers d JOIN public.vehicles v ON v.id = d.active_vehicle_id AND v.driver_id = d.user_id AND v.deleted_at IS NULL WHERE d.user_id = v_uid),
    'seats_engaged', coalesce(sum(coalesce(r.passenger_count,1)), 0),
    'seats_onboard', coalesce(sum(coalesce(r.passenger_count,1)) FILTER (WHERE r.status_v2 = 'ONBOARD'), 0),
    'active_rides', count(r.id),
    'accepting_new_shared', (SELECT p.accepting_new_shared FROM public.driver_presence p WHERE p.driver_id = v_uid),
    'detour_threshold_set', public.shared_detour_threshold_km() IS NOT NULL)
  INTO res
  FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id
  WHERE x.driver_id = v_uid AND x.source = 'v1' AND x.status IN ('reserved','confirmed');
  RETURN res;
END $$;

-- Supervision Superadmin : charge par Chauffeur.
CREATE OR REPLACE FUNCTION public.admin_list_driver_loads_v1() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT jsonb_agg(s) FROM (
    SELECT d.first_name, d.vehicle_plate, count(r.id) AS active_rides,
           coalesce(sum(coalesce(r.passenger_count,1)),0) AS seats_engaged,
           coalesce(sum(coalesce(r.passenger_count,1)) FILTER (WHERE r.status_v2 = 'ONBOARD'),0) AS seats_onboard,
           (SELECT v.passenger_capacity FROM public.vehicles v WHERE v.id = d.active_vehicle_id) AS passenger_capacity,
           (SELECT p.accepting_new_shared FROM public.driver_presence p WHERE p.driver_id = d.user_id) AS accepting_new_shared
    FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id JOIN public.drivers d ON d.user_id = x.driver_id
    WHERE x.source = 'v1' AND x.status IN ('reserved','confirmed')
    GROUP BY d.user_id, d.first_name, d.vehicle_plate, d.active_vehicle_id) s), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.set_accepting_new_shared_v1(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_shared_state_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_list_driver_loads_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_accepting_new_shared_v1(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_shared_state_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_driver_loads_v1() TO authenticated;
