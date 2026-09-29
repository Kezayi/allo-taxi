CREATE OR REPLACE FUNCTION public.shared_rides_enabled() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT (value)::text::boolean FROM public.system_settings WHERE key = 'shared_rides_enabled'), false)
$$;
GRANT EXECUTE ON FUNCTION public.shared_rides_enabled() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_shared_rides_enabled(_on boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'forbidden'; END IF;
  INSERT INTO public.system_settings(key, value, updated_at) VALUES ('shared_rides_enabled', to_jsonb(_on), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
END $$;
REVOKE EXECUTE ON FUNCTION public.set_shared_rides_enabled(boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_shared_rides_enabled(boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_shared_rides_toggle() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.shared_rides_enabled() THEN
    IF TG_OP = 'INSERT' THEN NEW.allow_sharing := false; END IF;
    IF NEW.anchor_ride_id IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.anchor_ride_id IS NULL) THEN
      RAISE EXCEPTION 'Le taxi partagé est désactivé';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_enforce_shared_rides_toggle ON public.rides;
CREATE TRIGGER trg_enforce_shared_rides_toggle BEFORE INSERT OR UPDATE OF anchor_ride_id ON public.rides
FOR EACH ROW EXECUTE FUNCTION public.enforce_shared_rides_toggle();