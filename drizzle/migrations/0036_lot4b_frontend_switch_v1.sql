-- LOT 4B : bascule frontend V1, fermeture de la création legacy, fin des SELECT directs sur rides.

-- 1. Plus aucune nouvelle course legacy (ancienne PWA) : erreur explicite, aucune valeur inventée.
CREATE OR REPLACE FUNCTION public.create_ride_public(
  _client_name text, _client_phone text, _pickup_location text, _dropoff_location text, _price integer,
  _payment_method text, _wants_ac boolean, _allow_sharing boolean,
  _pickup_lat double precision DEFAULT NULL, _pickup_lng double precision DEFAULT NULL,
  _dropoff_lat double precision DEFAULT NULL, _dropoff_lng double precision DEFAULT NULL)
RETURNS TABLE(id uuid, token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'CLIENT_APP_UPDATE_REQUIRED' USING ERRCODE = 'P0001',
    HINT = 'Legacy ride creation is closed since LOT 4B; use create_ride_public_v1.';
END $$;
COMMENT ON FUNCTION public.create_ride_public(text,text,text,text,integer,text,boolean,boolean,double precision,double precision,double precision,double precision)
  IS 'DEPRECATED (LOT 4B): always raises CLIENT_APP_UPDATE_REQUIRED. Replaced by create_ride_public_v1.';

-- 2. Lecture Chauffeur : ses courses actives, projection métier (V1 sans téléphone client ; legacy pour achèvement).
CREATE OR REPLACE FUNCTION public.get_my_active_rides()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'chauffeur') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'since') FROM (
      SELECT jsonb_build_object(
        'workflow_version', 'v1', 'ride_id', r.id, 'status', r.status_v2, 'since', coalesce(r.status_v2_changed_at, a.started_at),
        'client_first_name', r.client_name,
        'pickup_location', r.pickup_location, 'pickup_landmark', r.pickup_landmark,
        'dropoff_location', r.dropoff_location, 'dropoff_note', r.dropoff_note,
        'passenger_count', r.passenger_count, 'wants_ac', r.wants_ac, 'allow_sharing', r.allow_sharing,
        'payment_method', public.ride_v1_payment_code(r.payment_method),
        'price_proposed', r.price_proposed, 'price_final', r.price_final) AS x
      FROM public.ride_assignments a JOIN public.rides r ON r.id = a.ride_id
      WHERE a.driver_id = v_uid AND a.source = 'v1' AND a.status IN ('reserved','confirmed') AND r.workflow_version = 'v1'
      UNION ALL
      SELECT jsonb_build_object(
        'workflow_version', 'legacy', 'ride_id', r.id, 'status', r.status, 'since', r.started_negotiation_at,
        'client_first_name', r.client_name, 'client_phone', r.client_phone,
        'pickup_location', r.pickup_location, 'dropoff_location', r.dropoff_location,
        'wants_ac', r.wants_ac, 'allow_sharing', r.allow_sharing, 'payment_method', r.payment_method,
        'price_proposed', r.price_proposed, 'is_anchor', r.anchor_ride_id IS NULL)
      FROM public.rides r
      WHERE r.chauffeur_id = v_uid AND r.workflow_version = 'legacy' AND r.status IN ('negotiating','onboard')
    ) s), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.get_my_active_rides() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_active_rides() TO authenticated;

-- 3. Lecture Superadmin contrôlée : courses actives legacy + V1 distinguées par workflow_version.
CREATE OR REPLACE FUNCTION public.admin_list_live_rides()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'created_at') FROM (
      SELECT jsonb_build_object(
        'id', r.id, 'workflow_version', r.workflow_version, 'is_demo', r.is_demo,
        'status', CASE WHEN r.workflow_version = 'v1' THEN r.status_v2 ELSE r.status END,
        'client_name', r.client_name, 'pickup_location', r.pickup_location, 'dropoff_location', r.dropoff_location,
        'price_proposed', r.price_proposed, 'price_final', r.price_final, 'payment_method', r.payment_method,
        'wants_ac', r.wants_ac, 'passenger_count', r.passenger_count,
        'driver_label', (SELECT d.first_name || ' · ' || d.vehicle_plate FROM public.drivers d WHERE d.user_id = coalesce(
             CASE WHEN r.workflow_version = 'v1' THEN (SELECT a.driver_id FROM public.ride_assignments a WHERE a.ride_id = r.id AND a.source = 'v1' AND a.status IN ('reserved','confirmed') LIMIT 1) END,
             r.chauffeur_id)),
        'since', CASE WHEN r.workflow_version = 'v1' THEN coalesce(r.status_v2_changed_at, r.created_at)
                      WHEN r.status = 'pending' THEN r.created_at ELSE r.started_negotiation_at END,
        'created_at', r.created_at) AS x
      FROM public.rides r
      WHERE (r.workflow_version = 'legacy' AND r.status IN ('pending','negotiating','onboard'))
         OR (r.workflow_version = 'v1' AND r.status_v2 IN ('PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED','ONBOARD'))
    ) s), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_list_live_rides() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_live_rides() TO authenticated;

-- 4. Fin des lectures directes : rides et ride_public_status ne sont plus lisibles par les rôles API.
DROP POLICY IF EXISTS "Assigned driver reads ride" ON public.rides;
DROP POLICY IF EXISTS "Superadmin reads rides" ON public.rides;
REVOKE SELECT ON public.rides FROM anon, authenticated;
REVOKE SELECT ON public.ride_public_status FROM anon, authenticated;
COMMENT ON TABLE public.ride_public_status IS 'LEGACY (LOT 4B): read only through get_ride_status for legacy rides; never used by V1. Physical removal deferred to final cleanup.';