ALTER TABLE public.ride_public_status ADD COLUMN IF NOT EXISTS eta_minutes integer, ADD COLUMN IF NOT EXISTS driver_distance_km double precision;

CREATE OR REPLACE FUNCTION public.compute_eta(_lat1 double precision, _lng1 double precision, _lat2 double precision, _lng2 double precision, OUT km double precision, OUT minutes integer)
LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public' AS $$
BEGIN
  IF _lat1 IS NULL OR _lat2 IS NULL THEN km := NULL; minutes := NULL; RETURN; END IF;
  -- distance à vol d'oiseau x1.35 (réseau routier), vitesse urbaine moyenne Libreville 22 km/h
  km := 1.35 * 6371 * 2 * asin(sqrt(power(sin(radians(_lat2-_lat1)/2),2) + cos(radians(_lat1))*cos(radians(_lat2))*power(sin(radians(_lng2-_lng1)/2),2)));
  minutes := greatest(2, ceil(km / 22.0 * 60))::int;
END $$;

CREATE OR REPLACE FUNCTION public.sync_ride_public_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE d public.drivers%ROWTYPE; e record;
BEGIN
  IF NEW.chauffeur_id IS NOT NULL AND NEW.status = 'negotiating' THEN
    SELECT * INTO d FROM public.drivers WHERE user_id = NEW.chauffeur_id;
  END IF;
  SELECT * INTO e FROM public.compute_eta(d.last_lat, d.last_lng, NEW.pickup_lat, NEW.pickup_lng);
  INSERT INTO public.ride_public_status (ride_id, status, chauffeur_first_name, vehicle_model, vehicle_plate, chauffeur_phone, eta_minutes, driver_distance_km, updated_at)
  VALUES (NEW.id, NEW.status, d.first_name, d.vehicle_model, d.vehicle_plate, d.phone, e.minutes, e.km, now())
  ON CONFLICT (ride_id) DO UPDATE SET status = EXCLUDED.status,
    chauffeur_first_name = EXCLUDED.chauffeur_first_name, vehicle_model = EXCLUDED.vehicle_model,
    vehicle_plate = EXCLUDED.vehicle_plate, chauffeur_phone = EXCLUDED.chauffeur_phone,
    eta_minutes = EXCLUDED.eta_minutes, driver_distance_km = EXCLUDED.driver_distance_km, updated_at = now();
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.update_driver_position(_lat double precision, _lng double precision)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r public.rides%ROWTYPE; e record;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  UPDATE public.drivers SET last_lat=_lat, last_lng=_lng, last_seen_at=now() WHERE user_id=auth.uid();
  SELECT * INTO r FROM public.rides WHERE chauffeur_id=auth.uid() AND status='negotiating' LIMIT 1;
  IF r.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO e FROM public.compute_eta(_lat, _lng, r.pickup_lat, r.pickup_lng);
  UPDATE public.ride_public_status SET eta_minutes=e.minutes, driver_distance_km=e.km, updated_at=now() WHERE ride_id=r.id;
  RETURN e.minutes;
END $$;
REVOKE ALL ON FUNCTION public.update_driver_position(double precision, double precision) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_driver_position(double precision, double precision) TO authenticated;