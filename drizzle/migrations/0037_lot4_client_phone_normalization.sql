-- Correctif final LOT 4 : normalisation canonique du téléphone Client (+241 + 8 chiffres nationaux).
CREATE OR REPLACE FUNCTION public.normalize_client_phone_ga(_raw text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE d text := regexp_replace(coalesce(_raw,''), '[\s.\-()/]', '', 'g');
BEGIN
  IF d !~ '^\+?[0-9]+$' THEN RETURN NULL; END IF;
  d := ltrim(d, '+');
  IF d LIKE '00241%' THEN d := substr(d, 6);
  ELSIF d LIKE '241%' AND char_length(d) IN (11, 12) THEN d := substr(d, 4);
  END IF;
  IF char_length(d) = 9 AND left(d,1) = '0' THEN d := substr(d, 2); END IF;
  IF d !~ '^[1-9][0-9]{7}$' THEN RETURN NULL; END IF;
  RETURN '+241' || d;
END $$;
REVOKE ALL ON FUNCTION public.normalize_client_phone_ga(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_client_phone_ga(text) TO service_role;

CREATE OR REPLACE FUNCTION public.create_ride_public_v1(
  _client_name text, _client_phone text,
  _pickup_location text, _pickup_landmark text, _pickup_lat double precision, _pickup_lng double precision,
  _dropoff_location text, _dropoff_note text,
  _passenger_count integer, _wants_ac boolean, _allow_sharing boolean,
  _payment_method text, _price integer)
RETURNS TABLE(ride_id uuid, token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_name text := btrim(coalesce(_client_name,''));
  v_phone text := public.normalize_client_phone_ga(_client_phone);
  v_pickup text := btrim(coalesce(_pickup_location,''));
  v_drop text := btrim(coalesce(_dropoff_location,''));
  v_landmark text := nullif(btrim(coalesce(_pickup_landmark,'')),'');
  v_note text := nullif(btrim(coalesce(_dropoff_note,'')),'');
  v_pm text;
  v_id uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_identity uuid;
BEGIN
  v_pm := CASE _payment_method WHEN 'CASH' THEN 'Espèces' WHEN 'AIRTEL_MONEY' THEN 'AirtelMoney' WHEN 'MOOV_MONEY' THEN 'MoovMoney' END;
  IF char_length(v_name) NOT BETWEEN 2 AND 40
     OR v_phone IS NULL
     OR char_length(v_pickup) NOT BETWEEN 3 AND 120
     OR char_length(v_drop) NOT BETWEEN 3 AND 120
     OR (v_landmark IS NOT NULL AND char_length(v_landmark) > 120)
     OR (v_note IS NOT NULL AND char_length(v_note) > 160)
     OR _passenger_count IS NULL OR _passenger_count NOT BETWEEN 1 AND 8
     OR _wants_ac IS NULL OR _allow_sharing IS NULL
     OR v_pm IS NULL
     OR _price IS NULL OR _price NOT BETWEEN 500 AND 100000
     OR ((_pickup_lat IS NULL) <> (_pickup_lng IS NULL))
     OR (_pickup_lat IS NOT NULL AND (_pickup_lat NOT BETWEEN -90 AND 90 OR _pickup_lng NOT BETWEEN -180 AND 180))
     OR 'NaN'::float8 IN (_pickup_lat, _pickup_lng)
  THEN
    RAISE EXCEPTION 'INVALID_DATA' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('create_ride:' || v_phone));

  SELECT ci.id INTO v_identity FROM public.client_identities ci WHERE ci.phone = v_phone;
  IF v_identity IS NOT NULL AND EXISTS (SELECT 1 FROM public.client_restrictions cr
       WHERE cr.client_identity_id = v_identity AND cr.restriction_type = 'publish_blocked'
         AND cr.lifted_at IS NULL AND cr.starts_at <= now() AND (cr.ends_at IS NULL OR cr.ends_at > now())) THEN
    RAISE EXCEPTION 'CLIENT_RESTRICTED' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (SELECT 1 FROM public.rides r WHERE r.client_phone = v_phone AND r.status IN ('pending','negotiating','onboard')) THEN
    RAISE EXCEPTION 'ACTIVE_RIDE_EXISTS' USING ERRCODE = 'P0001';
  END IF;
  IF (SELECT count(*) FROM public.rides r WHERE r.client_phone = v_phone AND r.created_at > now() - interval '1 hour') >= 5 THEN
    RAISE EXCEPTION 'RATE_LIMITED' USING ERRCODE = 'P0001';
  END IF;

  PERFORM set_config('app.ride_v1_rpc', '1', true);
  INSERT INTO public.rides (id, access_token, access_token_hash, workflow_version, client_name, client_phone,
    pickup_location, pickup_landmark, pickup_lat, pickup_lng, dropoff_location, dropoff_note,
    passenger_count, wants_ac, allow_sharing, payment_method, price_proposed,
    status, status_v2, is_demo, created_at, updated_at)
  VALUES (v_id, NULL, extensions.digest(v_token::text, 'sha256'), 'v1', v_name, v_phone,
    v_pickup, v_landmark, _pickup_lat, _pickup_lng, v_drop, v_note,
    _passenger_count, _wants_ac, _allow_sharing, v_pm, _price,
    'pending', 'PENDING', false, now(), now())
  RETURNING client_identity_id INTO v_identity;
  PERFORM set_config('app.ride_v1_rpc', '', true);

  PERFORM public.ride_v1_event(v_id, NULL, 'published', CASE WHEN v_identity IS NULL THEN 'unknown' ELSE 'client' END, v_identity, NULL, 'PENDING');
  RETURN QUERY SELECT v_id, v_token;
END $$;