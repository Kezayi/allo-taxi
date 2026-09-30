-- LOT 1B-1 : structure Chauffeur + véhicules + fondations documentaires

-- 1. drivers : nouvelles colonnes
ALTER TABLE public.drivers
  ADD COLUMN last_name text NULL,
  ADD COLUMN whatsapp_phone text NULL,
  ADD COLUMN onboarding_status text NOT NULL DEFAULT 'legacy',
  ADD COLUMN active_vehicle_id uuid NULL;

ALTER TABLE public.drivers
  ADD CONSTRAINT drivers_onboarding_status_check
    CHECK (onboarding_status IN ('legacy','draft','submitted','under_review','approved','rejected','expired')),
  ADD CONSTRAINT drivers_whatsapp_phone_format_check
    CHECK (whatsapp_phone IS NULL OR whatsapp_phone ~ '^\+241[0-9]{8,9}$');

-- Backfill : le formulaire Chauffeur legacy libelle ce champ « Téléphone WhatsApp » (chauffeur.tsx).
UPDATE public.drivers SET whatsapp_phone = phone WHERE whatsapp_phone IS NULL;

COMMENT ON COLUMN public.drivers.phone IS 'LEGACY: remplacé fonctionnellement par profiles.phone (authentification) et drivers.whatsapp_phone (contact opérationnel). Conservé pour compatibilité MVP.';

-- 2. vehicles
CREATE TABLE public.vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL,
  make text NULL,
  model text NOT NULL,
  color text NULL,
  plate text NOT NULL,
  plate_normalized text GENERATED ALWAYS AS (public.normalize_plate(plate)) STORED,
  has_ac boolean NOT NULL DEFAULT false,
  registered_seats smallint NULL CHECK (registered_seats IS NULL OR registered_seats BETWEEN 2 AND 9),
  passenger_capacity smallint GENERATED ALWAYS AS (CASE WHEN registered_seats IS NULL THEN NULL ELSE registered_seats - 1 END) STORED,
  capacity_source text NULL CHECK (capacity_source IS NULL OR capacity_source = 'registration_card'),
  validation_status text NOT NULL DEFAULT 'pending' CHECK (validation_status IN ('pending','approved','rejected','suspended')),
  validated_by uuid NULL,
  validated_at timestamptz NULL,
  is_active boolean NOT NULL DEFAULT false,
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz NULL,
  CONSTRAINT vehicles_plate_normalized_not_null CHECK (plate_normalized IS NOT NULL),
  -- NO ACTION DEFERRABLE (équivalent RESTRICT au commit) : permet au trigger de purge démo ci-dessous
  -- de retirer les véhicules démo dans la même transaction que reset_demo_data().
  CONSTRAINT vehicles_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(user_id)
    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
);

REVOKE ALL ON public.vehicles FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.vehicles TO service_role;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

CREATE INDEX vehicles_driver_id_idx ON public.vehicles(driver_id);
CREATE UNIQUE INDEX vehicles_plate_normalized_uniq ON public.vehicles(plate_normalized) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX vehicles_one_active_per_driver ON public.vehicles(driver_id) WHERE is_active AND deleted_at IS NULL;

CREATE TRIGGER vehicles_touch_updated_at BEFORE UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Un véhicule ne change jamais de propriétaire.
CREATE OR REPLACE FUNCTION public.vehicles_forbid_owner_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.driver_id IS DISTINCT FROM OLD.driver_id THEN
    RAISE EXCEPTION 'VEHICLE_OWNER_IMMUTABLE' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER vehicles_owner_immutable BEFORE UPDATE OF driver_id ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.vehicles_forbid_owner_change();

-- 3. Backfill : un véhicule par chauffeur existant, sans rien inventer.
INSERT INTO public.vehicles (driver_id, model, plate, has_ac, validation_status, is_active, is_demo)
SELECT user_id, vehicle_model, vehicle_plate, has_ac, 'pending', true, is_demo
FROM public.drivers;

UPDATE public.drivers d SET active_vehicle_id = v.id
FROM public.vehicles v WHERE v.driver_id = d.user_id AND v.is_active AND v.deleted_at IS NULL;

