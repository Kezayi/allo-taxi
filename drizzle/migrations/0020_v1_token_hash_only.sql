LOCK TABLE public.rides IN SHARE ROW EXCLUSIVE MODE;

DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM public.rides
   WHERE access_token_hash IS NULL
      OR (access_token IS NOT NULL AND access_token_hash IS DISTINCT FROM extensions.digest(access_token::text,'sha256'));
  IF n > 0 THEN RAISE EXCEPTION 'TOKEN_HASH_PRECHECK_FAILED: % rides', n; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.rides_v1_projection()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_vehicle uuid; v_owner uuid;
BEGIN
  -- Legacy compat: hash only derived from a provided plaintext; NULL plaintext never erases the hash.
  IF NEW.access_token IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.access_token IS DISTINCT FROM OLD.access_token) THEN
    NEW.access_token_hash := extensions.digest(NEW.access_token::text, 'sha256');
  ELSIF TG_OP = 'UPDATE' AND NEW.access_token_hash IS NULL THEN
    NEW.access_token_hash := OLD.access_token_hash;
  END IF;

  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_v2 := CASE NEW.status WHEN 'pending' THEN 'PENDING' WHEN 'negotiating' THEN 'CONTACT_PENDING'
                                     WHEN 'onboard' THEN 'ONBOARD' WHEN 'completed' THEN 'COMPLETED' ELSE NULL END;
    NEW.status_v2_changed_at := CASE WHEN TG_OP = 'INSERT' THEN coalesce(NEW.created_at, now()) ELSE now() END;
  END IF;

  IF (TG_OP = 'INSERT' AND NEW.chauffeur_id IS NOT NULL AND NEW.vehicle_id IS NULL)
     OR (TG_OP = 'UPDATE' AND NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id) THEN
    IF NEW.chauffeur_id IS NULL THEN
      NEW.vehicle_id := NULL;
    ELSE
      SELECT v.id INTO v_vehicle FROM public.drivers d JOIN public.vehicles v
        ON v.id = d.active_vehicle_id AND v.driver_id = d.user_id AND v.deleted_at IS NULL
       WHERE d.user_id = NEW.chauffeur_id;
      NEW.vehicle_id := v_vehicle;
    END IF;
  END IF;

  IF NEW.vehicle_id IS NOT NULL THEN
    IF NEW.chauffeur_id IS NULL THEN
      RAISE EXCEPTION 'RIDE_VEHICLE_WITHOUT_DRIVER' USING ERRCODE = '23514';
    END IF;
    SELECT driver_id INTO v_owner FROM public.vehicles WHERE id = NEW.vehicle_id;
    IF v_owner IS DISTINCT FROM NEW.chauffeur_id THEN
      RAISE EXCEPTION 'RIDE_VEHICLE_NOT_OWNED' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.create_ride_public(_client_name text, _client_phone text, _pickup_location text, _dropoff_location text, _price integer, _payment_method text, _wants_ac boolean, _allow_sharing boolean, _pickup_lat double precision DEFAULT NULL::double precision, _pickup_lng double precision DEFAULT NULL::double precision, _dropoff_lat double precision DEFAULT NULL::double precision, _dropoff_lng double precision DEFAULT NULL::double precision)
 RETURNS TABLE(id uuid, token uuid) LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  PERFORM pg_advisory_xact_lock(hashtext('create_ride:' || v_phone));

  IF EXISTS (SELECT 1 FROM public.rides r WHERE r.client_phone = v_phone
             AND r.status IN ('pending','negotiating','onboard')) THEN
    RAISE EXCEPTION 'ACTIVE_RIDE_EXISTS' USING ERRCODE = 'P0001';
  END IF;

  IF (SELECT count(*) FROM public.rides r WHERE r.client_phone = v_phone
      AND r.created_at > now() - interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'RATE_LIMITED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.rides (id, access_token, access_token_hash, client_name, client_phone, pickup_location, dropoff_location,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, price_proposed, payment_method, wants_ac, allow_sharing,
    status, chauffeur_id, started_negotiation_at, resolved_at, boarded_at, anchor_ride_id, is_demo, created_at, updated_at)
  VALUES (v_id, NULL, extensions.digest(v_token::text, 'sha256'), v_name, v_phone, v_pickup, v_drop,
    _pickup_lat, _pickup_lng, _dropoff_lat, _dropoff_lng, _price, _payment_method, _wants_ac, _allow_sharing,
    'pending', NULL, NULL, NULL, NULL, NULL, false, now(), now());

  RETURN QUERY SELECT v_id, v_token;
END $function$;

