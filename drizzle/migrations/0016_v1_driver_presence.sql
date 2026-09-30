-- LOT 1B-2 : présence Chauffeur (projection V1, drivers reste maître)
CREATE TABLE public.driver_presence (
  driver_id uuid PRIMARY KEY REFERENCES public.drivers(user_id) ON DELETE CASCADE,
  availability text NOT NULL DEFAULT 'offline' CHECK (availability IN ('online','offline','paused')),
  accepting_new_shared boolean NOT NULL DEFAULT true,
  lat double precision NULL CHECK (lat IS NULL OR lat BETWEEN -90 AND 90),
  lng double precision NULL CHECK (lng IS NULL OR lng BETWEEN -180 AND 180),
  accuracy_m real NULL CHECK (accuracy_m IS NULL OR accuracy_m >= 0),
  heading_deg real NULL CHECK (heading_deg IS NULL OR (heading_deg >= 0 AND heading_deg < 360)),
  position_at timestamptz NULL,
  last_heartbeat_at timestamptz NULL,
  went_online_at timestamptz NULL,
  auto_closed_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON public.driver_presence FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.driver_presence TO service_role;
ALTER TABLE public.driver_presence ENABLE ROW LEVEL SECURITY;

CREATE INDEX driver_presence_online_idx ON public.driver_presence(availability) WHERE availability = 'online';
CREATE INDEX driver_presence_heartbeat_idx ON public.driver_presence(last_heartbeat_at);

CREATE TRIGGER driver_presence_touch_updated_at BEFORE UPDATE ON public.driver_presence
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

COMMENT ON TABLE public.driver_presence IS 'Projection V1 de présence, alimentée à sens unique depuis drivers (legacy maître). Valeurs initiales issues du backfill legacy.';

-- Backfill legacy
INSERT INTO public.driver_presence (driver_id, availability, accepting_new_shared, lat, lng, position_at, last_heartbeat_at, went_online_at)
SELECT user_id,
       CASE WHEN is_online THEN 'online' ELSE 'offline' END,
       true, last_lat, last_lng, last_seen_at, last_seen_at,
       CASE WHEN is_online AND last_seen_at IS NOT NULL THEN last_seen_at END
FROM public.drivers;

-- Synchronisation drivers -> driver_presence (SECURITY DEFINER : l'inscription Chauffeur insère dans drivers en tant qu'authenticated)
CREATE OR REPLACE FUNCTION public.sync_driver_presence_from_legacy()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.driver_presence (driver_id, availability, lat, lng, position_at, last_heartbeat_at, went_online_at)
    VALUES (NEW.user_id, CASE WHEN NEW.is_online THEN 'online' ELSE 'offline' END,
            NEW.last_lat, NEW.last_lng, NEW.last_seen_at, NEW.last_seen_at,
            CASE WHEN NEW.is_online THEN now() END)
    ON CONFLICT (driver_id) DO NOTHING;
    RETURN NEW;
  END IF;

  INSERT INTO public.driver_presence (driver_id) VALUES (NEW.user_id) ON CONFLICT (driver_id) DO NOTHING;
  UPDATE public.driver_presence SET
    availability = CASE WHEN NEW.is_online THEN 'online' ELSE 'offline' END,
    lat = NEW.last_lat,
    lng = NEW.last_lng,
    position_at = NEW.last_seen_at,
    last_heartbeat_at = NEW.last_seen_at,
    went_online_at = CASE WHEN NEW.is_online AND NOT OLD.is_online THEN now() ELSE went_online_at END
  WHERE driver_id = NEW.user_id;
  RETURN NEW;
END $$;

CREATE TRIGGER drivers_sync_presence_insert AFTER INSERT ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.sync_driver_presence_from_legacy();
CREATE TRIGGER drivers_sync_presence_update AFTER UPDATE OF is_online, last_lat, last_lng, last_seen_at ON public.drivers
  FOR EACH ROW
  WHEN (OLD.is_online IS DISTINCT FROM NEW.is_online OR OLD.last_lat IS DISTINCT FROM NEW.last_lat
        OR OLD.last_lng IS DISTINCT FROM NEW.last_lng OR OLD.last_seen_at IS DISTINCT FROM NEW.last_seen_at)
  EXECUTE FUNCTION public.sync_driver_presence_from_legacy();

REVOKE ALL ON FUNCTION public.sync_driver_presence_from_legacy() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_driver_presence_from_legacy() TO service_role;