-- 4. FK + cohérence active_vehicle_id
ALTER TABLE public.drivers
  ADD CONSTRAINT drivers_active_vehicle_id_fkey FOREIGN KEY (active_vehicle_id) REFERENCES public.vehicles(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.drivers_check_active_vehicle()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.active_vehicle_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vehicles v
    WHERE v.id = NEW.active_vehicle_id AND v.driver_id = NEW.user_id AND v.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'ACTIVE_VEHICLE_NOT_OWNED' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER drivers_active_vehicle_consistency BEFORE INSERT OR UPDATE OF active_vehicle_id ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.drivers_check_active_vehicle();

-- Purge des véhicules démo quand reset_demo_data() supprime un chauffeur démo (RPC inchangée).
CREATE OR REPLACE FUNCTION public.drivers_purge_demo_vehicles()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.is_demo THEN
    DELETE FROM public.vehicles WHERE driver_id = OLD.user_id AND is_demo;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER drivers_purge_demo_vehicles AFTER DELETE ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.drivers_purge_demo_vehicles();

-- 5. driver_documents (métadonnées uniquement, aucun bucket)
CREATE TABLE public.driver_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  vehicle_id uuid NULL REFERENCES public.vehicles(id) ON DELETE RESTRICT,
  doc_type text NOT NULL CHECK (doc_type IN ('driving_license','registration_card','insurance','technical_inspection','driver_photo','vehicle_photo','vehicle_plate_photo')),
  storage_bucket text NOT NULL DEFAULT 'driver-documents',
  storage_path text NOT NULL UNIQUE,
  mime_type text NULL,
  size_bytes integer NULL CHECK (size_bytes IS NULL OR (size_bytes > 0 AND size_bytes <= 8388608)),
  sha256 text NULL,
  issued_on date NULL,
  expires_on date NULL,
  status text NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted','under_review','approved','rejected','expired','superseded')),
  version integer NOT NULL DEFAULT 1 CHECK (version >= 1),
  supersedes_id uuid NULL REFERENCES public.driver_documents(id) ON DELETE RESTRICT,
  is_current boolean NOT NULL DEFAULT true,
  uploaded_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT driver_documents_dates_check CHECK (expires_on IS NULL OR issued_on IS NULL OR expires_on >= issued_on),
  CONSTRAINT driver_documents_scope_check CHECK (
    (doc_type IN ('driving_license','driver_photo') AND vehicle_id IS NULL)
    OR (doc_type IN ('registration_card','insurance','technical_inspection','vehicle_photo','vehicle_plate_photo') AND vehicle_id IS NOT NULL)
  )
);

REVOKE ALL ON public.driver_documents FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.driver_documents TO service_role;
ALTER TABLE public.driver_documents ENABLE ROW LEVEL SECURITY;

CREATE INDEX driver_documents_driver_idx ON public.driver_documents(driver_id);
CREATE INDEX driver_documents_vehicle_idx ON public.driver_documents(vehicle_id);
CREATE UNIQUE INDEX driver_documents_current_driver_uniq ON public.driver_documents(driver_id, doc_type) WHERE is_current AND vehicle_id IS NULL;
CREATE UNIQUE INDEX driver_documents_current_vehicle_uniq ON public.driver_documents(vehicle_id, doc_type) WHERE is_current AND vehicle_id IS NOT NULL;

CREATE TRIGGER driver_documents_touch_updated_at BEFORE UPDATE ON public.driver_documents
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 6. driver_document_checks (append-only, aucun effet sur les statuts)
CREATE TABLE public.driver_document_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL REFERENCES public.driver_documents(id) ON DELETE RESTRICT,
  method text NOT NULL CHECK (method IN ('ai','human')),
  reviewer_id uuid NULL,
  ai_model text NULL,
  result text NOT NULL CHECK (result IN ('pass','fail','needs_review')),
  confidence numeric(4,3) NULL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  extracted_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  anomalies jsonb NOT NULL DEFAULT '[]'::jsonb,
  decision text NULL CHECK (decision IS NULL OR decision IN ('approve','reject','request_resubmission','manual_review_required')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT driver_document_checks_actor_decision_check CHECK (
    (method = 'human' AND reviewer_id IS NOT NULL AND (decision IS NULL OR decision IN ('approve','reject','request_resubmission')))
    OR (method = 'ai' AND reviewer_id IS NULL AND (decision IS NULL OR decision IN ('approve','manual_review_required')))
  )
);

REVOKE ALL ON public.driver_document_checks FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.driver_document_checks TO service_role;
ALTER TABLE public.driver_document_checks ENABLE ROW LEVEL SECURITY;

CREATE INDEX driver_document_checks_document_idx ON public.driver_document_checks(document_id);

CREATE TRIGGER driver_document_checks_append_only BEFORE UPDATE OR DELETE ON public.driver_document_checks
  FOR EACH ROW EXECUTE FUNCTION public.forbid_mutation();

-- 7. Droits d'exécution des nouvelles fonctions trigger
REVOKE ALL ON FUNCTION public.vehicles_forbid_owner_change() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.drivers_check_active_vehicle() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.drivers_purge_demo_vehicles() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vehicles_forbid_owner_change() TO service_role;
GRANT EXECUTE ON FUNCTION public.drivers_check_active_vehicle() TO service_role;
GRANT EXECUTE ON FUNCTION public.drivers_purge_demo_vehicles() TO service_role;