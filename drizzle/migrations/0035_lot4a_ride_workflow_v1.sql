-- LOT 4A — Workflow Course V1 (backend). Legacy reste maître de ses propres courses.

ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS workflow_version text NOT NULL DEFAULT 'legacy';
ALTER TABLE public.rides ADD CONSTRAINT rides_workflow_version_check CHECK (workflow_version IN ('legacy','v1'));
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS pickup_landmark text;
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS dropoff_note text;
ALTER TABLE public.rides ADD CONSTRAINT rides_v1_notes_len CHECK (
  (pickup_landmark IS NULL OR char_length(pickup_landmark) <= 120) AND (dropoff_note IS NULL OR char_length(dropoff_note) <= 160));
ALTER TABLE public.rides ADD CONSTRAINT rides_v1_passenger_required CHECK (workflow_version <> 'v1' OR passenger_count IS NOT NULL) NOT VALID;
CREATE INDEX IF NOT EXISTS rides_v1_pool_idx ON public.rides (created_at DESC) WHERE workflow_version = 'v1' AND status_v2 = 'PENDING';
COMMENT ON COLUMN public.rides.workflow_version IS 'legacy = courses pilotées par rides.status (anciennes fonctions) ; v1 = courses pilotées par status_v2 via les RPC *_v1. Immuable.';

