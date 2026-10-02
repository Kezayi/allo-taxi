CREATE OR REPLACE FUNCTION public.set_pool_expiry_minutes_v1(_minutes integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old integer := public.pool_expiry_minutes();
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'REFUSED' USING ERRCODE = '42501'; END IF;
  IF _minutes IS NULL OR _minutes < 1 OR _minutes > 60 THEN RAISE EXCEPTION 'INVALID_DATA' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO public.system_settings(key, value, updated_at) VALUES ('pool_expiry_minutes', to_jsonb(_minutes), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM public.log_audit_event('pool_expiry_changed', 'system_setting', 'pool_expiry_minutes', 'admin', auth.uid(), 'rpc',
    jsonb_build_object('from', v_old, 'to', _minutes));
  RETURN _minutes;
END $$;