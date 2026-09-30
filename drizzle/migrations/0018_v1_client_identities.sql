-- LOT 1B-4 : identité Client légère (téléphone) + restrictions. Identité ≠ authentification.

CREATE TABLE public.client_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone text NOT NULL UNIQUE CHECK (phone ~ '^\+241[0-9]{8,9}$'),
  last_display_name text,
  trust_level text NOT NULL DEFAULT 'free' CHECK (trust_level IN ('free','verified')),
  phone_verified_at timestamptz,
  first_seen_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ci_verified_has_date CHECK (trust_level <> 'verified' OR phone_verified_at IS NOT NULL),
  CONSTRAINT ci_seen_order CHECK (last_seen_at >= first_seen_at)
);
COMMENT ON TABLE public.client_identities IS 'Identité Client légère fondée sur le téléphone tel que stocké (aucune normalisation). N''est PAS un compte : aucun accès aux courses sans leur token privé.';
CREATE TRIGGER ci_touch BEFORE UPDATE ON public.client_identities
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.client_restrictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_identity_id uuid NOT NULL REFERENCES public.client_identities(id) ON DELETE RESTRICT,
  restriction_type text NOT NULL CHECK (restriction_type IN ('publish_blocked','verification_required')),
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  lifted_at timestamptz,
  lifted_by uuid,
  lift_reason text,
  CONSTRAINT cr_period CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT cr_lift_consistent CHECK (
    (lifted_at IS NULL AND lifted_by IS NULL AND lift_reason IS NULL)
    OR (lifted_at IS NOT NULL AND lifted_by IS NOT NULL AND lift_reason IS NOT NULL AND btrim(lift_reason) <> ''))
);
CREATE INDEX cr_identity_idx ON public.client_restrictions(client_identity_id) WHERE lifted_at IS NULL;
COMMENT ON TABLE public.client_restrictions IS 'Seule source de vérité des restrictions Client. Active si lifted_at IS NULL, starts_at <= now() et (ends_at IS NULL OR ends_at > now()). Jamais supprimée.';
CREATE TRIGGER cr_forbid_delete BEFORE DELETE ON public.client_restrictions
  FOR EACH ROW EXECUTE FUNCTION public.forbid_mutation();

ALTER TABLE public.rides ADD COLUMN client_identity_id uuid REFERENCES public.client_identities(id) ON DELETE RESTRICT;
CREATE INDEX rides_client_identity_created_idx ON public.rides(client_identity_id, created_at DESC);

-- Backfill : une identité par téléphone distinct des courses non démo
INSERT INTO public.client_identities(phone, last_display_name, first_seen_at, last_seen_at, created_at)
SELECT DISTINCT ON (client_phone) client_phone, client_name,
       min(created_at) OVER (PARTITION BY client_phone),
       max(created_at) OVER (PARTITION BY client_phone),
       min(created_at) OVER (PARTITION BY client_phone)
FROM public.rides WHERE is_demo = false
ORDER BY client_phone, created_at DESC;

UPDATE public.rides r SET client_identity_id = ci.id
FROM public.client_identities ci
WHERE r.is_demo = false AND ci.phone = r.client_phone;

-- Synchronisation à sens unique rides (INSERT) -> client_identities
CREATE OR REPLACE FUNCTION public.rides_attach_client_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_at timestamptz := coalesce(NEW.created_at, now());
BEGIN
  IF NEW.is_demo THEN
    NEW.client_identity_id := NULL;
    RETURN NEW;
  END IF;
  INSERT INTO public.client_identities AS ci (phone, last_display_name, first_seen_at, last_seen_at, created_at)
  VALUES (NEW.client_phone, NEW.client_name, v_at, v_at, v_at)
  ON CONFLICT (phone) DO UPDATE
    SET last_display_name = EXCLUDED.last_display_name,
        last_seen_at = greatest(ci.last_seen_at, EXCLUDED.last_seen_at)
  RETURNING ci.id INTO v_id;
  NEW.client_identity_id := v_id;
  RETURN NEW;
END $$;
CREATE TRIGGER rides_attach_client_identity BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.rides_attach_client_identity();

-- Droits
ALTER TABLE public.client_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_restrictions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.client_identities FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.client_restrictions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.client_identities TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.client_restrictions TO service_role;
REVOKE ALL ON FUNCTION public.rides_attach_client_identity() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rides_attach_client_identity() TO service_role;
