-- A1 : privilèges par défaut des futurs objets créés par postgres
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- A2 : forfait journalier lisible par Superadmin et Associé uniquement
CREATE OR REPLACE FUNCTION public.get_daily_price()
RETURNS integer LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_role(auth.uid(),'super_admin') OR public.has_role(auth.uid(),'associe')) THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  RETURN public.setting_num('daily_price', 1000)::integer;
END $$;
REVOKE EXECUTE ON FUNCTION public.get_daily_price() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_price() TO authenticated;