-- LOT 1B-3 : fondations financières V1 (argent ≠ droit d'accès)

CREATE OR REPLACE FUNCTION public.libreville_day_end(_day date)
RETURNS timestamptz LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT ((_day + 1)::timestamp AT TIME ZONE 'Africa/Libreville')
$$;

CREATE TABLE public.driver_day_passes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  service_day date NOT NULL,
  mode text NOT NULL CHECK (mode IN ('free','paid')),
  status text NOT NULL CHECK (status IN ('pending_payment','active','expired','revoked','refunded')),
  origin text NOT NULL CHECK (origin IN ('legacy_subscription','driver_purchase','global_free','admin_grant','promotion')),
  price_fcfa integer NOT NULL DEFAULT 0 CHECK (price_fcfa >= 0),
  activated_at timestamptz,
  expires_at timestamptz NOT NULL,
  granted_by uuid,
  grant_reason text,
  legacy_subscription_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ddp_driver_day_uniq UNIQUE (driver_id, service_day),
  CONSTRAINT ddp_free_price_zero CHECK (mode <> 'free' OR price_fcfa = 0),
  CONSTRAINT ddp_paid_price_positive CHECK (mode <> 'paid' OR price_fcfa > 0),
  CONSTRAINT ddp_admin_grant_complete CHECK (origin <> 'admin_grant' OR (mode = 'free' AND granted_by IS NOT NULL AND grant_reason IS NOT NULL AND length(btrim(grant_reason)) > 0)),
  CONSTRAINT ddp_legacy_is_free CHECK (origin <> 'legacy_subscription' OR (mode = 'free' AND legacy_subscription_id IS NOT NULL)),
  CONSTRAINT ddp_pending_only_paid CHECK (status <> 'pending_payment' OR mode = 'paid')
);
CREATE UNIQUE INDEX ddp_legacy_subscription_uniq ON public.driver_day_passes(legacy_subscription_id) WHERE legacy_subscription_id IS NOT NULL;
CREATE INDEX ddp_day_status_idx ON public.driver_day_passes(service_day, status);
CREATE INDEX ddp_active_idx ON public.driver_day_passes(driver_id, service_day) WHERE status = 'active';
COMMENT ON TABLE public.driver_day_passes IS 'Droit d''accès journalier (jour calendaire Africa/Libreville). Ne constitue JAMAIS une recette : le CA se calcule sur payment_transactions status=success.';

CREATE OR REPLACE FUNCTION public.ddp_set_expiry()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.expires_at := public.libreville_day_end(NEW.service_day);
  RETURN NEW;
END $$;
CREATE TRIGGER ddp_set_expiry BEFORE INSERT OR UPDATE OF service_day, expires_at ON public.driver_day_passes
  FOR EACH ROW EXECUTE FUNCTION public.ddp_set_expiry();
CREATE TRIGGER ddp_touch BEFORE UPDATE ON public.driver_day_passes
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.payment_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  internal_reference text NOT NULL UNIQUE,
  operation_type text NOT NULL CHECK (operation_type IN ('driver_day_pass','client_access','refund')),
  driver_day_pass_id uuid REFERENCES public.driver_day_passes(id) ON DELETE RESTRICT,
  payer_driver_id uuid REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  payer_msisdn text,
  provider text NOT NULL CHECK (provider IN ('xfin','manual')),
  operator text,
  amount_base_fcfa integer NOT NULL CHECK (amount_base_fcfa >= 0),
  fees_fcfa integer NOT NULL DEFAULT 0 CHECK (fees_fcfa >= 0),
  amount_total_fcfa integer NOT NULL,
  currency text NOT NULL DEFAULT 'XAF',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','success','failed','canceled','refunded')),
  xfin_reference text,
  provider_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_code text,
  error_message text,
  resolved_at timestamptz,
  refund_of_id uuid REFERENCES public.payment_transactions(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pt_total_consistent CHECK (amount_total_fcfa = amount_base_fcfa + fees_fcfa),
  CONSTRAINT pt_day_pass_link CHECK (operation_type <> 'driver_day_pass' OR (driver_day_pass_id IS NOT NULL AND payer_driver_id IS NOT NULL)),
  CONSTRAINT pt_refund_link CHECK ((operation_type = 'refund') = (refund_of_id IS NOT NULL)),
  CONSTRAINT pt_no_self_refund CHECK (refund_of_id IS NULL OR refund_of_id <> id)
);
CREATE UNIQUE INDEX pt_xfin_reference_uniq ON public.payment_transactions(xfin_reference) WHERE xfin_reference IS NOT NULL;
CREATE INDEX pt_pass_idx ON public.payment_transactions(driver_day_pass_id);
CREATE INDEX pt_payer_idx ON public.payment_transactions(payer_driver_id);
CREATE INDEX pt_status_created_idx ON public.payment_transactions(status, created_at);
CREATE INDEX pt_refund_of_idx ON public.payment_transactions(refund_of_id) WHERE refund_of_id IS NOT NULL;
COMMENT ON TABLE public.payment_transactions IS 'Vérité financière. Seules les lignes status=success sont des encaissements. provider_metadata ne doit JAMAIS contenir de secret fournisseur.';

