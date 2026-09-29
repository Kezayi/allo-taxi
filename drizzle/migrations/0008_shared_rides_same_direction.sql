ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS allow_sharing boolean NOT NULL DEFAULT false;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS dropoff_lat double precision;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS dropoff_lng double precision;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS anchor_ride_id uuid;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS boarded_at timestamptz;

ALTER TABLE public.rides DROP CONSTRAINT IF EXISTS rides_status_check;
ALTER TABLE public.rides ADD CONSTRAINT rides_status_check CHECK (status = ANY (ARRAY['pending','negotiating','onboard','completed','canceled']));

DROP POLICY IF EXISTS "Public express ride publication" ON public.rides;
CREATE POLICY "Public express ride publication" ON public.rides FOR INSERT TO anon, authenticated
WITH CHECK (status = 'pending' AND chauffeur_id IS NULL AND started_negotiation_at IS NULL AND resolved_at IS NULL AND anchor_ride_id IS NULL AND boarded_at IS NULL);

-- Cap (degrés 0-360) entre deux points
CREATE OR REPLACE FUNCTION public.bearing_deg(_lat1 double precision, _lng1 double precision, _lat2 double precision, _lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT (degrees(atan2(sin(radians(_lng2-_lng1))*cos(radians(_lat2)),
    cos(radians(_lat1))*sin(radians(_lat2)) - sin(radians(_lat1))*cos(radians(_lat2))*cos(radians(_lng2-_lng1)))) + 360)::numeric % 360
$$;

-- Distance (km) équirectangulaire, suffisante à l'échelle d'une ville
CREATE OR REPLACE FUNCTION public.km_between(_lat1 double precision, _lng1 double precision, _lat2 double precision, _lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT 6371 * 2 * asin(sqrt(power(sin(radians(_lat2-_lat1)/2),2) + cos(radians(_lat1))*cos(radians(_lat2))*power(sin(radians(_lng2-_lng1)/2),2)))
$$;

-- Même direction : cap du nouveau trajet à ±45° de la course principale,
-- et dépose avant (ou à moins d'1 km au-delà de) la destination principale.
CREATE OR REPLACE FUNCTION public.ride_same_direction(a public.rides, c public.rides)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE ba double precision; bc double precision; diff double precision; len double precision; proj double precision;
BEGIN
  IF a.pickup_lat IS NULL OR a.dropoff_lat IS NULL OR c.pickup_lat IS NULL OR c.dropoff_lat IS NULL THEN
    RETURN lower(trim(a.dropoff_location)) = lower(trim(c.dropoff_location));
  END IF;
  ba := public.bearing_deg(a.pickup_lat, a.pickup_lng, a.dropoff_lat, a.dropoff_lng);
  bc := public.bearing_deg(c.pickup_lat, c.pickup_lng, c.dropoff_lat, c.dropoff_lng);
  diff := abs(ba - bc); IF diff > 180 THEN diff := 360 - diff; END IF;
  IF diff > 45 THEN RETURN false; END IF;
  len := public.km_between(a.pickup_lat, a.pickup_lng, a.dropoff_lat, a.dropoff_lng);
  proj := public.km_between(a.pickup_lat, a.pickup_lng, c.dropoff_lat, c.dropoff_lng)
          * cos(radians(public.bearing_deg(a.pickup_lat, a.pickup_lng, c.dropoff_lat, c.dropoff_lng) - ba));
  RETURN proj <= len + 1;
END $$;

-- Course principale du chauffeur (celle qui verrouille le trajet)
CREATE OR REPLACE FUNCTION public.driver_anchor_ride(_uid uuid)
RETURNS public.rides LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.rides WHERE chauffeur_id=_uid AND status IN ('negotiating','onboard') AND anchor_ride_id IS NULL
  ORDER BY started_negotiation_at LIMIT 1
$$;
REVOKE EXECUTE ON FUNCTION public.driver_anchor_ride(uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision DEFAULT NULL)
RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE; today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
  a public.rides; n_active int;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=today AND s.status='active') THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=coalesce(_lat,last_lat), last_lng=coalesce(_lng,last_lng), last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  SELECT count(*) INTO n_active FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard');
  a := public.driver_anchor_ride(auth.uid());
  IF n_active > 0 THEN
    -- Trajet verrouillé : seulement si le client principal a accepté le partage, est à bord, et qu'il reste une place (3 max)
    IF a.id IS NULL OR NOT a.allow_sharing OR a.status <> 'onboard' OR n_active >= 3
       OR EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN
      RETURN;
    END IF;
  END IF;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL THEN NULL ELSE public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) END,
    r.created_at
  FROM public.rides r
  WHERE r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND (n_active = 0 OR (r.allow_sharing AND public.ride_same_direction(a, r)))
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $$;

CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.rides; c public.rides; n_active int;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=(now() AT TIME ZONE 'Africa/Libreville')::date) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  IF EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  SELECT count(*) INTO n_active FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='onboard';
  SELECT * INTO c FROM public.rides x WHERE x.id=_ride_id AND x.status='pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  IF n_active > 0 THEN
    a := public.driver_anchor_ride(auth.uid());
    IF a.id IS NULL OR NOT a.allow_sharing THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: le client principal n''a pas accepté le partage'; END IF;
    IF n_active >= 3 THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: véhicule complet'; END IF;
    IF NOT c.allow_sharing OR NOT public.ride_same_direction(a, c) THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: course hors de votre trajet'; END IF;
  END IF;
  UPDATE public.rides r SET status='negotiating', chauffeur_id=auth.uid(), started_negotiation_at=now(), updated_at=now(),
    anchor_ride_id = CASE WHEN n_active > 0 THEN a.id ELSE NULL END
  WHERE r.id=_ride_id AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $$;

