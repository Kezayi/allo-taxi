CREATE OR REPLACE FUNCTION public.financial_today_split()
RETURNS TABLE (partner_key text, share_percent numeric, today_amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE is_admin boolean := public.has_role(auth.uid(),'super_admin');
  rev bigint;
BEGIN
  IF NOT is_admin AND NOT public.has_role(auth.uid(),'associe') THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  SELECT coalesce(sum(amount),0) INTO rev FROM public.subscriptions WHERE day=(now() AT TIME ZONE 'Africa/Libreville')::date AND status='active';
  RETURN QUERY SELECT a.partner_key, a.share_percent, round(rev * a.share_percent / 100, 0)
  FROM public.associates_settings a
  WHERE a.is_active AND a.deleted_at IS NULL AND (is_admin OR a.user_id = auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.financial_today_split() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.financial_today_split() TO authenticated;