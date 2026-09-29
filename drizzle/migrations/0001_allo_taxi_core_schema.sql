-- Chauffeurs (fiche véhicule, modération a priori)
CREATE TABLE public.drivers (
  user_id uuid PRIMARY KEY,
  first_name text NOT NULL,
  phone text NOT NULL,
  vehicle_model text NOT NULL,
  vehicle_plate text NOT NULL,
  has_ac boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','suspended')),
  is_online boolean NOT NULL DEFAULT false,
  last_lat double precision,
  last_lng double precision,
  last_seen_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.drivers TO authenticated;
GRANT ALL ON public.drivers TO service_role;
ALTER TABLE public.drivers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Drivers read own" ON public.drivers FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Drivers register own pending" ON public.drivers FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid() AND status = 'pending');
CREATE POLICY "Superadmin reads drivers" ON public.drivers FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'super_admin'));
CREATE POLICY "Superadmin manages drivers" ON public.drivers FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'super_admin')) WITH CHECK (public.has_role(auth.uid(),'super_admin'));

-- Courses
CREATE TABLE public.rides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  access_token uuid NOT NULL,
  client_name text NOT NULL,
  client_phone text NOT NULL,
  pickup_location text NOT NULL,
  dropoff_location text NOT NULL,
  pickup_lat double precision,
  pickup_lng double precision,
  price_proposed integer NOT NULL,
  payment_method text NOT NULL CHECK (payment_method IN ('Espèces','AirtelMoney','MoovMoney')),
  wants_ac boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','negotiating','completed','canceled')),
  chauffeur_id uuid,
  started_negotiation_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rides_price_range CHECK (price_proposed BETWEEN 500 AND 100000),
  CONSTRAINT rides_name_len CHECK (char_length(client_name) BETWEEN 2 AND 40),
  CONSTRAINT rides_phone_fmt CHECK (client_phone ~ '^\+241[0-9]{8,9}$'),
  CONSTRAINT rides_loc_len CHECK (char_length(pickup_location) BETWEEN 3 AND 120 AND char_length(dropoff_location) BETWEEN 3 AND 120)
);
CREATE INDEX rides_status_idx ON public.rides (status, created_at DESC);
GRANT INSERT ON public.rides TO anon, authenticated;
GRANT SELECT ON public.rides TO authenticated;
GRANT ALL ON public.rides TO service_role;
ALTER TABLE public.rides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public express ride publication" ON public.rides FOR INSERT TO anon, authenticated
  WITH CHECK (status = 'pending' AND chauffeur_id IS NULL AND started_negotiation_at IS NULL AND resolved_at IS NULL);
CREATE POLICY "Assigned driver reads ride" ON public.rides FOR SELECT TO authenticated USING (chauffeur_id = auth.uid());
CREATE POLICY "Superadmin reads rides" ON public.rides FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'super_admin'));

-- Statut public sans donnée personnelle (écouté en temps réel par le client via l'ID)
CREATE TABLE public.ride_public_status (
  ride_id uuid PRIMARY KEY REFERENCES public.rides(id) ON DELETE CASCADE,
  status text NOT NULL,
  chauffeur_first_name text,
  vehicle_model text,
  vehicle_plate text,
  chauffeur_phone text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.ride_public_status TO anon, authenticated;
GRANT ALL ON public.ride_public_status TO service_role;
ALTER TABLE public.ride_public_status ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Status readable by ride id" ON public.ride_public_status FOR SELECT TO anon, authenticated USING (true);
ALTER TABLE public.ride_public_status REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.ride_public_status;

-- Registre d'audit indélébile
CREATE TABLE public.ride_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id uuid NOT NULL,
  client_name text NOT NULL,
  client_phone text NOT NULL,
  chauffeur_id uuid,
  chauffeur_name text,
  chauffeur_phone text,
  vehicle_plate text,
  pickup_location text NOT NULL,
  dropoff_location text NOT NULL,
  proposed_price integer NOT NULL,
  payment_method text,
  wants_ac boolean,
  published_at timestamptz,
  matched_at timestamptz,
  resolved_at timestamptz NOT NULL DEFAULT now(),
  resolution_status text NOT NULL CHECK (resolution_status IN ('completed','canceled','timeout'))
);
GRANT SELECT ON public.ride_logs TO authenticated;
GRANT ALL ON public.ride_logs TO service_role;
ALTER TABLE public.ride_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Superadmin reads logs" ON public.ride_logs FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'super_admin'));
CREATE OR REPLACE FUNCTION public.forbid_ride_log_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'ride_logs est indélébile'; END $$;
CREATE TRIGGER ride_logs_immutable BEFORE UPDATE OR DELETE ON public.ride_logs FOR EACH ROW EXECUTE FUNCTION public.forbid_ride_log_mutation();

-- Abonnements journaliers XFin
CREATE TABLE public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL,
  day date NOT NULL DEFAULT (now() AT TIME ZONE 'Africa/Libreville')::date,
  amount integer NOT NULL DEFAULT 1000,
  provider text NOT NULL DEFAULT 'XFin',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','refunded')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (driver_id, day)
);
GRANT SELECT ON public.subscriptions TO authenticated;
GRANT ALL ON public.subscriptions TO service_role;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Driver reads own subscriptions" ON public.subscriptions FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "Superadmin reads subscriptions" ON public.subscriptions FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'super_admin'));

