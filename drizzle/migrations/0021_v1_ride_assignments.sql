CREATE TABLE public.ride_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id uuid NOT NULL REFERENCES public.rides(id) ON DELETE RESTRICT,
  driver_id uuid NOT NULL REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  vehicle_id uuid NULL REFERENCES public.vehicles(id) ON DELETE RESTRICT,
  status text NOT NULL CHECK (status IN ('reserved','confirmed','released','completed','canceled')),
  source text NOT NULL CHECK (source IN ('legacy','v1')),
  started_at timestamptz NOT NULL,
  confirmed_at timestamptz NULL,
  ended_at timestamptz NULL,
  end_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((status IN ('reserved','confirmed')) = (ended_at IS NULL) OR source = 'legacy')
);
COMMENT ON TABLE public.ride_assignments IS 'V1: historique des affectations Chauffeur par course. Alimenté à sens unique depuis rides (legacy maître).';
CREATE UNIQUE INDEX ride_assignments_one_active ON public.ride_assignments(ride_id) WHERE status IN ('reserved','confirmed');
CREATE INDEX ride_assignments_ride ON public.ride_assignments(ride_id);
CREATE INDEX ride_assignments_driver ON public.ride_assignments(driver_id);

GRANT ALL ON public.ride_assignments TO service_role;
REVOKE ALL ON public.ride_assignments FROM anon, authenticated;
ALTER TABLE public.ride_assignments ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.ride_assignments_guard()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $$
DECLARE v_owner uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ASSIGNMENT_DELETE_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.ride_id IS DISTINCT FROM OLD.ride_id OR NEW.driver_id IS DISTINCT FROM OLD.driver_id
       OR NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id OR NEW.source IS DISTINCT FROM OLD.source
       OR NEW.started_at IS DISTINCT FROM OLD.started_at OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'ASSIGNMENT_IMMUTABLE_FIELD' USING ERRCODE = '23514';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
         (OLD.status = 'reserved'  AND NEW.status IN ('confirmed','released','canceled'))
      OR (OLD.status = 'confirmed' AND NEW.status IN ('completed','canceled'))) THEN
      RAISE EXCEPTION 'ASSIGNMENT_INVALID_TRANSITION % -> %', OLD.status, NEW.status USING ERRCODE = '23514';
    END IF;
    IF OLD.status IN ('released','completed','canceled') THEN
      RAISE EXCEPTION 'ASSIGNMENT_TERMINAL' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  -- INSERT
  IF NEW.vehicle_id IS NOT NULL THEN
    SELECT driver_id INTO v_owner FROM public.vehicles WHERE id = NEW.vehicle_id;
    IF v_owner IS DISTINCT FROM NEW.driver_id THEN
      RAISE EXCEPTION 'ASSIGNMENT_VEHICLE_NOT_OWNED' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.ride_assignments_guard() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER ride_assignments_guard BEFORE INSERT OR UPDATE OR DELETE ON public.ride_assignments
  FOR EACH ROW EXECUTE FUNCTION public.ride_assignments_guard();

-- Backfill: real completed rides with a driver only; no invented vehicle; demo excluded.
INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at, confirmed_at, ended_at, end_reason, created_at)
SELECT r.id, r.chauffeur_id, NULL, 'completed', 'legacy', r.started_negotiation_at, r.boarded_at, r.resolved_at, 'legacy_backfill', now()
FROM public.rides r
WHERE NOT r.is_demo AND r.chauffeur_id IS NOT NULL AND r.status = 'completed'
  AND r.started_negotiation_at IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = r.chauffeur_id);

CREATE OR REPLACE FUNCTION public.rides_sync_assignments()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.is_demo THEN RETURN NULL; END IF;

  -- Chauffeur retiré ou remplacé : libère l'affectation active de l'ancien
  IF TG_OP = 'UPDATE' AND OLD.chauffeur_id IS NOT NULL AND NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id THEN
    UPDATE public.ride_assignments SET status='released', ended_at=now(), end_reason='legacy_released'
     WHERE ride_id=NEW.id AND driver_id=OLD.chauffeur_id AND status='reserved';
  END IF;

  -- Nouveau chauffeur : nouvelle affectation reserved
  IF NEW.chauffeur_id IS NOT NULL AND (TG_OP='INSERT' OR NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id) THEN
    INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at)
    VALUES (NEW.id, NEW.chauffeur_id, NEW.vehicle_id, 'reserved', 'legacy', now());
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.chauffeur_id IS NOT NULL THEN
    IF OLD.status='negotiating' AND NEW.status='onboard' THEN
      UPDATE public.ride_assignments SET status='confirmed', confirmed_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    ELSIF OLD.status='onboard' AND NEW.status='completed' THEN
      UPDATE public.ride_assignments SET status='completed', ended_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='confirmed';
    ELSIF OLD.status='negotiating' AND NEW.status='canceled' THEN
      -- Seul cancel_ride_public produit ce chemin (l'expiration 2h ne touche que pending) ; libellé neutre.
      UPDATE public.ride_assignments SET status='canceled', ended_at=now(), end_reason='legacy_ride_canceled'
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.rides_sync_assignments() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER rides_sync_assignments AFTER INSERT OR UPDATE OF status, chauffeur_id ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.rides_sync_assignments();