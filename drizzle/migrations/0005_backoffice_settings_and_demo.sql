ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.ride_logs ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.driver_penalties ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

-- ride_logs stays immutable, except demo rows during an explicit demo reset
CREATE OR REPLACE FUNCTION public.forbid_ride_log_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.is_demo AND current_setting('app.demo_reset', true) = 'on' THEN RETURN OLD; END IF;
  RAISE EXCEPTION 'ride_logs est indélébile';
END $$;

CREATE OR REPLACE FUNCTION public.setting_num(_key text, _default numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT (value #>> '{}')::numeric FROM public.system_settings WHERE key=_key), _default)
$$;

CREATE OR REPLACE FUNCTION public.update_system_settings(_daily_price integer, _radius_km numeric, _timeout_min integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  IF _daily_price < 100 OR _daily_price > 100000 OR _radius_km < 0.5 OR _radius_km > 50 OR _timeout_min < 1 OR _timeout_min > 240 THEN RAISE EXCEPTION 'Valeurs hors limites'; END IF;
  INSERT INTO public.system_settings(key,value,updated_at) VALUES
    ('daily_price', to_jsonb(_daily_price), now()), ('search_radius_km', to_jsonb(_radius_km), now()), ('negotiation_timeout_min', to_jsonb(_timeout_min), now())
  ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now();
END $$;

CREATE OR REPLACE FUNCTION public.activate_driver_day()
RETURNS date LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  INSERT INTO public.subscriptions (driver_id, day, amount) VALUES (auth.uid(), today, public.setting_num('daily_price',1000)::int) ON CONFLICT DO NOTHING;
  RETURN today;
END $$;

CREATE OR REPLACE FUNCTION public.check_and_purge_negotiation_timeouts()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides%ROWTYPE; n integer := 0; lim interval := make_interval(mins => public.setting_num('negotiation_timeout_min',15)::int);
BEGIN
  FOR r IN SELECT * FROM public.rides WHERE status='negotiating' AND started_negotiation_at < now() - lim FOR UPDATE SKIP LOCKED LOOP
    PERFORM public.log_ride_resolution(r, 'timeout');
    INSERT INTO public.driver_penalties (driver_id, ride_id, reason, is_demo) VALUES (r.chauffeur_id, r.id, 'Négociation non clôturée dans le délai', r.is_demo);
    UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, updated_at=now() WHERE id=r.id;
    n := n + 1;
  END LOOP;
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now() WHERE status='pending' AND created_at < now() - interval '2 hours' AND NOT is_demo;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision DEFAULT NULL)
RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE; today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=today AND s.status='active') THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=_lat, last_lng=_lng, last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL THEN NULL
      ELSE 6371 * 2 * asin(sqrt(power(sin(radians(r.pickup_lat-_lat)/2),2) + cos(radians(_lat))*cos(radians(r.pickup_lat))*power(sin(radians(r.pickup_lng-_lng)/2),2))) END,
    r.created_at
  FROM public.rides r
  WHERE r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
  AND (r.pickup_lat IS NULL OR _lat IS NULL OR 6371 * 2 * asin(sqrt(power(sin(radians(r.pickup_lat-_lat)/2),2) + cos(radians(_lat))*cos(radians(r.pickup_lat))*power(sin(radians(r.pickup_lng-_lng)/2),2))) <= rad)
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $$;

CREATE OR REPLACE FUNCTION public.set_driver_active(_user_id uuid, _active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  UPDATE public.drivers SET is_active=_active, is_online = CASE WHEN _active THEN is_online ELSE false END, updated_at=now() WHERE user_id=_user_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_penalty_active(_id uuid, _active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  UPDATE public.driver_penalties SET is_active=_active WHERE id=_id;
END $$;

CREATE OR REPLACE FUNCTION public.reset_demo_data()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  PERFORM set_config('app.demo_reset','on',true);
  DELETE FROM public.ride_logs WHERE is_demo;
  DELETE FROM public.driver_penalties WHERE is_demo;
  DELETE FROM public.subscriptions WHERE is_demo;
  DELETE FROM public.rides WHERE is_demo;
  DELETE FROM public.drivers WHERE is_demo;
  PERFORM set_config('app.demo_reset','off',true);
END $$;

CREATE OR REPLACE FUNCTION public.load_demo_data()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ids uuid[] := ARRAY(SELECT gen_random_uuid() FROM generate_series(1,8));
  names text[] := ARRAY['Michel','Junior','Cédric','Patrick','Hervé','Landry','Ulrich','Brice'];
  phones text[] := ARRAY['+24177452310','+24166128845','+24174903312','+24162457781','+24177018843','+24166734902','+24174556120','+24162981137'];
  models text[] := ARRAY['Toyota Corolla','Hyundai Accent','Toyota Yaris','Kia Rio','Suzuki Dzire','Toyota Corolla','Nissan Sunny','Hyundai i10'];
  plates text[] := ARRAY['1234 G 1A','5521 G 2B','8870 G 1C','3302 G 3A','7719 G 2D','4410 G 1E','6605 G 2F','2298 G 3G'];
  statuses text[] := ARRAY['approved','approved','approved','approved','approved','approved','pending','pending'];
  places text[] := ARRAY['Louis','Nzeng-Ayong','Charbonnages','PK8','Glass','Owendo','Akébé','Batterie IV','Mont-Bouët','Oloumi','Lalala','Angondjé','Aéroport Léon Mba','Rond-point de la Démocratie'];
  clients text[] := ARRAY['Amina','Mireille','Sandrine','David','Grâce','Yannick','Prisca','Stève','Nadège','Fabrice'];
  pays text[] := ARRAY['Espèces','AirtelMoney','MoovMoney'];
  today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  price int := public.setting_num('daily_price',1000)::int;
  i int; d int; rid uuid; t timestamptz; res text;
BEGIN
  IF NOT public.has_role(auth.uid(),'super_admin') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  PERFORM public.reset_demo_data();
  FOR i IN 1..8 LOOP
    INSERT INTO public.drivers(user_id, first_name, phone, vehicle_model, vehicle_plate, has_ac, status, is_online, last_lat, last_lng, last_seen_at, is_demo, created_at)
    VALUES (ids[i], names[i], phones[i], models[i], plates[i], i % 3 <> 0, statuses[i], i <= 4, 0.39 + random()*0.06, 9.43 + random()*0.06, now() - (i || ' minutes')::interval, true, now() - (i*3 || ' days')::interval);
  END LOOP;
  -- Daily subscriptions over ~6 months for approved drivers
  FOR d IN 0..170 LOOP
    FOR i IN 1..6 LOOP
      IF d = 0 AND i > 4 THEN CONTINUE; END IF;
      IF d > 0 AND random() < 0.3 THEN CONTINUE; END IF;
      INSERT INTO public.subscriptions(driver_id, day, amount, is_demo) VALUES (ids[i], today - d, price, true) ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;
  -- Live rides: pending
  FOR i IN 1..3 LOOP
    INSERT INTO public.rides(access_token, client_name, client_phone, pickup_location, dropoff_location, pickup_lat, pickup_lng, price_proposed, payment_method, wants_ac, status, is_demo, created_at)
    VALUES (gen_random_uuid(), clients[i], '+2410774' || lpad((1000+i*37)::text,4,'0'), places[i], places[i+5], 0.40+random()*0.04, 9.44+random()*0.04, 1500 + i*500, pays[1+(i%3)], i=2, 'pending', true, now() - (i*4 || ' minutes')::interval);
  END LOOP;
  -- Live rides: negotiating (one beyond timeout for the alert)
  FOR i IN 1..3 LOOP
    INSERT INTO public.rides(access_token, client_name, client_phone, pickup_location, dropoff_location, price_proposed, payment_method, wants_ac, status, chauffeur_id, started_negotiation_at, is_demo, created_at)
    VALUES (gen_random_uuid(), clients[i+3], '+2410665' || lpad((2000+i*41)::text,4,'0'), places[i+2], places[i+8], 2000 + i*500, pays[1+(i%3)], false, 'negotiating', ids[i], now() - ((CASE WHEN i=3 THEN 22 ELSE i*3 END) || ' minutes')::interval, true, now() - ((CASE WHEN i=3 THEN 25 ELSE i*3+2 END) || ' minutes')::interval);
  END LOOP;
  -- Closed history in ride_logs
  FOR i IN 1..24 LOOP
    rid := gen_random_uuid();
    t := now() - (i*47 || ' minutes')::interval;
    res := CASE WHEN i % 6 = 0 THEN 'timeout' WHEN i % 4 = 0 THEN 'canceled' ELSE 'completed' END;
    d := 1 + (i % 6);
    INSERT INTO public.ride_logs(ride_id, client_name, client_phone, chauffeur_id, chauffeur_name, chauffeur_phone, vehicle_plate, pickup_location, dropoff_location, proposed_price, payment_method, wants_ac, published_at, matched_at, resolved_at, resolution_status, is_demo)
    VALUES (rid, clients[1+(i%10)], '+2410774' || lpad((3000+i*13)::text,4,'0'), ids[d], names[d], phones[d], plates[d], places[1+(i%14)], places[1+((i+6)%14)], 1500 + (i%6)*500, pays[1+(i%3)], i%2=0, t - interval '3 minutes', t - interval '2 minutes', t, res, true);
    IF res = 'timeout' THEN
      INSERT INTO public.driver_penalties(driver_id, ride_id, reason, is_demo, created_at) VALUES (ids[d], rid, 'Négociation non clôturée dans le délai', true, t);
    END IF;
  END LOOP;
  INSERT INTO public.driver_penalties(driver_id, reason, is_demo, created_at) VALUES
    (ids[2], 'Annulations abusives répétées (3 en 24 h)', true, now() - interval '1 day'),
    (ids[5], 'Suspension temporaire : comportement signalé par un client', true, now() - interval '3 days');
END $$;

GRANT EXECUTE ON FUNCTION public.update_system_settings(integer, numeric, integer), public.set_driver_active(uuid, boolean), public.set_penalty_active(uuid, boolean), public.reset_demo_data(), public.load_demo_data() TO authenticated;