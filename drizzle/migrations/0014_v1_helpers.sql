-- LOT 1B-1 : helpers V1
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.forbid_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'APPEND_ONLY: % interdit sur %', TG_OP, TG_TABLE_NAME USING ERRCODE = '42501';
END $$;

-- Majuscules + suppression de tout caractère non alphanumérique (espaces, tirets, points, slash).
CREATE OR REPLACE FUNCTION public.normalize_plate(_plate text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path = public AS $$
  SELECT NULLIF(upper(regexp_replace(_plate, '[^A-Za-z0-9]', '', 'g')), '')
$$;

REVOKE ALL ON FUNCTION public.touch_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.forbid_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.normalize_plate(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.touch_updated_at() TO service_role;
GRANT EXECUTE ON FUNCTION public.forbid_mutation() TO service_role;
GRANT EXECUTE ON FUNCTION public.normalize_plate(text) TO service_role;