-- Embarqué => à bord ; échec => relance dans le pool
CREATE OR REPLACE FUNCTION public.close_ride(_ride_id uuid, _success boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id=_ride_id AND chauffeur_id=auth.uid() AND status='negotiating' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course introuvable'; END IF;
  IF _success THEN
    UPDATE public.rides SET status='onboard', boarded_at=now(), updated_at=now() WHERE id=_ride_id;
    RETURN 'onboard';
  END IF;
  PERFORM public.log_ride_resolution(r, 'canceled');
  UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, anchor_ride_id=NULL, updated_at=now() WHERE id=_ride_id;
  RETURN 'released';
END $$;

-- Dépose à destination => course terminée et journalisée
CREATE OR REPLACE FUNCTION public.drop_off_ride(_ride_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id=_ride_id AND chauffeur_id=auth.uid() AND status='onboard' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course introuvable'; END IF;
  PERFORM public.log_ride_resolution(r, 'completed');
  UPDATE public.rides SET status='completed', resolved_at=now(), updated_at=now() WHERE id=_ride_id;
  -- Si la course principale se termine, la plus ancienne course à bord devient la nouvelle principale
  IF r.anchor_ride_id IS NULL THEN
    UPDATE public.rides SET anchor_ride_id = (
      SELECT x.id FROM public.rides x WHERE x.anchor_ride_id=_ride_id AND x.status IN ('negotiating','onboard') ORDER BY x.started_negotiation_at LIMIT 1)
    WHERE anchor_ride_id=_ride_id AND status IN ('negotiating','onboard');
    UPDATE public.rides SET anchor_ride_id=NULL WHERE id = (SELECT anchor_ride_id FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard') AND anchor_ride_id IS NOT NULL LIMIT 1);
  END IF;
  RETURN 'completed';
END $$;
REVOKE EXECUTE ON FUNCTION public.drop_off_ride(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.drop_off_ride(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.forbid_duplicate_active_ride()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.rides WHERE client_phone = NEW.client_phone
             AND status IN ('pending','negotiating','onboard') AND id <> NEW.id) THEN
    RAISE EXCEPTION 'ACTIVE_RIDE_EXISTS' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.sync_ride_public_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE; e record;
BEGIN
  IF NEW.chauffeur_id IS NOT NULL AND NEW.status IN ('negotiating','onboard') THEN
    SELECT * INTO d FROM public.drivers WHERE user_id = NEW.chauffeur_id;
  END IF;
  IF NEW.status = 'negotiating' THEN
    SELECT * INTO e FROM public.compute_eta(d.last_lat, d.last_lng, NEW.pickup_lat, NEW.pickup_lng);
  END IF;
  INSERT INTO public.ride_public_status (ride_id, status, chauffeur_first_name, vehicle_model, vehicle_plate, chauffeur_phone, eta_minutes, driver_distance_km, updated_at)
  VALUES (NEW.id, NEW.status, d.first_name, d.vehicle_model, d.vehicle_plate, d.phone, e.minutes, e.km, now())
  ON CONFLICT (ride_id) DO UPDATE SET status = EXCLUDED.status,
    chauffeur_first_name = EXCLUDED.chauffeur_first_name, vehicle_model = EXCLUDED.vehicle_model,
    vehicle_plate = EXCLUDED.vehicle_plate, chauffeur_phone = EXCLUDED.chauffeur_phone,
    eta_minutes = EXCLUDED.eta_minutes, driver_distance_km = EXCLUDED.driver_distance_km, updated_at = now();
  RETURN NEW;
END $$;

-- Position : ETA vers le client en négociation (le plus récent)
CREATE OR REPLACE FUNCTION public.update_driver_position(_lat double precision, _lng double precision)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE; e record;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  UPDATE public.drivers SET last_lat=_lat, last_lng=_lng, last_seen_at=now() WHERE user_id=auth.uid();
  SELECT * INTO r FROM public.rides WHERE chauffeur_id=auth.uid() AND status='negotiating' ORDER BY started_negotiation_at DESC LIMIT 1;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO e FROM public.compute_eta(_lat, _lng, r.pickup_lat, r.pickup_lng);
  UPDATE public.ride_public_status SET eta_minutes=e.minutes, driver_distance_km=e.km, updated_at=now() WHERE ride_id=r.id;
  RETURN e.minutes;
END $$;

CREATE OR REPLACE FUNCTION public.get_public_activity()
RETURNS TABLE(active_passengers bigint, drivers_online bigint, matches_today bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    (SELECT count(*) FROM public.rides WHERE status IN ('pending','negotiating','onboard') AND NOT is_demo),
    (SELECT count(*) FROM public.drivers WHERE is_online AND status='approved' AND is_active AND deleted_at IS NULL AND NOT is_demo
       AND (last_seen_at IS NULL OR last_seen_at > now() - interval '15 minutes')),
    (SELECT count(*) FROM public.rides WHERE chauffeur_id IS NOT NULL AND NOT is_demo
       AND created_at >= ((now() AT TIME ZONE 'Africa/Libreville')::date AT TIME ZONE 'Africa/Libreville'));
$$;