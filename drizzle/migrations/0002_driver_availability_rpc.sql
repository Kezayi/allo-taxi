CREATE OR REPLACE FUNCTION public.set_driver_availability(_online boolean, _has_ac boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_active_driver(auth.uid()) THEN RAISE EXCEPTION 'Chauffeur non validé'; END IF;
  UPDATE public.drivers SET is_online=_online, has_ac=_has_ac, updated_at=now() WHERE user_id=auth.uid();
END $$;
GRANT EXECUTE ON FUNCTION public.set_driver_availability(boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_active_driver(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_active_driver(uuid) TO authenticated;