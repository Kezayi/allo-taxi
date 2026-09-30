CREATE OR REPLACE FUNCTION public.sync_ride_public_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE d public.drivers%ROWTYPE; v_min integer; v_km double precision;
BEGIN
  IF NEW.chauffeur_id IS NOT NULL AND NEW.status IN ('negotiating','onboard') THEN
    SELECT * INTO d FROM public.drivers WHERE user_id = NEW.chauffeur_id;
  END IF;
  IF NEW.status = 'negotiating' THEN
    SELECT c.minutes, c.km INTO v_min, v_km FROM public.compute_eta(d.last_lat, d.last_lng, NEW.pickup_lat, NEW.pickup_lng) c;
  END IF;
  INSERT INTO public.ride_public_status (ride_id, status, chauffeur_first_name, vehicle_model, vehicle_plate, chauffeur_phone, eta_minutes, driver_distance_km, updated_at)
  VALUES (NEW.id, NEW.status, d.first_name, d.vehicle_model, d.vehicle_plate, d.phone, v_min, v_km, now())
  ON CONFLICT (ride_id) DO UPDATE SET status = EXCLUDED.status,
    chauffeur_first_name = EXCLUDED.chauffeur_first_name, vehicle_model = EXCLUDED.vehicle_model,
    vehicle_plate = EXCLUDED.vehicle_plate, chauffeur_phone = EXCLUDED.chauffeur_phone,
    eta_minutes = EXCLUDED.eta_minutes, driver_distance_km = EXCLUDED.driver_distance_km, updated_at = now();
  RETURN NEW;
END $function$;
REVOKE EXECUTE ON FUNCTION public.sync_ride_public_status() FROM PUBLIC, anon, authenticated;