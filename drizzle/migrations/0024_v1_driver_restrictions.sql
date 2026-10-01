CREATE TABLE public.driver_restrictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  restriction_type text NOT NULL CONSTRAINT driver_restrictions_type_chk CHECK (restriction_type IN ('pool_blocked','shared_blocked','access_blocked')),
  reason text NOT NULL CONSTRAINT driver_restrictions_reason_chk CHECK (btrim(reason) <> ''),
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz,
  created_by uuid NOT NULL,
  source text NOT NULL DEFAULT 'admin' CONSTRAINT driver_restrictions_source_chk CHECK (source IN ('admin','penalty','system')),
  penalty_id uuid REFERENCES public.driver_penalties(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  lifted_at timestamptz,
  lifted_by uuid,
  lift_reason text,
  CONSTRAINT driver_restrictions_dates_chk CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT driver_restrictions_penalty_chk CHECK (source <> 'penalty' OR penalty_id IS NOT NULL),
  CONSTRAINT driver_restrictions_lift_chk CHECK (
    (lifted_at IS NULL AND lifted_by IS NULL AND lift_reason IS NULL)
    OR (lifted_at IS NOT NULL AND lifted_by IS NOT NULL AND lift_reason IS NOT NULL AND btrim(lift_reason) <> '')
  )
);

COMMENT ON TABLE public.driver_restrictions IS 'V1: operational restrictions on drivers. Active = lifted_at IS NULL AND starts_at <= now() AND (ends_at IS NULL OR ends_at > now()). Never deleted; not yet read by any operational function.';

CREATE INDEX driver_restrictions_driver_type_idx ON public.driver_restrictions (driver_id, restriction_type);
CREATE INDEX driver_restrictions_unlifted_idx ON public.driver_restrictions (driver_id, starts_at, ends_at) WHERE lifted_at IS NULL;

CREATE OR REPLACE FUNCTION public.driver_restrictions_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_pen_driver uuid; v_pen_demo boolean;
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'DRIVER_RESTRICTIONS_NO_DELETE';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.lifted_at IS NOT NULL THEN
      RAISE EXCEPTION 'DRIVER_RESTRICTION_CREATED_LIFTED';
    END IF;
    IF NEW.penalty_id IS NOT NULL THEN
      SELECT driver_id, is_demo INTO v_pen_driver, v_pen_demo FROM public.driver_penalties WHERE id = NEW.penalty_id;
      IF v_pen_driver IS DISTINCT FROM NEW.driver_id THEN
        RAISE EXCEPTION 'DRIVER_RESTRICTION_PENALTY_OTHER_DRIVER';
      END IF;
      IF v_pen_demo THEN
        RAISE EXCEPTION 'DRIVER_RESTRICTION_PENALTY_DEMO';
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE
  IF OLD.lifted_at IS NOT NULL THEN
    RAISE EXCEPTION 'DRIVER_RESTRICTION_LIFTED_IMMUTABLE';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.driver_id IS DISTINCT FROM OLD.driver_id
     OR NEW.restriction_type IS DISTINCT FROM OLD.restriction_type OR NEW.reason IS DISTINCT FROM OLD.reason
     OR NEW.starts_at IS DISTINCT FROM OLD.starts_at OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.source IS DISTINCT FROM OLD.source OR NEW.penalty_id IS DISTINCT FROM OLD.penalty_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'DRIVER_RESTRICTION_FIELD_IMMUTABLE';
  END IF;
  IF NEW.ends_at IS DISTINCT FROM OLD.ends_at
     AND NOT (NEW.ends_at IS NOT NULL AND (OLD.ends_at IS NULL OR NEW.ends_at < OLD.ends_at)) THEN
    RAISE EXCEPTION 'DRIVER_RESTRICTION_ENDS_AT_ONLY_SHORTEN';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER driver_restrictions_guard_row BEFORE INSERT OR UPDATE OR DELETE ON public.driver_restrictions
  FOR EACH ROW EXECUTE FUNCTION public.driver_restrictions_guard();
CREATE TRIGGER driver_restrictions_guard_truncate BEFORE TRUNCATE ON public.driver_restrictions
  FOR EACH STATEMENT EXECUTE FUNCTION public.driver_restrictions_guard();

REVOKE ALL ON FUNCTION public.driver_restrictions_guard() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON public.driver_restrictions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.driver_restrictions TO service_role;
ALTER TABLE public.driver_restrictions ENABLE ROW LEVEL SECURITY;