CREATE OR REPLACE FUNCTION public.get_ride_status(_ride_id uuid, _token uuid)
 RETURNS TABLE(status text, chauffeur_first_name text, vehicle_model text, vehicle_plate text, chauffeur_phone text, eta_minutes integer, driver_distance_km double precision, updated_at timestamp with time zone)
 LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT s.status, s.chauffeur_first_name, s.vehicle_model, s.vehicle_plate,
         s.chauffeur_phone, s.eta_minutes, s.driver_distance_km, s.updated_at
  FROM public.rides r
  JOIN public.ride_public_status s ON s.ride_id = r.id
  WHERE r.id = _ride_id AND _token IS NOT NULL
    AND r.access_token_hash = extensions.digest(_token::text, 'sha256')
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.cancel_ride_public(_ride_id uuid, _token uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r public.rides;
BEGIN
  IF _token IS NULL THEN RETURN false; END IF;
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now()
  WHERE id=_ride_id AND access_token_hash = extensions.digest(_token::text, 'sha256')
    AND status IN ('pending','negotiating')
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN false; END IF;
  IF r.chauffeur_id IS NOT NULL THEN PERFORM public.log_ride_resolution(r, 'canceled'); END IF;
  RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.load_demo_data()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  FOR d IN 0..170 LOOP
    FOR i IN 1..6 LOOP
      IF d = 0 AND i > 4 THEN CONTINUE; END IF;
      IF d > 0 AND random() < 0.3 THEN CONTINUE; END IF;
      INSERT INTO public.subscriptions(driver_id, day, amount, is_demo) VALUES (ids[i], today - d, price, true) ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;
  FOR i IN 1..3 LOOP
    INSERT INTO public.rides(access_token, access_token_hash, client_name, client_phone, pickup_location, dropoff_location, pickup_lat, pickup_lng, price_proposed, payment_method, wants_ac, status, is_demo, created_at)
    VALUES (NULL, extensions.digest(gen_random_uuid()::text,'sha256'), clients[i], '+2410774' || lpad((1000+i*37)::text,4,'0'), places[i], places[i+5], 0.40+random()*0.04, 9.44+random()*0.04, 1500 + i*500, pays[1+(i%3)], i=2, 'pending', true, now() - (i*4 || ' minutes')::interval);
  END LOOP;
  FOR i IN 1..3 LOOP
    INSERT INTO public.rides(access_token, access_token_hash, client_name, client_phone, pickup_location, dropoff_location, price_proposed, payment_method, wants_ac, status, chauffeur_id, started_negotiation_at, is_demo, created_at)
    VALUES (NULL, extensions.digest(gen_random_uuid()::text,'sha256'), clients[i+3], '+2410665' || lpad((2000+i*41)::text,4,'0'), places[i+2], places[i+8], 2000 + i*500, pays[1+(i%3)], false, 'negotiating', ids[i], now() - ((CASE WHEN i=3 THEN 22 ELSE i*3 END) || ' minutes')::interval, true, now() - ((CASE WHEN i=3 THEN 25 ELSE i*3+2 END) || ' minutes')::interval);
  END LOOP;
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
END $function$;

ALTER TABLE public.rides ALTER COLUMN access_token_hash SET NOT NULL;
ALTER TABLE public.rides ADD CONSTRAINT rides_access_token_hash_len CHECK (octet_length(access_token_hash) = 32);
ALTER TABLE public.rides ALTER COLUMN access_token DROP NOT NULL;
COMMENT ON COLUMN public.rides.access_token IS 'DEPRECATED — ancien stockage du secret Client ; ne doit plus être utilisé pour authentifier une course ; la vérification utilise access_token_hash.';

UPDATE public.rides SET access_token = NULL WHERE access_token IS NOT NULL;

REVOKE ALL ON FUNCTION public.create_ride_public(text,text,text,text,integer,text,boolean,boolean,double precision,double precision,double precision,double precision) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_ride_status(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_ride_public(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.load_demo_data() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rides_v1_projection() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_ride_public(text,text,text,text,integer,text,boolean,boolean,double precision,double precision,double precision,double precision) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_ride_status(uuid,uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_ride_public(uuid,uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.load_demo_data() TO authenticated, service_role;

DO $$ DECLARE a int; b int; c int; BEGIN
  SELECT count(access_token), count(*) FILTER (WHERE access_token_hash IS NULL), count(*) FILTER (WHERE octet_length(access_token_hash)<>32) INTO a,b,c FROM public.rides;
  IF a+b+c > 0 THEN RAISE EXCEPTION 'TOKEN_HASH_POSTCHECK_FAILED %/%/%', a,b,c; END IF;
END $$;