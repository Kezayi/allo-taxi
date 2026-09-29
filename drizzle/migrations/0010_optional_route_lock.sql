-- Le partage (case client) reste toujours possible ; seul le VERROUILLAGE du trajet du premier client devient optionnel (system_settings.shared_rides_enabled).

-- 1) Plus de forçage côté trigger : le consentement client est stocké tel quel.
DROP TRIGGER IF EXISTS trg_enforce_shared_rides_toggle ON public.rides;
DROP FUNCTION IF EXISTS public.enforce_shared_rides_toggle();

-- 2) Pool chauffeur : quand le verrouillage est désactivé, le chauffeur voit toutes les courses en attente
--    même avec une course active (capacité max 3 courses actives conservée).
DROP FUNCTION IF EXISTS public.get_localized_pool_for_driver(double precision, double precision, double precision);
CREATE FUNCTION public.get_localized_pool_for_driver(_lat double precision, _lng double precision, _radius_km double precision)
RETURNS TABLE(id uuid, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean, distance_km double precision, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.drivers%ROWTYPE; today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  rad double precision := coalesce(_radius_km, public.setting_num('search_radius_km',5)::double precision);
  a public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=today AND s.status='active') THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
  PERFORM public.check_and_purge_negotiation_timeouts();
  UPDATE public.drivers SET last_lat=coalesce(_lat,last_lat), last_lng=coalesce(_lng,last_lng), last_seen_at=now(), is_online=true WHERE user_id=auth.uid() RETURNING * INTO d;
  SELECT count(*) INTO n_active FROM public.rides WHERE chauffeur_id=auth.uid() AND status IN ('negotiating','onboard');
  IF n_active > 0 THEN
    IF n_active >= 3 OR EXISTS (SELECT 1 FROM public.rides x WHERE x.chauffeur_id=auth.uid() AND x.status='negotiating') THEN
      RETURN;
    END IF;
    IF lock_on THEN
      a := public.driver_anchor_ride(auth.uid());
      -- Trajet verrouillé : partage seulement si le client principal a accepté, est à bord
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
END $$;
GRANT EXECUTE ON FUNCTION public.get_localized_pool_for_driver(double precision, double precision, double precision) TO authenticated;

-- 3) Prise de course : les contrôles d'ancre (consentement, direction) ne s'appliquent que si le verrouillage est activé.
DROP FUNCTION IF EXISTS public.take_ride(uuid);
CREATE FUNCTION public.take_ride(_ride_id uuid)
RETURNS TABLE(id uuid, client_name text, client_phone text, pickup_location text, dropoff_location text, price_proposed integer, payment_method text, wants_ac boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.rides; c public.rides; n_active int; lock_on boolean := public.shared_rides_enabled();
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.driver_id=auth.uid() AND s.day=(now() AT TIME ZONE 'Africa/Libreville')::date) THEN RAISE EXCEPTION 'Abonnement du jour inactif'; END IF;
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
END $$;
GRANT EXECUTE ON FUNCTION public.take_ride(uuid) TO authenticated;