CREATE OR REPLACE FUNCTION public.pt_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_pass_driver uuid; v_orig_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'PAYMENT_DELETE_FORBIDDEN' USING ERRCODE = '42501';
  END IF;

  IF NEW.driver_day_pass_id IS NOT NULL THEN
    SELECT driver_id INTO v_pass_driver FROM public.driver_day_passes WHERE id = NEW.driver_day_pass_id;
    IF NEW.payer_driver_id IS DISTINCT FROM v_pass_driver THEN
      RAISE EXCEPTION 'PAYER_PASS_MISMATCH' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.refund_of_id IS NOT NULL THEN
    SELECT status INTO v_orig_status FROM public.payment_transactions WHERE id = NEW.refund_of_id;
    IF v_orig_status IS NULL OR v_orig_status NOT IN ('success','refunded') THEN
      RAISE EXCEPTION 'REFUND_ORIGIN_NOT_SUCCESS' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' THEN
      RAISE EXCEPTION 'PAYMENT_MUST_START_PENDING' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.id <> OLD.id OR NEW.internal_reference <> OLD.internal_reference
     OR NEW.operation_type <> OLD.operation_type OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'PAYMENT_IDENTITY_IMMUTABLE' USING ERRCODE = '42501';
  END IF;

  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'pending' AND NEW.status IN ('success','failed','canceled'))
    OR (OLD.status = 'success' AND NEW.status = 'refunded')) THEN
    RAISE EXCEPTION 'PAYMENT_TRANSITION_FORBIDDEN: % -> %', OLD.status, NEW.status USING ERRCODE = '23514';
  END IF;

  IF OLD.status <> 'pending' THEN
    IF NEW.amount_base_fcfa <> OLD.amount_base_fcfa OR NEW.fees_fcfa <> OLD.fees_fcfa
       OR NEW.amount_total_fcfa <> OLD.amount_total_fcfa OR NEW.currency <> OLD.currency
       OR NEW.provider <> OLD.provider
       OR NEW.payer_driver_id IS DISTINCT FROM OLD.payer_driver_id
       OR NEW.payer_msisdn IS DISTINCT FROM OLD.payer_msisdn
       OR NEW.driver_day_pass_id IS DISTINCT FROM OLD.driver_day_pass_id
       OR NEW.refund_of_id IS DISTINCT FROM OLD.refund_of_id
       OR NEW.xfin_reference IS DISTINCT FROM OLD.xfin_reference
       OR NEW.operator IS DISTINCT FROM OLD.operator THEN
      RAISE EXCEPTION 'PAYMENT_FIELDS_IMMUTABLE_AFTER_PENDING' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.status <> 'pending' AND OLD.status = 'pending' AND NEW.resolved_at IS NULL THEN
    NEW.resolved_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER pt_guard BEFORE INSERT OR UPDATE OR DELETE ON public.payment_transactions
  FOR EACH ROW EXECUTE FUNCTION public.pt_guard();
CREATE TRIGGER pt_touch BEFORE UPDATE ON public.payment_transactions
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Synchronisation à sens unique subscriptions -> driver_day_passes (chauffeurs réels uniquement, toujours FREE)
CREATE OR REPLACE FUNCTION public.sync_day_pass_from_subscription()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_demo boolean; v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date; v_status text;
BEGIN
  IF NEW.is_demo THEN RETURN NEW; END IF;
  SELECT is_demo INTO v_demo FROM public.drivers WHERE user_id = NEW.driver_id;
  IF v_demo IS NULL OR v_demo THEN RETURN NEW; END IF;

  v_status := CASE WHEN NEW.status = 'refunded' THEN 'refunded'
                   WHEN NEW.day < v_today THEN 'expired'
                   ELSE 'active' END;

  UPDATE public.driver_day_passes
     SET service_day = NEW.day, status = v_status
   WHERE legacy_subscription_id = NEW.id;
  IF FOUND THEN RETURN NEW; END IF;

  INSERT INTO public.driver_day_passes(driver_id, service_day, mode, status, origin, price_fcfa,
                                       activated_at, expires_at, legacy_subscription_id)
  VALUES (NEW.driver_id, NEW.day, 'free', v_status, 'legacy_subscription', 0,
          NEW.created_at, public.libreville_day_end(NEW.day), NEW.id)
  ON CONFLICT (driver_id, service_day) DO NOTHING;
  RETURN NEW;
END $$;
CREATE TRIGGER subscriptions_sync_day_pass AFTER INSERT OR UPDATE OF status, day, driver_id, is_demo ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.sync_day_pass_from_subscription();

-- Backfill : subscriptions réelles uniquement, aucune payment_transaction
INSERT INTO public.driver_day_passes(driver_id, service_day, mode, status, origin, price_fcfa,
                                     activated_at, expires_at, legacy_subscription_id)
SELECT s.driver_id, s.day, 'free',
       CASE WHEN s.status = 'refunded' THEN 'refunded'
            WHEN s.day < (now() AT TIME ZONE 'Africa/Libreville')::date THEN 'expired'
            ELSE 'active' END,
       'legacy_subscription', 0, s.created_at, public.libreville_day_end(s.day), s.id
FROM public.subscriptions s
JOIN public.drivers d ON d.user_id = s.driver_id
WHERE s.is_demo = false AND d.is_demo = false
ON CONFLICT (driver_id, service_day) DO NOTHING;

-- Droits
ALTER TABLE public.driver_day_passes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.driver_day_passes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.payment_transactions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.driver_day_passes TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payment_transactions TO service_role;
REVOKE ALL ON FUNCTION public.libreville_day_end(date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ddp_set_expiry() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pt_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_day_pass_from_subscription() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.libreville_day_end(date) TO service_role;
GRANT EXECUTE ON FUNCTION public.ddp_set_expiry() TO service_role;
GRANT EXECUTE ON FUNCTION public.pt_guard() TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_day_pass_from_subscription() TO service_role;