-- Associés
CREATE TABLE public.associates_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_key text NOT NULL UNIQUE CHECK (partner_key IN ('xfin','promoteur')),
  user_id uuid,
  display_name text NOT NULL,
  phone text NOT NULL,
  share_percent numeric(5,2) NOT NULL CHECK (share_percent BETWEEN 0 AND 100),
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.associates_settings TO authenticated;
GRANT ALL ON public.associates_settings TO service_role;
ALTER TABLE public.associates_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Superadmin manages associates" ON public.associates_settings FOR ALL TO authenticated USING (public.has_role(auth.uid(),'super_admin')) WITH CHECK (public.has_role(auth.uid(),'super_admin'));
CREATE POLICY "Associate reads own settings" ON public.associates_settings FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Paramètres système
CREATE TABLE public.system_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.system_settings TO authenticated;
GRANT ALL ON public.system_settings TO service_role;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated read settings" ON public.system_settings FOR SELECT TO authenticated USING (true);
CREATE POLICY "Superadmin manages settings" ON public.system_settings FOR ALL TO authenticated USING (public.has_role(auth.uid(),'super_admin')) WITH CHECK (public.has_role(auth.uid(),'super_admin'));

-- Pénalités chauffeurs
CREATE TABLE public.driver_penalties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL,
  ride_id uuid,
  reason text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.driver_penalties TO authenticated;
GRANT ALL ON public.driver_penalties TO service_role;
ALTER TABLE public.driver_penalties ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Driver reads own penalties" ON public.driver_penalties FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "Superadmin manages penalties" ON public.driver_penalties FOR ALL TO authenticated USING (public.has_role(auth.uid(),'super_admin')) WITH CHECK (public.has_role(auth.uid(),'super_admin'));

-- Synchronisation du statut public
CREATE OR REPLACE FUNCTION public.sync_ride_public_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE;
BEGIN
  IF NEW.chauffeur_id IS NOT NULL AND NEW.status = 'negotiating' THEN
    SELECT * INTO d FROM public.drivers WHERE user_id = NEW.chauffeur_id;
  END IF;
  INSERT INTO public.ride_public_status (ride_id, status, chauffeur_first_name, vehicle_model, vehicle_plate, chauffeur_phone, updated_at)
  VALUES (NEW.id, NEW.status, d.first_name, d.vehicle_model, d.vehicle_plate, d.phone, now())
  ON CONFLICT (ride_id) DO UPDATE SET status = EXCLUDED.status,
    chauffeur_first_name = EXCLUDED.chauffeur_first_name, vehicle_model = EXCLUDED.vehicle_model,
    vehicle_plate = EXCLUDED.vehicle_plate, chauffeur_phone = EXCLUDED.chauffeur_phone, updated_at = now();
  RETURN NEW;
END $$;
CREATE TRIGGER rides_sync_public AFTER INSERT OR UPDATE OF status, chauffeur_id ON public.rides FOR EACH ROW EXECUTE FUNCTION public.sync_ride_public_status();

-- Helpers internes
CREATE OR REPLACE FUNCTION public.is_active_driver(_uid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_uid,'chauffeur') AND EXISTS (SELECT 1 FROM public.drivers WHERE user_id=_uid AND status='approved' AND is_active AND deleted_at IS NULL)
$$;

