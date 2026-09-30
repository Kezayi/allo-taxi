-- LOT 1B-5 : extension V1 de rides, legacy status reste maître.

ALTER TABLE public.rides
  ADD COLUMN passenger_count smallint CHECK (passenger_count IS NULL OR passenger_count BETWEEN 1 AND 8),
  ADD COLUMN price_final integer CHECK (price_final IS NULL OR price_final BETWEEN 500 AND 100000),
  ADD COLUMN price_final_confirmed_at timestamptz,
  ADD COLUMN vehicle_id uuid REFERENCES public.vehicles(id) ON DELETE RESTRICT,
  ADD COLUMN status_v2 text CHECK (status_v2 IS NULL OR status_v2 IN (
    'DRAFT','PENDING','CONTACT_PENDING','CONFIRMED','DRIVER_EN_ROUTE','DRIVER_ARRIVED',
    'ONBOARD','COMPLETED','CANCELED_BY_CLIENT','CANCELED_BY_DRIVER','CONTACT_FAILED','EXPIRED','INCIDENT')),
  ADD COLUMN status_v2_changed_at timestamptz,
  ADD COLUMN access_token_hash bytea;

ALTER TABLE public.rides ADD CONSTRAINT rides_price_final_confirmed_needs_price
  CHECK (price_final_confirmed_at IS NULL OR price_final IS NOT NULL);
ALTER TABLE public.rides ADD CONSTRAINT rides_vehicle_needs_chauffeur
  CHECK (vehicle_id IS NULL OR chauffeur_id IS NOT NULL);
CREATE INDEX rides_vehicle_idx ON public.rides(vehicle_id) WHERE vehicle_id IS NOT NULL;
CREATE INDEX rides_status_v2_idx ON public.rides(status_v2);

COMMENT ON COLUMN public.rides.passenger_count IS 'NULL = inconnu (historique). Ne jamais backfiller 1. Obligatoire à partir de create_ride_public V2.';
COMMENT ON COLUMN public.rides.price_final IS 'Prix réellement convenu. NULL = inconnu ; ne jamais recopier price_proposed.';
COMMENT ON COLUMN public.rides.status_v2 IS 'Projection à sens unique de rides.status (legacy maître). Legacy canceled -> NULL : cause ambiguë (annulation client OU expiration 2 h par check_and_purge_negotiation_timeouts).';
COMMENT ON COLUMN public.rides.access_token_hash IS 'SHA-256 du token. Prépare le LOT 4. DETTE : access_token reste en clair et lisible par le chauffeur affecté (policy Assigned driver reads ride).';

-- Backfill (aucun trigger existant ne porte sur ces colonnes)
UPDATE public.rides SET
  access_token_hash = extensions.digest(access_token::text, 'sha256'),
  status_v2 = CASE status WHEN 'pending' THEN 'PENDING' WHEN 'negotiating' THEN 'CONTACT_PENDING'
                          WHEN 'onboard' THEN 'ONBOARD' WHEN 'completed' THEN 'COMPLETED' ELSE NULL END;

CREATE OR REPLACE FUNCTION public.rides_v1_projection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_vehicle uuid; v_owner uuid;
BEGIN
  IF TG_OP = 'INSERT' OR NEW.access_token IS DISTINCT FROM OLD.access_token THEN
    NEW.access_token_hash := CASE WHEN NEW.access_token IS NULL THEN NULL
                                  ELSE extensions.digest(NEW.access_token::text, 'sha256') END;
  END IF;

  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_v2 := CASE NEW.status WHEN 'pending' THEN 'PENDING' WHEN 'negotiating' THEN 'CONTACT_PENDING'
                                     WHEN 'onboard' THEN 'ONBOARD' WHEN 'completed' THEN 'COMPLETED' ELSE NULL END;
    NEW.status_v2_changed_at := CASE WHEN TG_OP = 'INSERT' THEN coalesce(NEW.created_at, now()) ELSE now() END;
  END IF;

  IF (TG_OP = 'INSERT' AND NEW.chauffeur_id IS NOT NULL AND NEW.vehicle_id IS NULL)
     OR (TG_OP = 'UPDATE' AND NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id) THEN
    IF NEW.chauffeur_id IS NULL THEN
      NEW.vehicle_id := NULL;
    ELSE
      SELECT v.id INTO v_vehicle FROM public.drivers d JOIN public.vehicles v
        ON v.id = d.active_vehicle_id AND v.driver_id = d.user_id AND v.deleted_at IS NULL
       WHERE d.user_id = NEW.chauffeur_id;
      NEW.vehicle_id := v_vehicle;
    END IF;
  END IF;

  IF NEW.vehicle_id IS NOT NULL THEN
    IF NEW.chauffeur_id IS NULL THEN
      RAISE EXCEPTION 'RIDE_VEHICLE_WITHOUT_DRIVER' USING ERRCODE = '23514';
    END IF;
    SELECT driver_id INTO v_owner FROM public.vehicles WHERE id = NEW.vehicle_id;
    IF v_owner IS DISTINCT FROM NEW.chauffeur_id THEN
      RAISE EXCEPTION 'RIDE_VEHICLE_NOT_OWNED' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER rides_v1_projection BEFORE INSERT OR UPDATE OF status, chauffeur_id, access_token, vehicle_id
  ON public.rides FOR EACH ROW EXECUTE FUNCTION public.rides_v1_projection();

REVOKE ALL ON FUNCTION public.rides_v1_projection() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rides_v1_projection() TO service_role;
