-- LOT 7 : présence GPS courante (sans historique), outbox dédupliquée, supervision dispatch.
CREATE OR REPLACE FUNCTION public.presence_stale_threshold_sec() RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (SELECT (value #>> '{}')::integer FROM public.system_settings WHERE key = 'presence_stale_threshold_sec') $$;
REVOKE ALL ON FUNCTION public.presence_stale_threshold_sec() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.update_driver_presence_v1(_lat double precision, _lng double precision, _accuracy_m real DEFAULT NULL, _heading_deg real DEFAULT NULL, _position_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_pos timestamptz;
BEGIN
  IF v_uid IS NULL OR NOT public.is_active_driver(v_uid) THEN RAISE EXCEPTION 'DRIVER_NOT_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  IF _lat IS NULL OR _lng IS NULL OR _lat NOT BETWEEN -90 AND 90 OR _lng NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'INVALID_POSITION' USING ERRCODE = 'P0001'; END IF;
  -- Horodatage appareil borné : jamais dans le futur, jamais plus ancien que 10 min (sinon heure serveur).
  v_pos := CASE WHEN _position_at IS NULL OR _position_at > now() OR _position_at < now() - interval '10 minutes' THEN now() ELSE _position_at END;
  UPDATE public.drivers SET last_lat = _lat, last_lng = _lng, last_seen_at = now() WHERE user_id = v_uid;
  INSERT INTO public.driver_presence (driver_id) VALUES (v_uid) ON CONFLICT (driver_id) DO NOTHING;
  UPDATE public.driver_presence SET lat = _lat, lng = _lng,
    accuracy_m = CASE WHEN _accuracy_m >= 0 THEN _accuracy_m END,
    heading_deg = CASE WHEN _heading_deg >= 0 AND _heading_deg < 360 THEN _heading_deg END,
    position_at = v_pos, last_heartbeat_at = now()
  WHERE driver_id = v_uid;
  RETURN jsonb_build_object('ok', true, 'server_at', now());
END $$;
REVOKE ALL ON FUNCTION public.update_driver_presence_v1(double precision, double precision, real, real, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_driver_presence_v1(double precision, double precision, real, real, timestamptz) TO authenticated;

-- Producteur outbox : un événement métier V1 = une notification logique par destinataire (clé evt:<id>:<type>).
CREATE OR REPLACE FUNCTION public.ride_events_to_outbox() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.rides; v_driver uuid; v_type text; v_to text;
BEGIN
  IF NEW.source <> 'v1' THEN RETURN NEW; END IF;
  SELECT * INTO r FROM public.rides WHERE id = NEW.ride_id;
  IF NOT FOUND OR r.is_demo THEN RETURN NEW; END IF;
  SELECT driver_id INTO v_driver FROM public.ride_assignments WHERE id = NEW.assignment_id;
  v_type := CASE NEW.event_type
    WHEN 'driver_reserved' THEN 'ride_reserved' WHEN 'contact_confirmed' THEN 'ride_confirmed'
    WHEN 'driver_en_route' THEN 'driver_en_route' WHEN 'driver_arrived' THEN 'driver_arrived'
    WHEN 'canceled_by_client' THEN 'ride_canceled' WHEN 'canceled_by_driver' THEN 'ride_canceled'
    WHEN 'dropped_off' THEN 'ride_completed' END;
  IF v_type IS NULL THEN RETURN NEW; END IF;
  v_to := CASE WHEN NEW.event_type IN ('contact_confirmed','canceled_by_client') THEN 'driver' ELSE 'client' END;
  IF v_to = 'driver' AND v_driver IS NOT NULL THEN
    INSERT INTO public.notification_outbox (dedupe_key, notification_type, channel, recipient_type, recipient_id, ride_id, ride_event_id, payload)
    VALUES ('evt:'||NEW.id||':driver', v_type, 'in_app', 'driver', v_driver, NEW.ride_id, NEW.id, jsonb_build_object('status', NEW.to_status_v2))
    ON CONFLICT (dedupe_key) DO NOTHING;
  ELSIF v_to = 'client' AND r.client_identity_id IS NOT NULL THEN
    INSERT INTO public.notification_outbox (dedupe_key, notification_type, channel, recipient_type, recipient_id, ride_id, ride_event_id, payload)
    VALUES ('evt:'||NEW.id||':client', v_type, 'in_app', 'client', r.client_identity_id, NEW.ride_id, NEW.id, jsonb_build_object('status', NEW.to_status_v2))
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.ride_events_to_outbox() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER ride_events_outbox AFTER INSERT ON public.ride_events FOR EACH ROW EXECUTE FUNCTION public.ride_events_to_outbox();

-- Supervision Superadmin : présence + charge, sans téléphone ni historique.
CREATE OR REPLACE FUNCTION public.admin_list_driver_presence_v1() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE thr integer := public.presence_stale_threshold_sec();
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object('stale_threshold_sec', thr, 'drivers', coalesce((SELECT jsonb_agg(s ORDER BY s.availability, s.first_name) FROM (
    SELECT d.first_name, d.vehicle_plate, p.availability, p.lat, p.lng, p.accuracy_m, p.position_at, p.last_heartbeat_at,
      extract(epoch FROM now() - p.position_at)::int AS position_age_sec,
      CASE WHEN thr IS NULL OR p.position_at IS NULL THEN NULL ELSE p.position_at < now() - make_interval(secs => thr) END AS is_stale,
      (SELECT count(*) FROM public.ride_assignments x WHERE x.driver_id = d.user_id AND x.source = 'v1' AND x.status IN ('reserved','confirmed')) AS active_rides,
      (SELECT coalesce(sum(coalesce(r.passenger_count,1)),0) FROM public.ride_assignments x JOIN public.rides r ON r.id = x.ride_id
        WHERE x.driver_id = d.user_id AND x.source = 'v1' AND x.status IN ('reserved','confirmed')) AS seats_engaged,
      (SELECT v.passenger_capacity FROM public.vehicles v WHERE v.id = d.active_vehicle_id) AS passenger_capacity
    FROM public.drivers d JOIN public.driver_presence p ON p.driver_id = d.user_id
    WHERE NOT d.is_demo AND d.deleted_at IS NULL AND d.status = 'approved') s), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.admin_list_driver_presence_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_driver_presence_v1() TO authenticated;