CREATE OR REPLACE FUNCTION public.log_ride_resolution(_ride public.rides, _resolution text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE;
BEGIN
  SELECT * INTO d FROM public.drivers WHERE user_id = _ride.chauffeur_id;
  INSERT INTO public.ride_logs (ride_id, client_name, client_phone, chauffeur_id, chauffeur_name, chauffeur_phone, vehicle_plate,
    pickup_location, dropoff_location, proposed_price, payment_method, wants_ac, published_at, matched_at, resolution_status)
  VALUES (_ride.id, _ride.client_name, _ride.client_phone, _ride.chauffeur_id, d.first_name, d.phone, d.vehicle_plate,
    _ride.pickup_location, _ride.dropoff_location, _ride.price_proposed, _ride.payment_method, _ride.wants_ac,
    _ride.created_at, _ride.started_negotiation_at, _resolution);
END $$;
REVOKE ALL ON FUNCTION public.log_ride_resolution(public.rides, text) FROM PUBLIC, anon, authenticated;

-- Libération des négociations expirées (15 min)
CREATE OR REPLACE FUNCTION public.check_and_purge_negotiation_timeouts() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE; n integer := 0;
BEGIN
  FOR r IN SELECT * FROM public.rides WHERE status='negotiating' AND started_negotiation_at < now() - interval '15 minutes' FOR UPDATE SKIP LOCKED LOOP
    PERFORM public.log_ride_resolution(r, 'timeout');
    INSERT INTO public.driver_penalties (driver_id, ride_id, reason) VALUES (r.chauffeur_id, r.id, 'Négociation non clôturée sous 15 minutes');
    UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, updated_at=now() WHERE id=r.id;
    n := n + 1;
  END LOOP;
  -- Expiration des demandes non prises après 2 h
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now() WHERE status='pending' AND created_at < now() - interval '2 hours';
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.check_and_purge_negotiation_timeouts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_and_purge_negotiation_timeouts() TO authenticated;

-- Client : annulation avec jeton secret
CREATE OR REPLACE FUNCTION public.cancel_ride_public(_ride_id uuid, _token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now()
  WHERE id=_ride_id AND access_token=_token AND status='pending';
  RETURN FOUND;
END $$;
GRANT EXECUTE ON FUNCTION public.cancel_ride_public(uuid, uuid) TO anon, authenticated;

-- Chauffeur : activation du jour (paiement XFin simulé)
CREATE OR REPLACE FUNCTION public.activate_driver_day() RETURNS date
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  INSERT INTO public.subscriptions (driver_id, day) VALUES (auth.uid(), today) ON CONFLICT DO NOTHING;
  RETURN today;
END $$;
GRANT EXECUTE ON FUNCTION public.activate_driver_day() TO authenticated;

-- Chauffeur : pool localisé
CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision DEFAULT 5)
RETURNS TABLE (id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE; today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=today AND s.status='active') THEN
    RAISE EXCEPTION 'Abonnement du jour inactif';
  END IF;
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=_lat, last_lng=_lng, last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL THEN NULL
      ELSE 6371 * 2 * asin(sqrt(power(sin(radians(r.pickup_lat-_lat)/2),2) + cos(radians(_lat))*cos(radians(r.pickup_lat))*power(sin(radians(r.pickup_lng-_lng)/2),2))) END AS distance_km,
    r.created_at
  FROM public.rides r
  WHERE r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
  AND (r.pickup_lat IS NULL OR _lat IS NULL OR 6371 * 2 * asin(sqrt(power(sin(radians(r.pickup_lat-_lat)/2),2) + cos(radians(_lat))*cos(radians(r.pickup_lat))*power(sin(radians(r.pickup_lng-_lng)/2),2))) <= _radius_km)
  ORDER BY distance_km NULLS LAST, r.created_at DESC
  LIMIT 30;
END $$;
GRANT EXECUTE ON FUNCTION public.get_localized_pool_for_driver(double precision, double precision, double precision) TO authenticated;

-- Chauffeur : prise de course atomique
CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
RETURNS TABLE (id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF EXISTS (SELECT 1 FROM public.rides WHERE chauffeur_id=auth.uid() AND status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=(now() AT TIME ZONE 'Africa/Libreville')::date) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  UPDATE public.rides r SET status='negotiating', chauffeur_id=auth.uid(), started_negotiation_at=now(), updated_at=now()
  WHERE r.id=_ride_id AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $$;
GRANT EXECUTE ON FUNCTION public.take_ride(uuid) TO authenticated;

-- Chauffeur : clôture + journalisation
CREATE OR REPLACE FUNCTION public.close_ride(_ride_id uuid, _success boolean) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id=_ride_id AND chauffeur_id=auth.uid() AND status='negotiating' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course introuvable'; END IF;
  PERFORM public.log_ride_resolution(r, CASE WHEN _success THEN 'completed' ELSE 'canceled' END);
  IF _success THEN
    UPDATE public.rides SET status='completed', resolved_at=now(), updated_at=now() WHERE id=_ride_id;
    RETURN 'completed';
  END IF;
  -- Échec : la demande retourne dans le pool pour être republiée
  UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, updated_at=now() WHERE id=_ride_id;
  RETURN 'released';
END $$;
GRANT EXECUTE ON FUNCTION public.close_ride(uuid, boolean) TO authenticated;

-- Superadmin : export complet du registre
CREATE OR REPLACE FUNCTION public.export_full_ride_logs() RETURNS SETOF public.ride_logs
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  RETURN QUERY SELECT * FROM public.ride_logs ORDER BY resolved_at DESC;
END $$;
GRANT EXECUTE ON FUNCTION public.export_full_ride_logs() TO authenticated;

-- Superadmin : validation d'un chauffeur
CREATE OR REPLACE FUNCTION public.approve_driver(_user_id uuid, _approve boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  UPDATE public.drivers SET status = CASE WHEN _approve THEN 'approved' ELSE 'suspended' END, updated_at=now() WHERE user_id=_user_id;
  IF _approve THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (_user_id,'chauffeur')
    ON CONFLICT (user_id, role) DO UPDATE SET is_active=true, deleted_at=NULL, updated_at=now();
  ELSE
    UPDATE public.user_roles SET is_active=false, updated_at=now() WHERE user_id=_user_id AND role='chauffeur';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.approve_driver(uuid, boolean) TO authenticated;

-- Amorçage : le premier compte connecté peut devenir Superadmin tant qu'aucun n'existe
CREATE OR REPLACE FUNCTION public.claim_first_superadmin() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(424242);
  IF EXISTS (SELECT 1 FROM public.user_roles WHERE role='super_admin' AND is_active AND deleted_at IS NULL) THEN RETURN false; END IF;
  INSERT INTO public.user_roles (user_id, role) VALUES (auth.uid(),'super_admin') ON CONFLICT DO NOTHING;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION public.claim_first_superadmin() TO authenticated;

-- Répartition financière au prorata (Superadmin : tout ; Associé : sa part seulement)
CREATE OR REPLACE FUNCTION public.financial_dashboard_split()
RETURNS TABLE (month date, gross_revenue bigint, today_revenue bigint, active_drivers_today bigint, partner_key text, display_name text, share_percent numeric, partner_amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE is_admin boolean := public.has_role(auth.uid(),'super_admin');
  today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT is_admin AND NOT public.has_role(auth.uid(),'associe') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  RETURN QUERY
  WITH months AS (
    SELECT date_trunc('month', s.day)::date AS m, sum(s.amount)::bigint AS gross
    FROM public.subscriptions s WHERE s.status='active' AND s.day >= (date_trunc('month', today) - interval '5 months')::date
    GROUP BY 1
  ), td AS (
    SELECT coalesce(sum(amount),0)::bigint AS rev, count(*)::bigint AS n FROM public.subscriptions WHERE day=today AND status='active'
  ), parts AS (
    SELECT a.partner_key, a.display_name, a.share_percent FROM public.associates_settings a
    WHERE a.is_active AND a.deleted_at IS NULL AND (is_admin OR a.user_id = auth.uid())
  )
  SELECT m.m,
    CASE WHEN is_admin THEN m.gross ELSE NULL END,
    CASE WHEN is_admin THEN td.rev ELSE NULL END,
    CASE WHEN is_admin THEN td.n ELSE NULL END,
    p.partner_key, p.display_name, p.share_percent,
    round(m.gross * p.share_percent / 100, 0)
  FROM months m CROSS JOIN td LEFT JOIN parts p ON true
  UNION ALL
  SELECT today, CASE WHEN is_admin THEN td.rev END, CASE WHEN is_admin THEN td.rev END, CASE WHEN is_admin THEN td.n END,
    p.partner_key, p.display_name, p.share_percent, round(td.rev * p.share_percent / 100, 0)
  FROM td LEFT JOIN parts p ON true
  WHERE NOT EXISTS (SELECT 1 FROM months);
END $$;
GRANT EXECUTE ON FUNCTION public.financial_dashboard_split() TO authenticated;

-- Le rôle 'associe' doit pouvoir appeler has_role via RLS : déjà SECURITY DEFINER.
REVOKE EXECUTE ON FUNCTION public.forbid_ride_log_mutation() FROM PUBLIC;
