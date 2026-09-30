-- LOT 0B : sécurisation (C1, C2, C3, C4, C5, anon). C6 volontairement NON appliqué.

-- ========== C1 : suivi Client par jeton ==========
CREATE OR REPLACE FUNCTION public.get_ride_status(_ride_id uuid, _token uuid)
RETURNS TABLE(status text, chauffeur_first_name text, vehicle_model text, vehicle_plate text,
              chauffeur_phone text, eta_minutes integer, driver_distance_km double precision, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT s.status, s.chauffeur_first_name, s.vehicle_model, s.vehicle_plate,
         s.chauffeur_phone, s.eta_minutes, s.driver_distance_km, s.updated_at
  FROM public.rides r
  JOIN public.ride_public_status s ON s.ride_id = r.id
  WHERE r.id = _ride_id AND _token IS NOT NULL AND r.access_token = _token
  LIMIT 1
$$;

DROP POLICY IF EXISTS "Status readable by ride id" ON public.ride_public_status;
ALTER PUBLICATION supabase_realtime DROP TABLE public.ride_public_status;

-- ========== C2 : création de course côté serveur ==========
CREATE OR REPLACE FUNCTION public.create_ride_public(
  _client_name text, _client_phone text, _pickup_location text, _dropoff_location text,
  _price integer, _payment_method text, _wants_ac boolean, _allow_sharing boolean,
  _pickup_lat double precision DEFAULT NULL, _pickup_lng double precision DEFAULT NULL,
  _dropoff_lat double precision DEFAULT NULL, _dropoff_lng double precision DEFAULT NULL)
RETURNS TABLE(id uuid, token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text := btrim(coalesce(_client_name, ''));
  v_phone text := btrim(coalesce(_client_phone, ''));
  v_pickup text := btrim(coalesce(_pickup_location, ''));
  v_drop text := btrim(coalesce(_dropoff_location, ''));
  v_id uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
BEGIN
  IF char_length(v_name) NOT BETWEEN 2 AND 40
     OR v_phone !~ '^\+241[0-9]{8,9}$'
     OR char_length(v_pickup) NOT BETWEEN 3 AND 120
     OR char_length(v_drop) NOT BETWEEN 3 AND 120
     OR _price IS NULL OR _price NOT BETWEEN 500 AND 100000
     OR _payment_method IS NULL OR _payment_method NOT IN ('Espèces','AirtelMoney','MoovMoney')
     OR _wants_ac IS NULL OR _allow_sharing IS NULL
     OR ((_pickup_lat IS NULL) <> (_pickup_lng IS NULL))
     OR ((_dropoff_lat IS NULL) <> (_dropoff_lng IS NULL))
     OR (_pickup_lat IS NOT NULL AND (_pickup_lat NOT BETWEEN -90 AND 90 OR _pickup_lng NOT BETWEEN -180 AND 180))
     OR (_dropoff_lat IS NOT NULL AND (_dropoff_lat NOT BETWEEN -90 AND 90 OR _dropoff_lng NOT BETWEEN -180 AND 180))
     OR 'NaN'::float8 IN (_pickup_lat, _pickup_lng, _dropoff_lat, _dropoff_lng)
  THEN
    RAISE EXCEPTION 'INVALID_DATA' USING ERRCODE = 'P0001';
  END IF;

  -- Sérialise les créations d'un même numéro (évite les courses concurrentes)
  PERFORM pg_advisory_xact_lock(hashtext('create_ride:' || v_phone));

  IF EXISTS (SELECT 1 FROM public.rides r WHERE r.client_phone = v_phone
             AND r.status IN ('pending','negotiating','onboard')) THEN
    RAISE EXCEPTION 'ACTIVE_RIDE_EXISTS' USING ERRCODE = 'P0001';
  END IF;

  IF (SELECT count(*) FROM public.rides r WHERE r.client_phone = v_phone
      AND r.created_at > now() - interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'RATE_LIMITED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.rides (id, access_token, client_name, client_phone, pickup_location, dropoff_location,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, price_proposed, payment_method, wants_ac, allow_sharing,
    status, chauffeur_id, started_negotiation_at, resolved_at, boarded_at, anchor_ride_id, is_demo, created_at, updated_at)
  VALUES (v_id, v_token, v_name, v_phone, v_pickup, v_drop,
    _pickup_lat, _pickup_lng, _dropoff_lat, _dropoff_lng, _price, _payment_method, _wants_ac, _allow_sharing,
    'pending', NULL, NULL, NULL, NULL, NULL, false, now(), now());

  RETURN QUERY SELECT v_id, v_token;
END $$;

CREATE INDEX IF NOT EXISTS rides_phone_created_idx ON public.rides (client_phone, created_at DESC);

DROP POLICY IF EXISTS "Public express ride publication" ON public.rides;

-- ========== C3 : cloisonnement Associé ==========
DROP POLICY IF EXISTS "Administrators can read all profiles" ON public.profiles;
CREATE POLICY "Superadmin reads all profiles" ON public.profiles
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));
DROP POLICY IF EXISTS "Administrators can read all roles" ON public.user_roles;
CREATE POLICY "Superadmin reads all roles" ON public.user_roles
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'super_admin'::public.app_role));

-- ========== C4 : system_settings réservé au Superadmin ==========
DROP POLICY IF EXISTS "Authenticated read settings" ON public.system_settings;
-- (la policy "Superadmin manages settings" FOR ALL couvre la lecture superadmin)

-- ========== C5 : droits EXECUTE (moindre privilège) ==========
-- 1) Tout retirer à PUBLIC / anon / authenticated
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
  END LOOP;
END $$;

-- 2) anon : uniquement le parcours public
GRANT EXECUTE ON FUNCTION public.get_public_activity() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_ride_public(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.superadmin_exists() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_ride_public(text, text, text, text, integer, text, boolean, boolean, double precision, double precision, double precision, double precision) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_ride_status(uuid, uuid) TO anon, authenticated;

-- 3) authenticated : Chauffeur / Superadmin / Associé (chaque RPC vérifie le rôle en interne)
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated;
GRANT EXECUTE ON FUNCTION public.activate_driver_day() TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_driver(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_purge_negotiation_timeouts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_first_superadmin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_ride(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_anchor_ride(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.drop_off_ride(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.export_full_ride_logs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.financial_dashboard_split() TO authenticated;
GRANT EXECUTE ON FUNCTION public.financial_today_split() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_localized_pool_for_driver(double precision, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_driver(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_demo_data() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_demo_data() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_driver_active(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_driver_availability(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_penalty_active(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_shared_rides_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.shared_rides_enabled() TO authenticated;
GRANT EXECUTE ON FUNCTION public.take_ride(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_driver_position(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_system_settings(integer, numeric, integer) TO authenticated;
-- Non réattribuées (usage interne uniquement, appelées par des fonctions SECURITY DEFINER propriété de postgres
-- ou par des triggers) : setting_num, log_ride_resolution, sync_ride_public_status, forbid_duplicate_active_ride,
-- forbid_ride_log_mutation, bearing_deg, km_between, compute_eta, ride_same_direction.

-- Fonctions futures : pas d'EXECUTE implicite à PUBLIC
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- ========== Droits directs du rôle anon ==========
REVOKE ALL ON public.ride_public_status, public.rides, public.profiles, public.user_roles, public.drivers,
  public.subscriptions, public.driver_penalties, public.associates_settings, public.system_settings,
  public.ride_logs FROM anon;