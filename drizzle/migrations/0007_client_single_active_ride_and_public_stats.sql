CREATE OR REPLACE FUNCTION public.cancel_ride_public(_ride_id uuid, _token uuid)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r public.rides;
BEGIN
  UPDATE public.rides SET status='canceled', resolved_at=now(), updated_at=now()
  WHERE id=_ride_id AND access_token=_token AND status IN ('pending','negotiating')
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN false; END IF;
  IF r.chauffeur_id IS NOT NULL THEN PERFORM public.log_ride_resolution(r, 'canceled'); END IF;
  RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.forbid_duplicate_active_ride()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM public.rides WHERE client_phone = NEW.client_phone
             AND status IN ('pending','negotiating') AND id <> NEW.id) THEN
    RAISE EXCEPTION 'ACTIVE_RIDE_EXISTS' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS rides_single_active ON public.rides;
CREATE TRIGGER rides_single_active BEFORE INSERT ON public.rides
FOR EACH ROW EXECUTE FUNCTION public.forbid_duplicate_active_ride();

CREATE OR REPLACE FUNCTION public.get_public_activity()
 RETURNS TABLE(active_passengers bigint, drivers_online bigint, matches_today bigint)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT
    (SELECT count(*) FROM public.rides WHERE status IN ('pending','negotiating') AND NOT is_demo),
    (SELECT count(*) FROM public.drivers WHERE is_online AND status='approved' AND is_active AND deleted_at IS NULL AND NOT is_demo
       AND (last_seen_at IS NULL OR last_seen_at > now() - interval '15 minutes')),
    (SELECT count(*) FROM public.rides WHERE chauffeur_id IS NOT NULL AND NOT is_demo
       AND created_at >= ((now() AT TIME ZONE 'Africa/Libreville')::date AT TIME ZONE 'Africa/Libreville'));
$function$;
GRANT EXECUTE ON FUNCTION public.get_public_activity() TO anon, authenticated;