CREATE OR REPLACE FUNCTION public.ride_v1_legacy_status(_s text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE _s WHEN 'DRAFT' THEN 'pending' WHEN 'PENDING' THEN 'pending'
    WHEN 'CONTACT_PENDING' THEN 'negotiating' WHEN 'CONFIRMED' THEN 'negotiating'
    WHEN 'DRIVER_EN_ROUTE' THEN 'negotiating' WHEN 'DRIVER_ARRIVED' THEN 'negotiating'
    WHEN 'ONBOARD' THEN 'onboard' WHEN 'COMPLETED' THEN 'completed' ELSE 'canceled' END $$;

CREATE OR REPLACE FUNCTION public.ride_v1_transition_allowed(_from text, _to text) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE _from
    WHEN 'DRAFT' THEN _to IN ('PENDING')
    WHEN 'PENDING' THEN _to IN ('CONTACT_PENDING','CANCELED_BY_CLIENT','EXPIRED')
    WHEN 'CONTACT_PENDING' THEN _to IN ('CONFIRMED','PENDING','CANCELED_BY_CLIENT','CONTACT_FAILED')
    WHEN 'CONFIRMED' THEN _to IN ('DRIVER_EN_ROUTE','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','INCIDENT')
    WHEN 'DRIVER_EN_ROUTE' THEN _to IN ('DRIVER_ARRIVED','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','INCIDENT')
    WHEN 'DRIVER_ARRIVED' THEN _to IN ('ONBOARD','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','INCIDENT')
    WHEN 'ONBOARD' THEN _to IN ('COMPLETED','INCIDENT')
    ELSE false END $$;

CREATE OR REPLACE FUNCTION public.url_encode(_s text) RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE b bytea := convert_to(coalesce(_s,''), 'UTF8'); i int; c int; out text := '';
BEGIN
  FOR i IN 0 .. length(b) - 1 LOOP
    c := get_byte(b, i);
    IF (c BETWEEN 48 AND 57) OR (c BETWEEN 65 AND 90) OR (c BETWEEN 97 AND 122) OR c IN (45,46,95,126) THEN
      out := out || chr(c);
    ELSE
      out := out || '%' || upper(lpad(to_hex(c), 2, '0'));
    END IF;
  END LOOP;
  RETURN out;
END $$;

REVOKE ALL ON FUNCTION public.ride_v1_legacy_status(text), public.ride_v1_transition_allowed(text,text), public.url_encode(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rides_v1_workflow_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.workflow_version IS DISTINCT FROM OLD.workflow_version THEN
      RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE' USING ERRCODE = '23514';
    END IF;
    IF OLD.price_final_confirmed_at IS NOT NULL AND (NEW.price_final IS DISTINCT FROM OLD.price_final
        OR NEW.price_final_confirmed_at IS DISTINCT FROM OLD.price_final_confirmed_at) THEN
      RAISE EXCEPTION 'PRICE_FINAL_IMMUTABLE' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.workflow_version <> 'v1' THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    IF coalesce(current_setting('app.ride_v1_rpc', true), '') <> '1' THEN
      RAISE EXCEPTION 'V1_RPC_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF NEW.status_v2 IS NULL OR NEW.status_v2 NOT IN ('DRAFT','PENDING') OR NEW.chauffeur_id IS NOT NULL
       OR NEW.price_final IS NOT NULL OR NEW.passenger_count IS NULL THEN
      RAISE EXCEPTION 'V1_INVALID_INITIAL_STATE' USING ERRCODE = '23514';
    END IF;
    NEW.status := public.ride_v1_legacy_status(NEW.status_v2);
    NEW.status_v2_changed_at := coalesce(NEW.created_at, now());
    RETURN NEW;
  END IF;

  IF NEW.chauffeur_id IS NOT NULL OR NEW.anchor_ride_id IS NOT NULL THEN
    RAISE EXCEPTION 'V1_LEGACY_FIELDS_FORBIDDEN' USING ERRCODE = '23514';
  END IF;
  IF NEW.status_v2 IS DISTINCT FROM OLD.status_v2 THEN
    IF coalesce(current_setting('app.ride_v1_rpc', true), '') <> '1' THEN
      RAISE EXCEPTION 'V1_RPC_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF NOT public.ride_v1_transition_allowed(OLD.status_v2, NEW.status_v2) THEN
      RAISE EXCEPTION 'V1_INVALID_TRANSITION % -> %', OLD.status_v2, NEW.status_v2 USING ERRCODE = '23514';
    END IF;
    NEW.status_v2_changed_at := now();
  END IF;
  IF NEW.status IS DISTINCT FROM public.ride_v1_legacy_status(NEW.status_v2) THEN
    IF NEW.status_v2 IS NOT DISTINCT FROM OLD.status_v2 AND NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'V1_LEGACY_STATUS_FORBIDDEN' USING ERRCODE = '23514';
    END IF;
    NEW.status := public.ride_v1_legacy_status(NEW.status_v2);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER rides_v1_workflow_guard BEFORE INSERT OR UPDATE ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.rides_v1_workflow_guard();

CREATE OR REPLACE FUNCTION public.rides_v1_projection()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_vehicle uuid; v_owner uuid;
BEGIN
  IF NEW.access_token IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.access_token IS DISTINCT FROM OLD.access_token) THEN
    NEW.access_token_hash := extensions.digest(NEW.access_token::text, 'sha256');
  ELSIF TG_OP = 'UPDATE' AND NEW.access_token_hash IS NULL THEN
    NEW.access_token_hash := OLD.access_token_hash;
  END IF;

  IF NEW.workflow_version = 'v1' THEN RETURN NEW; END IF;

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

CREATE OR REPLACE FUNCTION public.rides_emit_events()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.is_demo OR NEW.workflow_version = 'v1' THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, to_status_v2)
    VALUES (NEW.id, 'published', 'legacy_observed',
            CASE WHEN NEW.client_identity_id IS NULL THEN 'unknown' ELSE 'client' END,
            NEW.client_identity_id, 'PENDING');
    RETURN NULL;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;

  IF NEW.status = 'canceled' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, from_status_v2, to_status_v2, payload)
    VALUES (NEW.id, 'legacy_canceled_unknown', 'legacy_observed', 'unknown', OLD.status_v2, NEW.status_v2,
            jsonb_build_object('legacy_from_status', OLD.status, 'legacy_to_status', NEW.status));
  ELSIF OLD.status = 'negotiating' AND NEW.status = 'pending' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'returned_to_pool', 'legacy_observed', 'unknown', 'CONTACT_PENDING', 'PENDING');
  ELSIF OLD.status = 'negotiating' AND NEW.status = 'onboard' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'onboard', 'legacy_observed', CASE WHEN NEW.chauffeur_id IS NULL THEN 'unknown' ELSE 'driver' END,
            NEW.chauffeur_id, 'CONTACT_PENDING', 'ONBOARD');
  ELSIF OLD.status = 'onboard' AND NEW.status = 'completed' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'dropped_off', 'legacy_observed', CASE WHEN NEW.chauffeur_id IS NULL THEN 'unknown' ELSE 'driver' END,
            NEW.chauffeur_id, 'ONBOARD', 'COMPLETED');
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.rides_sync_assignments()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.is_demo OR NEW.workflow_version = 'v1' THEN RETURN NULL; END IF;

  IF TG_OP = 'UPDATE' AND OLD.chauffeur_id IS NOT NULL AND NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id THEN
    UPDATE public.ride_assignments SET status='released', ended_at=now(), end_reason='legacy_released'
     WHERE ride_id=NEW.id AND driver_id=OLD.chauffeur_id AND status='reserved';
  END IF;

  IF NEW.chauffeur_id IS NOT NULL AND (TG_OP='INSERT' OR NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id)
     AND EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = NEW.chauffeur_id AND NOT d.is_demo) THEN
    INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at)
    VALUES (NEW.id, NEW.chauffeur_id, NEW.vehicle_id, 'reserved', 'legacy', now());
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.chauffeur_id IS NOT NULL THEN
    IF OLD.status='negotiating' AND NEW.status='onboard' THEN
      UPDATE public.ride_assignments SET status='confirmed', confirmed_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    ELSIF OLD.status='onboard' AND NEW.status='completed' THEN
      UPDATE public.ride_assignments SET status='completed', ended_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='confirmed';
    ELSIF OLD.status='negotiating' AND NEW.status='canceled' THEN
      UPDATE public.ride_assignments SET status='canceled', ended_at=now(), end_reason='legacy_ride_canceled'
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    END IF;
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.ride_assignments_emit_events()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.source = 'v1' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.rides r WHERE r.id = NEW.ride_id AND r.is_demo)
     OR EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = NEW.driver_id AND d.is_demo) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' AND NEW.status = 'reserved' THEN
    INSERT INTO public.ride_events (ride_id, assignment_id, event_type, source, actor_type, actor_id)
    VALUES (NEW.ride_id, NEW.id, 'driver_reserved', 'legacy_observed', 'driver', NEW.driver_id);
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'reserved' AND NEW.status = 'released' THEN
    INSERT INTO public.ride_events (ride_id, assignment_id, event_type, source, actor_type)
    VALUES (NEW.ride_id, NEW.id, 'driver_released', 'legacy_observed', 'unknown');
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.sync_ride_public_status()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE d public.drivers%ROWTYPE; v_min integer; v_km double precision;
BEGIN
  IF NEW.workflow_version = 'v1' THEN RETURN NEW; END IF;
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

