CREATE TABLE public.associates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES public.profiles(user_id) ON DELETE SET NULL,
  partner_key text NOT NULL UNIQUE CHECK (btrim(partner_key) <> ''),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  phone text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz NULL
);
CREATE UNIQUE INDEX associates_user_id_uniq ON public.associates(user_id) WHERE user_id IS NOT NULL;

CREATE TABLE public.associate_share_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  associate_id uuid NOT NULL REFERENCES public.associates(id) ON DELETE RESTRICT,
  share_percent numeric(5,2) NOT NULL CHECK (share_percent >= 0 AND share_percent <= 100),
  effective_from date NOT NULL,
  effective_to date NULL,
  source text NOT NULL CHECK (source IN ('legacy_migration','admin')),
  created_by uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT asr_period_chk CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT asr_admin_author_chk CHECK (source <> 'admin' OR created_by IS NOT NULL)
);
CREATE INDEX asr_associate_idx ON public.associate_share_rules(associate_id, effective_from);
CREATE INDEX asr_from_idx ON public.associate_share_rules(effective_from);

REVOKE ALL ON public.associates, public.associate_share_rules FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.associates, public.associate_share_rules TO service_role;
ALTER TABLE public.associates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.associate_share_rules ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.associates_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ASSOCIATES_NO_DELETE' USING HINT = 'use deleted_at';
  END IF;
  IF NEW.partner_key IS DISTINCT FROM OLD.partner_key THEN
    RAISE EXCEPTION 'ASSOCIATES_PARTNER_KEY_IMMUTABLE';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'ASSOCIATES_IDENTITY_IMMUTABLE';
  END IF;
  -- user_id: may be set once (NULL -> value) or cleared by ON DELETE SET NULL; never replaced by another account
  IF OLD.user_id IS NOT NULL AND NEW.user_id IS NOT NULL AND NEW.user_id <> OLD.user_id THEN
    RAISE EXCEPTION 'ASSOCIATES_USER_ID_NOT_REPLACEABLE';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER associates_guard BEFORE UPDATE OR DELETE ON public.associates
  FOR EACH ROW EXECUTE FUNCTION public.associates_guard();
CREATE TRIGGER associates_touch BEFORE UPDATE ON public.associates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER associates_no_truncate BEFORE TRUNCATE ON public.associates
  FOR EACH STATEMENT EXECUTE FUNCTION public.associates_guard();

CREATE OR REPLACE FUNCTION public.associate_share_rules_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  v_d date;
  v_sum numeric;
BEGIN
  IF TG_OP IN ('DELETE','TRUNCATE') THEN
    RAISE EXCEPTION 'SHARE_RULES_NO_DELETE';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.effective_from < v_today THEN
      RAISE EXCEPTION 'SHARE_RULE_RETROACTIVE_START';
    END IF;
  ELSE
    IF NEW.id <> OLD.id OR NEW.associate_id <> OLD.associate_id OR NEW.source <> OLD.source
       OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'SHARE_RULE_IDENTITY_IMMUTABLE';
    END IF;
    IF OLD.effective_from <= v_today THEN
      -- started rule: only closing via effective_to
      IF NEW.share_percent <> OLD.share_percent OR NEW.effective_from <> OLD.effective_from THEN
        RAISE EXCEPTION 'SHARE_RULE_STARTED_IMMUTABLE';
      END IF;
      IF NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
        IF OLD.effective_to IS NOT NULL AND OLD.effective_to <= v_today THEN
          RAISE EXCEPTION 'SHARE_RULE_PERIOD_ELAPSED';
        END IF;
        IF NEW.effective_to IS NULL THEN
          RAISE EXCEPTION 'SHARE_RULE_END_NOT_REMOVABLE';
        END IF;
        IF NEW.effective_to < v_today THEN
          RAISE EXCEPTION 'SHARE_RULE_END_IN_PAST';
        END IF;
        IF OLD.effective_to IS NOT NULL AND NEW.effective_to > OLD.effective_to THEN
          RAISE EXCEPTION 'SHARE_RULE_END_NOT_EXTENDABLE';
        END IF;
      END IF;
      RETURN NEW; -- shrinking a period can neither create overlap nor raise any sum
    ELSE
      IF NEW.effective_from <= v_today THEN
        RAISE EXCEPTION 'SHARE_RULE_FUTURE_MUST_STAY_FUTURE';
      END IF;
    END IF;
  END IF;

  -- per-associate overlap on [from, to), NULL to = infinity
  IF EXISTS (
    SELECT 1 FROM public.associate_share_rules o
    WHERE o.associate_id = NEW.associate_id AND o.id <> NEW.id
      AND NEW.effective_from < COALESCE(o.effective_to, 'infinity'::date)
      AND o.effective_from < COALESCE(NEW.effective_to, 'infinity'::date)
  ) THEN
    RAISE EXCEPTION 'SHARE_RULE_OVERLAP';
  END IF;

  -- global cap: serialize all writers, then check every date where the sum can rise within NEW's period
  PERFORM pg_advisory_xact_lock(hashtext('associate_share_rules_cap')::bigint);
  FOR v_d IN
    SELECT NEW.effective_from
    UNION
    SELECT o.effective_from FROM public.associate_share_rules o
    WHERE o.id <> NEW.id
      AND o.effective_from > NEW.effective_from
      AND o.effective_from < COALESCE(NEW.effective_to, 'infinity'::date)
  LOOP
    SELECT NEW.share_percent + COALESCE(SUM(o.share_percent), 0) INTO v_sum
    FROM public.associate_share_rules o
    WHERE o.id <> NEW.id
      AND o.effective_from <= v_d
      AND v_d < COALESCE(o.effective_to, 'infinity'::date);
    IF v_sum > 100 THEN
      RAISE EXCEPTION 'SHARE_RULES_CAP_EXCEEDED' USING DETAIL = format('date=%s sum=%s', v_d, v_sum);
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

CREATE TRIGGER asr_guard BEFORE INSERT OR UPDATE OR DELETE ON public.associate_share_rules
  FOR EACH ROW EXECUTE FUNCTION public.associate_share_rules_guard();
CREATE TRIGGER asr_no_truncate BEFORE TRUNCATE ON public.associate_share_rules
  FOR EACH STATEMENT EXECUTE FUNCTION public.associate_share_rules_guard();
CREATE TRIGGER asr_touch BEFORE UPDATE ON public.associate_share_rules
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

REVOKE ALL ON FUNCTION public.associates_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.associate_share_rules_guard() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.associates_guard(), public.associate_share_rules_guard() TO service_role;

-- Backfill: associates_settings is empty at migration time (verified) -> 0 associates, 0 rules.
COMMENT ON TABLE public.associate_share_rules IS 'V1 dated shares [from,to); started rules only closable; global sum <= 100% via trigger + advisory lock. Not synced from associates_settings.';