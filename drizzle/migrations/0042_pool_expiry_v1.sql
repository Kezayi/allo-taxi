ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS pool_entered_at timestamptz NOT NULL DEFAULT now();
UPDATE public.rides SET pool_entered_at = created_at;
CREATE INDEX IF NOT EXISTS rides_v1_pool_idx ON public.rides (pool_entered_at, id) WHERE workflow_version = 'v1' AND status_v2 = 'PENDING';

INSERT INTO public.system_settings(key, value, updated_at) VALUES ('pool_expiry_minutes', to_jsonb(13), now())
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.pool_expiry_minutes() RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT greatest(1, least(60, coalesce(public.setting_num('pool_expiry_minutes', 13), 13)))::int $$;

CREATE OR REPLACE FUNCTION public.ride_v1_pool_overdue(_entered timestamptz) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT now() >= _entered + make_interval(mins => public.pool_expiry_minutes()) $$;

-- Matérialise l'expiration des courses PENDING dépassées (serveur uniquement).
CREATE OR REPLACE FUNCTION public.expire_overdue_rides_v1() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid; n integer := 0;
BEGIN
  FOR rid IN SELECT id FROM public.rides
    WHERE workflow_version = 'v1' AND status_v2 = 'PENDING' AND NOT is_demo
      AND public.ride_v1_pool_overdue(pool_entered_at)
    ORDER BY pool_entered_at FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM public.ride_v1_set_status(rid, 'EXPIRED');
    PERFORM public.ride_v1_event(rid, NULL, 'expired', 'system', NULL, 'PENDING', 'EXPIRED');
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.expire_overdue_rides_v1() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_overdue_rides_v1() TO service_role;
REVOKE ALL ON FUNCTION public.pool_expiry_minutes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pool_expiry_minutes() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.ride_v1_pool_overdue(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ride_v1_pool_overdue(timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.get_pool_v1(_lat double precision, _lng double precision, _radius_km double precision)
 RETURNS TABLE(ride_id uuid, pickup_location text, pickup_landmark text, dropoff_location text, dropoff_note text, passenger_count smallint, wants_ac boolean, allow_sharing boolean, payment_method text, price_proposed integer, distance_km double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_ac boolean;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
BEGIN
  PERFORM public.ride_v1_assert_driver_ready(v_uid);
  PERFORM public.expire_overdue_rides_v1();
  IF EXISTS (SELECT 1 FROM public.rides WHERE chauffeur_id = v_uid AND status IN ('negotiating','onboard')) THEN RETURN; END IF;
  SELECT has_ac INTO v_ac FROM public.drivers WHERE user_id = v_uid;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.pickup_landmark, r.dropoff_location, r.dropoff_note,
    r.passenger_count, r.wants_ac, r.allow_sharing, public.ride_v1_payment_code(r.payment_method), r.price_proposed,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL OR _lng IS NULL THEN NULL ELSE public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) END,
    r.pool_entered_at
  FROM public.rides r
  WHERE r.workflow_version = 'v1' AND r.status_v2 = 'PENDING' AND NOT r.is_demo
    AND NOT public.ride_v1_pool_overdue(r.pool_entered_at)
    AND (v_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR _lng IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND public.shared_v1_rejection(v_uid, r) IS NULL
  ORDER BY r.pool_entered_at ASC, r.id ASC LIMIT 30;
END $function$;

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
  IF NOT FOUND OR r.status_v2 <> 'PENDING' OR public.ride_v1_pool_overdue(r.pool_entered_at) THEN
    RAISE EXCEPTION 'RIDE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
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

CREATE OR REPLACE FUNCTION public.release_ride_v1(_ride_id uuid, _reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); r public.rides; a public.ride_assignments;
  v_reason text := nullif(left(btrim(coalesce(_reason,'')), 200), '');
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND driver_id = v_uid AND status = 'reserved' FOR UPDATE;
  IF NOT FOUND OR r.status_v2 <> 'CONTACT_PENDING' THEN RAISE EXCEPTION 'RELEASE_NOT_ALLOWED' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.ride_assignments SET status = 'released', ended_at = now(), end_reason = coalesce('driver_release:' || v_reason, 'driver_release') WHERE id = a.id;
  PERFORM public.ride_v1_set_status(r.id, 'PENDING');
  UPDATE public.rides SET pool_entered_at = now() WHERE id = r.id;
  PERFORM public.ride_v1_event(r.id, a.id, 'driver_released', 'driver', v_uid, 'CONTACT_PENDING', 'CONTACT_PENDING');
  PERFORM public.ride_v1_event(r.id, a.id, 'returned_to_pool', 'system', NULL, 'CONTACT_PENDING', 'PENDING');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'PENDING');
END $function$;

-- Statut Client : matérialise l'expiration de SA course si le délai est dépassé.
CREATE OR REPLACE FUNCTION public.get_ride_status_v1(_ride_id uuid, _token uuid)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r public.rides; a public.ride_assignments; d public.drivers; v public.vehicles;
  v_wa text; v_msg text; v_contact jsonb := NULL; v_safety jsonb := NULL;
BEGIN
  IF _ride_id IS NULL OR _token IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1'
     AND access_token_hash = extensions.digest(_token::text, 'sha256');
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF r.status_v2 = 'PENDING' AND NOT r.is_demo AND public.ride_v1_pool_overdue(r.pool_entered_at) THEN
    SELECT * INTO r FROM public.rides WHERE id = r.id FOR UPDATE;
    IF r.status_v2 = 'PENDING' AND public.ride_v1_pool_overdue(r.pool_entered_at) THEN
      PERFORM public.ride_v1_set_status(r.id, 'EXPIRED');
      PERFORM public.ride_v1_event(r.id, NULL, 'expired', 'system', NULL, 'PENDING', 'EXPIRED');
      SELECT * INTO r FROM public.rides WHERE id = r.id;
    END IF;
  END IF;

  IF r.status_v2 IN ('CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED','ONBOARD') THEN
    SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND source = 'v1' AND status IN ('reserved','confirmed');
    IF FOUND THEN
      SELECT * INTO d FROM public.drivers WHERE user_id = a.driver_id;
      v_wa := public.ride_v1_whatsapp_number(d.whatsapp_phone);
      v_msg := 'Bonjour ' || d.first_name || ', c''est ' || r.client_name || ' (Allo Taxi). Course de ' || r.pickup_location
               || ' vers ' || r.dropoff_location || ', ' || r.passenger_count || ' passager(s), prix proposé '
               || r.price_proposed || ' FCFA.';
      v_contact := jsonb_build_object(
        'driver_first_name', d.first_name,
        'whatsapp_status', CASE WHEN d.whatsapp_phone IS NULL OR btrim(d.whatsapp_phone) = '' THEN 'MISSING'
                                WHEN v_wa IS NULL THEN 'INVALID' ELSE 'AVAILABLE' END,
        'whatsapp_url', CASE WHEN v_wa IS NULL THEN NULL ELSE 'https://wa.me/' || v_wa || '?text=' || public.url_encode(v_msg) END);
      IF r.status_v2 <> 'CONTACT_PENDING' THEN
        IF a.vehicle_id IS NOT NULL THEN SELECT * INTO v FROM public.vehicles WHERE id = a.vehicle_id; END IF;
        v_safety := jsonb_build_object(
          'driver_first_name', d.first_name,
          'driver_photo_url', NULL, 'driver_photo_status', 'UNAVAILABLE',
          'vehicle_photo_url', NULL, 'vehicle_photo_status', 'UNAVAILABLE',
          'vehicle_make', v.make, 'vehicle_model', v.model, 'vehicle_color', v.color, 'vehicle_plate', v.plate,
          'vehicle_validated', coalesce(v.validation_status = 'approved', false));
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ride_id', r.id, 'status', r.status_v2, 'status_changed_at', r.status_v2_changed_at,
    'pickup_location', r.pickup_location, 'pickup_landmark', r.pickup_landmark,
    'dropoff_location', r.dropoff_location, 'dropoff_note', r.dropoff_note,
    'passenger_count', r.passenger_count, 'wants_ac', r.wants_ac, 'allow_sharing', r.allow_sharing,
    'payment_method', public.ride_v1_payment_code(r.payment_method),
    'price_proposed', r.price_proposed, 'price_final', r.price_final, 'price_final_confirmed_at', r.price_final_confirmed_at,
    'contact', v_contact, 'safety', v_safety, 'created_at', r.created_at,
    'pool_entered_at', r.pool_entered_at, 'pool_expires_at', r.pool_entered_at + make_interval(mins => public.pool_expiry_minutes()));
END $function$;

-- Réglage Superadmin de la durée de vie dans le pool (journalisé).
CREATE OR REPLACE FUNCTION public.set_pool_expiry_minutes_v1(_minutes integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old integer := public.pool_expiry_minutes();
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _minutes IS NULL OR _minutes < 1 OR _minutes > 60 THEN RAISE EXCEPTION 'INVALID_DATA' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO public.system_settings(key, value, updated_at) VALUES ('pool_expiry_minutes', to_jsonb(_minutes), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM public.log_audit_event('pool_expiry_changed', 'system_setting', 'pool_expiry_minutes', 'admin', auth.uid(), 'backoffice',
    jsonb_build_object('from', v_old, 'to', _minutes));
  RETURN _minutes;
END $$;
REVOKE ALL ON FUNCTION public.set_pool_expiry_minutes_v1(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_pool_expiry_minutes_v1(integer) TO authenticated;