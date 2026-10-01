-- LOT 3B : driver_day_passes devient la source opérationnelle du droit journalier.
-- Ne répond que pour soi-même (ou Superadmin / service_role) : aucune fuite d'information.
CREATE OR REPLACE FUNCTION public.has_valid_driver_day_access(_driver_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT (auth.uid() IS NULL OR auth.uid() = _driver_id OR public.has_role(auth.uid(), 'super_admin'))
    AND EXISTS (
    SELECT 1 FROM public.driver_day_passes p
    WHERE p.driver_id = _driver_id
      AND p.service_day = (now() AT TIME ZONE 'Africa/Libreville')::date
      AND p.status = 'active'
      AND p.expires_at > now()
  )
$$;
REVOKE ALL ON FUNCTION public.has_valid_driver_day_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_valid_driver_day_access(uuid) TO authenticated, service_role;

-- Adaptateur de compatibilité (anciennes PWA) : plus aucun INSERT dans subscriptions.
CREATE OR REPLACE FUNCTION public.activate_driver_day() RETURNS date
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.activate_my_driver_day_v1(NULL);
  RETURN (now() AT TIME ZONE 'Africa/Libreville')::date;
END $$;
REVOKE ALL ON FUNCTION public.activate_driver_day() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activate_driver_day() TO authenticated;
COMMENT ON FUNCTION public.activate_driver_day() IS 'DEPRECATED (LOT 3B): adaptateur vers activate_my_driver_day_v1, ne crée plus de subscription.';
COMMENT ON TABLE public.subscriptions IS 'LEGACY / simulation historique (provider XFin sans paiement réel). Plus alimentée depuis LOT 3B. Jamais une recette.';

CREATE OR REPLACE FUNCTION public.set_driver_availability(_online boolean, _has_ac boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF _online THEN
    IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
    PERFORM public.assert_driver_documents_gate(auth.uid());
  END IF;
  UPDATE public.drivers SET is_online=_online, has_ac=_has_ac, updated_at=now() WHERE user_id=auth.uid();
END $function$;

CREATE OR REPLACE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision)
 RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
  WHERE r.status='pending' AND (d.has_ac OR NOT r.wants_ac)
    AND (r.pickup_lat IS NULL OR _lat IS NULL OR public.km_between(_lat,_lng,r.pickup_lat,r.pickup_lng) <= rad)
    AND (n_active = 0 OR NOT lock_on OR (r.allow_sharing AND public.ride_same_direction(a, r)))
  ORDER BY 7 NULLS LAST, r.created_at DESC LIMIT 30;
END $function$;

CREATE OR REPLACE FUNCTION public.take_ride(_ride_id uuid)
 RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE a public.rides; c public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT public.has_valid_driver_day_access(auth.uid()) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.assert_driver_documents_gate(auth.uid());
  IF EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN RAISE EXCEPTION 'Clôturez votre course en cours'; END IF;
  SELECT count(*) INTO n_active FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='onboard';
  SELECT * INTO c FROM public.rides x WHERE x.id=_ride_id AND x.status='pending' FOR UPDATE;
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
  WHERE r.id=_ride_id AND r.status='pending'
    AND ((SELECT has_ac FROM public.drivers WHERE user_id=auth.uid()) OR NOT r.wants_ac);
  IF NOT FOUND THEN RAISE EXCEPTION 'Course déjà prise ou indisponible'; END IF;
  RETURN QUERY SELECT r.id, r.client_name, r.client_phone, r.pickup_location, r.dropoff_location, r.price_proposed, r.payment_method, r.wants_ac FROM public.rides r WHERE r.id=_ride_id;
END $function$;

-- Superadmin : lecture de la configuration ticket (aucun secret)
CREATE OR REPLACE FUNCTION public.get_ticket_config()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE='42501'; END IF;
  RETURN jsonb_build_object('mode', public.driver_ticket_mode(), 'xfin_configured', public.xfin_integration_ready(),
    'standard_price_fcfa', public.setting_num('daily_price', 1000)::int);
END $$;
REVOKE ALL ON FUNCTION public.get_ticket_config() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_ticket_config() TO authenticated;