CREATE OR REPLACE FUNCTION public.check_and_purge_negotiation_timeouts()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r public.rides%ROWTYPE; n integer := 0; lim interval := make_interval(mins => public.setting_num('negotiation_timeout_min',15)::int);
BEGIN
  FOR r IN SELECT * FROM public.rides WHERE workflow_version='legacy' AND status='negotiating' AND started_negotiation_at < now() - lim FOR UPDATE SKIP LOCKED LOOP
    PERFORM public.log_ride_resolution(r, 'timeout');
    INSERT INTO public.driver_penalties (driver_id, ride_id, reason, is_demo) VALUES (r.chauffeur_id, r.id, 'Négociation non clôturée dans le délai', r.is_demo);
    UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, updated_at=now() WHERE id=r.id;
    n := n + 1;
  END LOOP;
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now()
   WHERE workflow_version='legacy' AND status='pending' AND created_at < now() - interval '2 hours' AND NOT is_demo;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.cancel_ride_public(_ride_id uuid, _token uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r public.rides;
BEGIN
  IF _token IS NULL THEN RETURN false; END IF;
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now()
  WHERE id=_ride_id AND workflow_version='legacy' AND access_token_hash = extensions.digest(_token::text, 'sha256')
    AND status IN ('pending','negotiating')
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN false; END IF;
  IF r.chauffeur_id IS NOT NULL THEN PERFORM public.log_ride_resolution(r, 'canceled'); END IF;
  RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.get_ride_status(_ride_id uuid, _token uuid)
 RETURNS TABLE(status text, chauffeur_first_name text, vehicle_model text, vehicle_plate text, chauffeur_phone text, eta_minutes integer, driver_distance_km double precision, updated_at timestamp with time zone)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT s.status, s.chauffeur_first_name, s.vehicle_model, s.vehicle_plate,
         s.chauffeur_phone, s.eta_minutes, s.driver_distance_km, s.updated_at
  FROM public.rides r
  JOIN public.ride_public_status s ON s.ride_id = r.id
  WHERE r.id = _ride_id AND _token IS NOT NULL AND r.workflow_version = 'legacy'
    AND r.access_token_hash = extensions.digest(_token::text, 'sha256')
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.close_ride(_ride_id uuid, _success boolean)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r public.rides%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id=_ride_id AND workflow_version='legacy' AND chauffeur_id=auth.uid() AND status='negotiating' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course introuvable'; END IF;
  IF _success THEN
    UPDATE public.rides SET status='onboard', boarded_at=now(), updated_at=now() WHERE id=_ride_id;
    RETURN 'onboard';
  END IF;
  PERFORM public.log_ride_resolution(r, 'canceled');
  UPDATE public.rides SET status='pending', chauffeur_id=NULL, started_negotiation_at=NULL, anchor_ride_id=NULL, updated_at=now() WHERE id=_ride_id;
  RETURN 'released';
END $function$;

CREATE OR REPLACE FUNCTION public.drop_off_ride(_ride_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r public.rides%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id=_ride_id AND workflow_version='legacy' AND chauffeur_id=auth.uid() AND status='onboard' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course introuvable'; END IF;
  PERFORM public.log_ride_resolution(r, 'completed');
  UPDATE public.rides SET status='completed', resolved_at=now(), updated_at=now() WHERE id=_ride_id;
  IF r.anchor_ride_id IS NULL THEN
    UPDATE public.rides SET anchor_ride_id = (
      SELECT x.id FROM public.rides x WHERE x.anchor_ride_id=_ride_id AND x.status IN ('negotiating','onboard') ORDER BY x.started_negotiation_at LIMIT 1)
    WHERE anchor_ride_id=_ride_id AND status IN ('negotiating','onboard');
    UPDATE public.rides SET anchor_ride_id=NULL WHERE id = (SELECT anchor_ride_id FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard') AND anchor_ride_id IS NOT NULL LIMIT 1);
  END IF;
  RETURN 'completed';
END $function$;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision)
 RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE d public.drivers%ROWTYPE;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
  a public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=coalesce(_lat,last_lat), last_lng=coalesce(_lng,last_lng), last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  SELECT count(*) INTO n_active FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard');
  IF n_active > 0 THEN
    IF n_active >= 3 OR EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN
      RETURN;
    END IF;
    IF lock_on THEN
      a := public.driver_anchor_ride(auth.uid());
      IF a.id IS NULL OR NOT a.allow_sharing OR a.status <> 'onboard' THEN
        RETURN;
      END IF;
    END IF;
  END IF;
  RETURN QUERY
  SELECT r.id, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac,
    CASE WHEN r.pickup_lat IS NULL OR _lat IS NULL THEN NULL ELSE public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) END,
    r.created_at
  FROM public.rides r
  WHERE r.workflow_version='legacy' AND r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND (n_active = 0 OR NOT lock_on OR (r.allow_sharing AND public.ride_same_direction(a, r)))
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $function$;

CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
 RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE a public.rides; c public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  IF EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  IF EXISTS (SELECT 1 FROM public.ride_assignments ra WHERE ra.driver_id=auth.uid() AND ra.source='v1' AND ra.status IN ('reserved','confirmed')) THEN
    RAISE EXCEPTION 'Clôturez votre course en cours';
  END IF;
  SELECT count(*) INTO n_active FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='onboard';
  SELECT * INTO c FROM public.rides x WHERE x.id=_ride_id AND x.workflow_version='legacy' AND x.status='pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  IF n_active > 0 AND lock_on THEN
    a := public.driver_anchor_ride(auth.uid());
    IF a.id IS NULL OR NOT a.allow_sharing THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: le client principal n''a pas accepté le partage'; END IF;
    IF n_active >= 3 THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: véhicule complet'; END IF;
    IF NOT c.allow_sharing OR NOT public.ride_same_direction(a, c) THEN RAISE EXCEPTION 'TRAJET_VERROUILLE: course hors de votre trajet'; END IF;
  ELSIF n_active >= 3 THEN
    RAISE EXCEPTION 'Véhicule complet';
  END IF;
  UPDATE public.rides r SET status='negotiating', chauffeur_id=auth.uid(), started_negotiation_at=now(), updated_at=now(),
    anchor_ride_id = CASE WHEN n_active > 0 AND lock_on THEN a.id ELSE NULL END
  WHERE r.id=_ride_id AND r.workflow_version='legacy' AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $function$;

CREATE OR REPLACE FUNCTION public.ride_v1_payment_code(_legacy text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE _legacy WHEN 'Espèces' THEN 'CASH' WHEN 'AirtelMoney' THEN 'AIRTEL_MONEY' WHEN 'MoovMoney' THEN 'MOOV_MONEY' END $$;
REVOKE ALL ON FUNCTION public.ride_v1_payment_code(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ride_v1_by_token(_ride_id uuid, _token uuid) RETURNS public.rides
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides;
BEGIN
  IF _ride_id IS NULL OR _token IS NULL THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1'
     AND access_token_hash = extensions.digest(_token::text, 'sha256') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ride_v1_by_token(uuid,uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ride_v1_set_status(_ride_id uuid, _to text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM set_config('app.ride_v1_rpc', '1', true);
  UPDATE public.rides SET status_v2 = _to, updated_at = now(),
    boarded_at = CASE WHEN _to = 'ONBOARD' THEN now() ELSE boarded_at END,
    resolved_at = CASE WHEN _to IN ('COMPLETED','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','CONTACT_FAILED','EXPIRED','INCIDENT') THEN now() ELSE resolved_at END
   WHERE id = _ride_id;
  PERFORM set_config('app.ride_v1_rpc', '', true);
END $$;
REVOKE ALL ON FUNCTION public.ride_v1_set_status(uuid,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ride_v1_event(_ride_id uuid, _assignment uuid, _type text, _actor_type text, _actor uuid, _from text, _to text, _payload jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.ride_events (ride_id, assignment_id, event_type, source, actor_type, actor_id, from_status_v2, to_status_v2, payload)
  VALUES (_ride_id, _assignment, _type, 'v1', _actor_type, CASE WHEN _actor_type IN ('system','unknown') THEN NULL ELSE _actor END, _from, _to, coalesce(_payload,'{}'::jsonb)) $$;
REVOKE ALL ON FUNCTION public.ride_v1_event(uuid,uuid,text,text,uuid,text,text,jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ride_v1_whatsapp_number(_raw text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE WHEN regexp_replace(coalesce(_raw,''), '[\s\-\.\(\)]', '', 'g') ~ '^\+?241[0-9]{8,9}$'
              THEN ltrim(regexp_replace(_raw, '[\s\-\.\(\)]', '', 'g'), '+') END $$;
REVOKE ALL ON FUNCTION public.ride_v1_whatsapp_number(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ride_v1_assert_driver_ready(_uid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF _uid IS NULL OR NOT public.is_active_driver(_uid) THEN RAISE EXCEPTION 'DRIVER_NOT_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  IF NOT public.has_valid_driver_day_access(_uid) THEN RAISE EXCEPTION 'DAY_ACCESS_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.assert_driver_documents_gate(_uid);
END $$;
REVOKE ALL ON FUNCTION public.ride_v1_assert_driver_ready(uuid) FROM PUBLIC, anon, authenticated;

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
  v_phone text := btrim(coalesce(_client_phone,''));
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
     OR v_phone !~ '^\+241[0-9]{8,9}$'
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

CREATE OR REPLACE FUNCTION public.get_ride_status_v1(_ride_id uuid, _token uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.rides; a public.ride_assignments; d public.drivers; v public.vehicles;
  v_wa text; v_msg text; v_contact jsonb := NULL; v_safety jsonb := NULL;
BEGIN
  IF _ride_id IS NULL OR _token IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1'
     AND access_token_hash = extensions.digest(_token::text, 'sha256');
  IF NOT FOUND THEN RETURN NULL; END IF;

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
          'driver_photo_url', NULL,
          'driver_photo_status', 'UNAVAILABLE',
          'vehicle_photo_url', NULL,
          'vehicle_photo_status', 'UNAVAILABLE',
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
    'contact', v_contact, 'safety', v_safety, 'created_at', r.created_at);
END $$;

CREATE OR REPLACE FUNCTION public.get_pool_v1(_lat double precision, _lng double precision, _radius_km double precision)
RETURNS TABLE(ride_id uuid, pickup_location text, pickup_landmark text, dropoff_location text, dropoff_note text,
  passenger_count smallint, wants_ac boolean, allow_sharing boolean, payment_method text, price_proposed integer,
  distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_ac boolean;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
BEGIN
  PERFORM public.ride_v1_assert_driver_ready(v_uid);
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
  ORDER BY 11 NULLS LAST, r.created_at DESC LIMIT 30;
END $$;

CREATE OR REPLACE FUNCTION public.reserve_ride_v1(_ride_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.rides; d public.drivers; v_vehicle uuid; v_asg uuid;
BEGIN
  PERFORM public.ride_v1_assert_driver_ready(v_uid);
  PERFORM pg_advisory_xact_lock(hashtext('driver_engage:' || v_uid::text));
  SELECT * INTO d FROM public.drivers WHERE user_id = v_uid;
  IF NOT d.is_online THEN RAISE EXCEPTION 'DRIVER_OFFLINE' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM public.ride_assignments WHERE driver_id = v_uid AND status IN ('reserved','confirmed'))
     OR EXISTS (SELECT 1 FROM public.rides WHERE chauffeur_id = v_uid AND status IN ('negotiating','onboard')) THEN
    RAISE EXCEPTION 'DRIVER_ALREADY_ENGAGED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND OR r.status_v2 <> 'PENDING' THEN RAISE EXCEPTION 'RIDE_UNAVAILABLE' USING ERRCODE = 'P0001'; END IF;
  IF r.wants_ac AND NOT d.has_ac THEN RAISE EXCEPTION 'RIDE_REQUIRES_AC' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (SELECT 1 FROM public.ride_assignments WHERE ride_id = r.id AND status IN ('reserved','confirmed')) THEN
    RAISE EXCEPTION 'RIDE_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;
  SELECT v.id INTO v_vehicle FROM public.vehicles v
   WHERE v.id = d.active_vehicle_id AND v.driver_id = v_uid AND v.deleted_at IS NULL;

  INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at)
  VALUES (r.id, v_uid, v_vehicle, 'reserved', 'v1', now()) RETURNING id INTO v_asg;
  PERFORM public.ride_v1_set_status(r.id, 'CONTACT_PENDING');
  PERFORM public.ride_v1_event(r.id, v_asg, 'driver_reserved', 'driver', v_uid, 'PENDING', 'CONTACT_PENDING');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CONTACT_PENDING', 'assignment_id', v_asg);
END $$;

CREATE OR REPLACE FUNCTION public.release_ride_v1(_ride_id uuid, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  PERFORM public.ride_v1_event(r.id, a.id, 'driver_released', 'driver', v_uid, 'CONTACT_PENDING', 'CONTACT_PENDING');
  PERFORM public.ride_v1_event(r.id, a.id, 'returned_to_pool', 'system', NULL, 'CONTACT_PENDING', 'PENDING');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'PENDING');
END $$;

CREATE OR REPLACE FUNCTION public.confirm_ride_after_contact_v1(_ride_id uuid, _token uuid, _final_price integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides; a public.ride_assignments;
BEGIN
  r := public.ride_v1_by_token(_ride_id, _token);
  IF r.status_v2 <> 'CONTACT_PENDING' THEN RAISE EXCEPTION 'CONFIRM_NOT_ALLOWED' USING ERRCODE = 'P0001'; END IF;
  IF _final_price IS NULL OR _final_price NOT BETWEEN 500 AND 100000 THEN RAISE EXCEPTION 'INVALID_PRICE' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND source = 'v1' AND status = 'reserved' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CONFIRM_NOT_ALLOWED' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.rides SET price_final = _final_price, price_final_confirmed_at = now() WHERE id = r.id;
  PERFORM public.ride_v1_set_status(r.id, 'CONFIRMED');
  UPDATE public.ride_assignments SET status = 'confirmed', confirmed_at = now() WHERE id = a.id;
  PERFORM public.ride_v1_event(r.id, a.id, 'contact_confirmed', 'client', r.client_identity_id, 'CONTACT_PENDING', 'CONFIRMED');
  PERFORM public.ride_v1_event(r.id, a.id, 'price_confirmed', 'client', r.client_identity_id, 'CONFIRMED', 'CONFIRMED',
    jsonb_build_object('price_proposed', r.price_proposed, 'price_final', _final_price));
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CONFIRMED', 'price_final', _final_price);
END $$;

CREATE OR REPLACE FUNCTION public.mark_contact_failed_v1(_ride_id uuid, _token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides; a public.ride_assignments;
BEGIN
  r := public.ride_v1_by_token(_ride_id, _token);
  IF r.status_v2 <> 'CONTACT_PENDING' THEN RAISE EXCEPTION 'CONTACT_FAILED_NOT_ALLOWED' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND source = 'v1' AND status = 'reserved' FOR UPDATE;
  IF FOUND THEN
    UPDATE public.ride_assignments SET status = 'released', ended_at = now(), end_reason = 'contact_failed' WHERE id = a.id;
  END IF;
  PERFORM public.ride_v1_set_status(r.id, 'CONTACT_FAILED');
  PERFORM public.ride_v1_event(r.id, a.id, 'contact_failed', 'client', r.client_identity_id, 'CONTACT_PENDING', 'CONTACT_FAILED');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CONTACT_FAILED');
END $$;

CREATE OR REPLACE FUNCTION public.advance_ride_v1(_ride_id uuid, _action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.rides; a public.ride_assignments; v_from text; v_to text; v_evt text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND driver_id = v_uid AND status = 'confirmed' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_ASSIGNED_DRIVER' USING ERRCODE = 'P0001'; END IF;
  CASE _action
    WHEN 'MARK_EN_ROUTE' THEN v_from := 'CONFIRMED'; v_to := 'DRIVER_EN_ROUTE'; v_evt := 'driver_en_route';
    WHEN 'MARK_ARRIVED' THEN v_from := 'DRIVER_EN_ROUTE'; v_to := 'DRIVER_ARRIVED'; v_evt := 'driver_arrived';
    WHEN 'MARK_ONBOARD' THEN v_from := 'DRIVER_ARRIVED'; v_to := 'ONBOARD'; v_evt := 'onboard';
    WHEN 'MARK_COMPLETED' THEN v_from := 'ONBOARD'; v_to := 'COMPLETED'; v_evt := 'dropped_off';
    ELSE RAISE EXCEPTION 'INVALID_ACTION' USING ERRCODE = 'P0001';
  END CASE;
  IF r.status_v2 <> v_from THEN
    RAISE EXCEPTION 'V1_INVALID_TRANSITION % -> %', r.status_v2, v_to USING ERRCODE = '23514';
  END IF;
  PERFORM public.ride_v1_set_status(r.id, v_to);
  IF v_to = 'COMPLETED' THEN
    UPDATE public.ride_assignments SET status = 'completed', ended_at = now() WHERE id = a.id;
  END IF;
  PERFORM public.ride_v1_event(r.id, a.id, v_evt, 'driver', v_uid, v_from, v_to);
  RETURN jsonb_build_object('ride_id', r.id, 'status', v_to);
END $$;

CREATE OR REPLACE FUNCTION public.cancel_ride_by_driver_v1(_ride_id uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); r public.rides; a public.ride_assignments;
  v_reason text := nullif(left(btrim(coalesce(_reason,'')), 200), '');
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED' USING ERRCODE = '42501'; END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RIDE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND driver_id = v_uid AND status = 'confirmed' FOR UPDATE;
  IF NOT FOUND OR r.status_v2 NOT IN ('CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED') THEN
    RAISE EXCEPTION 'DRIVER_CANCEL_NOT_ALLOWED' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.ride_assignments SET status = 'canceled', ended_at = now(), end_reason = 'driver_cancel' WHERE id = a.id;
  PERFORM public.ride_v1_set_status(r.id, 'CANCELED_BY_DRIVER');
  PERFORM public.ride_v1_event(r.id, a.id, 'canceled_by_driver', 'driver', v_uid, r.status_v2, 'CANCELED_BY_DRIVER',
    jsonb_build_object('reason', v_reason));
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CANCELED_BY_DRIVER');
END $$;

CREATE OR REPLACE FUNCTION public.cancel_ride_v1(_ride_id uuid, _token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides; a public.ride_assignments;
BEGIN
  r := public.ride_v1_by_token(_ride_id, _token);
  IF r.status_v2 NOT IN ('PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED') THEN
    RAISE EXCEPTION 'CLIENT_CANCEL_NOT_ALLOWED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO a FROM public.ride_assignments WHERE ride_id = r.id AND source = 'v1' AND status IN ('reserved','confirmed') FOR UPDATE;
  IF FOUND THEN
    UPDATE public.ride_assignments
       SET status = CASE WHEN a.status = 'reserved' THEN 'released' ELSE 'canceled' END,
           ended_at = now(), end_reason = 'client_cancel' WHERE id = a.id;
  END IF;
  PERFORM public.ride_v1_set_status(r.id, 'CANCELED_BY_CLIENT');
  PERFORM public.ride_v1_event(r.id, a.id, 'canceled_by_client', 'client', r.client_identity_id, r.status_v2, 'CANCELED_BY_CLIENT');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'CANCELED_BY_CLIENT');
END $$;

CREATE OR REPLACE FUNCTION public.expire_ride_v1(_ride_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides;
BEGIN
  SELECT * INTO r FROM public.rides WHERE id = _ride_id AND workflow_version = 'v1' FOR UPDATE;
  IF NOT FOUND OR r.status_v2 <> 'PENDING' THEN RAISE EXCEPTION 'EXPIRE_NOT_ALLOWED' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.ride_v1_set_status(r.id, 'EXPIRED');
  PERFORM public.ride_v1_event(r.id, NULL, 'expired', 'system', NULL, 'PENDING', 'EXPIRED');
  RETURN jsonb_build_object('ride_id', r.id, 'status', 'EXPIRED');
END $$;

REVOKE ALL ON FUNCTION public.create_ride_public_v1(text,text,text,text,double precision,double precision,text,text,integer,boolean,boolean,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_ride_status_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_ride_after_contact_v1(uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_contact_failed_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_ride_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pool_v1(double precision,double precision,double precision) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reserve_ride_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_ride_v1(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.advance_ride_v1(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_ride_by_driver_v1(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.expire_ride_v1(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_ride_public_v1(text,text,text,text,double precision,double precision,text,text,integer,boolean,boolean,text,integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_ride_status_v1(uuid,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_ride_after_contact_v1(uuid,uuid,integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_contact_failed_v1(uuid,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_ride_v1(uuid,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pool_v1(double precision,double precision,double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_ride_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_ride_v1(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.advance_ride_v1(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_ride_by_driver_v1(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expire_ride_v1(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.rides_v1_workflow_guard() FROM PUBLIC, anon, authenticated;
