-- LOT 1B-9: audit_events + notification_outbox (foundations only, no producers, no workers)

CREATE TABLE public.audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type text NOT NULL,
  entity_type text NOT NULL,
  entity_id text,
  actor_type text NOT NULL,
  actor_id uuid,
  source text NOT NULL,
  reason text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  correlation_id uuid,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ae_event_type_not_blank CHECK (btrim(event_type) <> ''),
  CONSTRAINT ae_entity_type_not_blank CHECK (btrim(entity_type) <> ''),
  CONSTRAINT ae_actor_type CHECK (actor_type IN ('admin','driver','client','associate','system','service')),
  CONSTRAINT ae_source CHECK (source IN ('rpc','trigger','system','migration')),
  CONSTRAINT ae_metadata_object CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT ae_actor_consistency CHECK (actor_type NOT IN ('system','service') OR actor_id IS NULL),
  CONSTRAINT ae_metadata_no_secrets CHECK (NOT (metadata ?| ARRAY[
    'access_token','access_token_hash','pin','pin_hash','password','secret','xfin_secret',
    'api_key','apikey','credential','credentials','phone','client_phone','driver_phone',
    'msisdn','document','document_base64','photo','photo_base64'
  ]))
);

CREATE INDEX ae_entity_idx ON public.audit_events (entity_type, entity_id, occurred_at DESC);
CREATE INDEX ae_actor_idx ON public.audit_events (actor_id, occurred_at DESC) WHERE actor_id IS NOT NULL;
CREATE INDEX ae_event_type_idx ON public.audit_events (event_type, occurred_at DESC);

CREATE OR REPLACE FUNCTION public.audit_events_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'AUDIT_EVENTS_APPEND_ONLY';
END $$;

CREATE TRIGGER audit_events_no_mutation BEFORE UPDATE OR DELETE ON public.audit_events
  FOR EACH ROW EXECUTE FUNCTION public.audit_events_guard();
CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON public.audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.audit_events_guard();

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.audit_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.audit_events TO service_role;

COMMENT ON TABLE public.audit_events IS 'V1 cross-cutting admin/security/finance audit journal. Append-only, no backfill, no secrets in metadata. Distinct from ride_events (business history of a ride).';

-- ============================================================

CREATE TABLE public.notification_outbox (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dedupe_key text NOT NULL UNIQUE,
  notification_type text NOT NULL,
  channel text NOT NULL,
  recipient_type text NOT NULL,
  recipient_id uuid NOT NULL,
  ride_id uuid REFERENCES public.rides(id) ON DELETE RESTRICT,
  ride_event_id bigint REFERENCES public.ride_events(id) ON DELETE RESTRICT,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  attempt_count integer NOT NULL DEFAULT 0,
  available_at timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz,
  locked_by text,
  last_attempt_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT no_dedupe_key_not_blank CHECK (btrim(dedupe_key) <> ''),
  CONSTRAINT no_type_not_blank CHECK (btrim(notification_type) <> ''),
  CONSTRAINT no_channel CHECK (channel IN ('in_app','push')),
  CONSTRAINT no_recipient_type CHECK (recipient_type IN ('client','driver','admin','associate')),
  CONSTRAINT no_status CHECK (status IN ('pending','processing','sent','failed','canceled')),
  CONSTRAINT no_attempt_count CHECK (attempt_count >= 0),
  CONSTRAINT no_locked_by_not_blank CHECK (locked_by IS NULL OR btrim(locked_by) <> ''),
  CONSTRAINT no_payload_object CHECK (jsonb_typeof(payload) = 'object'),
  CONSTRAINT no_sent_at_consistency CHECK ((status = 'sent') = (sent_at IS NOT NULL)),
  CONSTRAINT no_payload_no_secrets CHECK (NOT (payload ?| ARRAY[
    'access_token','access_token_hash','pin','pin_hash','password','secret','xfin_secret',
    'api_key','apikey','credential','credentials','phone','client_phone','driver_phone',
    'msisdn','document','document_base64','photo','photo_base64'
  ]))
);

CREATE INDEX no_claim_idx ON public.notification_outbox (status, available_at, id);
CREATE INDEX no_ride_idx ON public.notification_outbox (ride_id) WHERE ride_id IS NOT NULL;
CREATE INDEX no_ride_event_idx ON public.notification_outbox (ride_event_id) WHERE ride_event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notification_outbox_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX_NO_TRUNCATE';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.dedupe_key IS DISTINCT FROM OLD.dedupe_key
       OR NEW.notification_type IS DISTINCT FROM OLD.notification_type
       OR NEW.channel IS DISTINCT FROM OLD.channel
       OR NEW.recipient_type IS DISTINCT FROM OLD.recipient_type
       OR NEW.recipient_id IS DISTINCT FROM OLD.recipient_id
       OR NEW.ride_id IS DISTINCT FROM OLD.ride_id
       OR NEW.ride_event_id IS DISTINCT FROM OLD.ride_event_id
       OR NEW.payload IS DISTINCT FROM OLD.payload
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'NOTIFICATION_OUTBOX_IMMUTABLE_FIELDS';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NOT (
           (OLD.status = 'pending'    AND NEW.status IN ('processing','canceled'))
        OR (OLD.status = 'processing' AND NEW.status IN ('pending','sent','failed','canceled'))
      ) THEN
        RAISE EXCEPTION 'NOTIFICATION_OUTBOX_BAD_TRANSITION' USING DETAIL = format('%s -> %s', OLD.status, NEW.status);
      END IF;
    END IF;

    IF NEW.attempt_count < OLD.attempt_count THEN
      RAISE EXCEPTION 'NOTIFICATION_OUTBOX_ATTEMPT_COUNT_DECREASE';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX_NO_DELETE';
  END IF;

  -- INSERT
  IF NEW.status <> 'pending' THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX_MUST_START_PENDING';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER no_guard BEFORE INSERT OR UPDATE OR DELETE ON public.notification_outbox
  FOR EACH ROW EXECUTE FUNCTION public.notification_outbox_guard();
CREATE TRIGGER no_no_truncate BEFORE TRUNCATE ON public.notification_outbox
  FOR EACH STATEMENT EXECUTE FUNCTION public.notification_outbox_guard();
CREATE TRIGGER no_touch BEFORE UPDATE ON public.notification_outbox
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_outbox FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.notification_outbox TO service_role;

REVOKE ALL ON FUNCTION public.audit_events_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notification_outbox_guard() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.audit_events_guard(), public.notification_outbox_guard() TO service_role;

COMMENT ON TABLE public.notification_outbox IS 'V1 reliable notification queue (in_app/push only, never whatsapp). Content immutable after insert; sent/failed/canceled terminal. No producer and no worker in this lot.';