CREATE OR REPLACE FUNCTION public.superadmin_exists()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE role='super_admin' AND is_active AND deleted_at IS NULL)
$$;
GRANT EXECUTE ON FUNCTION public.superadmin_exists() TO anon, authenticated;