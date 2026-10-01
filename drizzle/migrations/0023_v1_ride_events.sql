CREATE TABLE public.ride_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ride_id uuid NOT NULL REFERENCES public.rides(id) ON DELETE RESTRICT,
  assignment_id uuid NULL REFERENCES public.ride_assignments(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN (
    'legacy_imported','published','driver_reserved','driver_released','returned_to_pool',
    'contact_pending','contact_confirmed','price_confirmed','driver_en_route','driver_arrived',
    'onboard','dropped_off','canceled_by_client','canceled_by_driver','contact_failed',
    'expired','incident','legacy_canceled_unknown')),
  source text NOT NULL CHECK (source IN ('legacy_backfill','legacy_observed','v1')),
  actor_type text NOT NULL CHECK (actor_type IN ('client','driver','admin','system','unknown')),
  actor_id uuid NULL,
  from_status_v2 text NULL CHECK (from_status_v2 IN ('DRAFT','PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED','ONBOARD','COMPLETED','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','CONTACT_FAILED','EXPIRED','INCIDENT')),
  to_status_v2 text NULL CHECK (to_status_v2 IN ('DRAFT','PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED','ONBOARD','COMPLETED','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','CONTACT_FAILED','EXPIRED','INCIDENT')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CHECK (actor_type NOT IN ('system','unknown') OR actor_id IS NULL)
);
COMMENT ON TABLE public.ride_events IS 'V1: journal métier append-only des courses. Observe le legacy (sens unique), ne pilote rien. Tri historique: occurred_at, id.';
CREATE INDEX ride_events_ride ON public.ride_events(ride_id, id);
CREATE INDEX ride_events_assignment ON public.ride_events(assignment_id, id) WHERE assignment_id IS NOT NULL;
CREATE INDEX ride_events_type_time ON public.ride_events(event_type, occurred_at DESC);

GRANT ALL ON public.ride_events TO service_role;
REVOKE ALL ON public.ride_events FROM PUBLIC, anon, authenticated;
ALTER TABLE public.ride_events ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.ride_events_guard()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'RIDE_EVENTS_APPEND_ONLY' USING ERRCODE = '42501';
END $$;
REVOKE ALL ON FUNCTION public.ride_events_guard() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER ride_events_append_only BEFORE UPDATE OR DELETE ON public.ride_events
  FOR EACH ROW EXECUTE FUNCTION public.ride_events_guard();
CREATE TRIGGER ride_events_no_truncate BEFORE TRUNCATE ON public.ride_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.ride_events_guard();

-- Backfill: un seul legacy_imported par course réelle existante, aucun événement reconstruit.
INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, to_status_v2, payload)
SELECT r.id, 'legacy_imported', 'legacy_backfill', 'system', r.status_v2,
       jsonb_build_object('legacy_status', r.status, 'imported_from', 'legacy_mvp')
FROM public.rides r WHERE NOT r.is_demo;

-- Événements de course, générés depuis rides uniquement.
CREATE OR REPLACE FUNCTION public.rides_emit_events()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.is_demo THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, to_status_v2)
    VALUES (NEW.id, 'published', 'legacy_observed',
            CASE WHEN NEW.client_identity_id IS NULL THEN 'unknown' ELSE 'client' END,
            NEW.client_identity_id, 'PENDING');
    RETURN NULL;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;

  IF NEW.status = 'canceled' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, from_status_v2, to_status_v2, payload)
    VALUES (NEW.id, 'legacy_canceled_unknown', 'legacy_observed', 'unknown', OLD.status_v2, NEW.status_v2,
            jsonb_build_object('legacy_from_status', OLD.status, 'legacy_to_status', NEW.status));
  ELSIF OLD.status = 'negotiating' AND NEW.status = 'pending' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'returned_to_pool', 'legacy_observed', 'unknown', 'CONTACT_PENDING', 'PENDING');
  ELSIF OLD.status = 'negotiating' AND NEW.status = 'onboard' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'onboard', 'legacy_observed', CASE WHEN NEW.chauffeur_id IS NULL THEN 'unknown' ELSE 'driver' END,
            NEW.chauffeur_id, 'CONTACT_PENDING', 'ONBOARD');
  ELSIF OLD.status = 'onboard' AND NEW.status = 'completed' THEN
    INSERT INTO public.ride_events (ride_id, event_type, source, actor_type, actor_id, from_status_v2, to_status_v2)
    VALUES (NEW.id, 'dropped_off', 'legacy_observed', CASE WHEN NEW.chauffeur_id IS NULL THEN 'unknown' ELSE 'driver' END,
            NEW.chauffeur_id, 'ONBOARD', 'COMPLETED');
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.rides_emit_events() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER rides_emit_events AFTER INSERT OR UPDATE OF status ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.rides_emit_events();

-- Événements d'affectation, générés depuis ride_assignments uniquement.
CREATE OR REPLACE FUNCTION public.ride_assignments_emit_events()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.rides r WHERE r.id = NEW.ride_id AND r.is_demo)
     OR EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = NEW.driver_id AND d.is_demo) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' AND NEW.status = 'reserved' THEN
    INSERT INTO public.ride_events (ride_id, assignment_id, event_type, source, actor_type, actor_id)
    VALUES (NEW.ride_id, NEW.id, 'driver_reserved', 'legacy_observed', 'driver', NEW.driver_id);
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'reserved' AND NEW.status = 'released' THEN
    INSERT INTO public.ride_events (ride_id, assignment_id, event_type, source, actor_type)
    VALUES (NEW.ride_id, NEW.id, 'driver_released', 'legacy_observed', 'unknown');
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.ride_assignments_emit_events() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER ride_assignments_emit_events AFTER INSERT OR UPDATE OF status ON public.ride_assignments
  FOR EACH ROW EXECUTE FUNCTION public.ride_assignments_emit_events();