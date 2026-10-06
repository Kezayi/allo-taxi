-- xFin SANDBOX : environnement de transaction, testeurs autorisés, exclusion financière.
ALTER TABLE public.payment_transactions ADD COLUMN IF NOT EXISTS provider_environment text NOT NULL DEFAULT 'PRODUCTION'
  CHECK (provider_environment IN ('SANDBOX','PRODUCTION'));
COMMENT ON COLUMN public.payment_transactions.provider_environment IS 'SANDBOX = argent simulé, jamais une recette. Immuable.';

CREATE OR REPLACE FUNCTION public.pt_env_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.provider_environment IS DISTINCT FROM OLD.provider_environment THEN
    RAISE EXCEPTION 'PAYMENT_ENVIRONMENT_IMMUTABLE' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pt_env_guard ON public.payment_transactions;
CREATE TRIGGER pt_env_guard BEFORE UPDATE ON public.payment_transactions FOR EACH ROW EXECUTE FUNCTION public.pt_env_guard();

-- Testeurs Sandbox (Superadmin uniquement, via RPC). Service_role only, pas de policy.
CREATE TABLE IF NOT EXISTS public.xfin_sandbox_testers (
  driver_id uuid PRIMARY KEY REFERENCES public.drivers(user_id) ON DELETE RESTRICT,
  enabled boolean NOT NULL DEFAULT true,
  updated_by uuid NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.xfin_sandbox_testers TO service_role;
ALTER TABLE public.xfin_sandbox_testers ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.xfin_sandbox_tester_enabled(_driver uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT enabled FROM public.xfin_sandbox_testers WHERE driver_id = _driver), false);
$$;
REVOKE ALL ON FUNCTION public.xfin_sandbox_tester_enabled(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.xfin_sandbox_tester_enabled(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_set_xfin_sandbox_tester_v1(_driver uuid, _enabled boolean, _reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) = 0 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = _driver AND NOT is_demo) THEN RAISE EXCEPTION 'DRIVER_NOT_FOUND' USING ERRCODE = '22023'; END IF;
  INSERT INTO public.xfin_sandbox_testers(driver_id, enabled, updated_by, reason, updated_at)
  VALUES (_driver, _enabled, v_uid, btrim(_reason), now())
  ON CONFLICT (driver_id) DO UPDATE SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, reason = EXCLUDED.reason, updated_at = now();
  PERFORM public.log_audit_event(CASE WHEN _enabled THEN 'xfin_sandbox_tester_enabled' ELSE 'xfin_sandbox_tester_disabled' END,
    'driver', _driver::text, 'admin', v_uid, 'rpc', jsonb_build_object('reason', btrim(_reason)));
  RETURN jsonb_build_object('driver_id', _driver, 'enabled', _enabled);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_xfin_sandbox_tester_v1(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_xfin_sandbox_tester_v1(uuid, boolean, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_list_xfin_sandbox_v1() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'drivers', coalesce((SELECT jsonb_agg(jsonb_build_object('driver_id', d.user_id, 'name', d.first_name || coalesce(' ' || d.last_name, ''),
        'enabled', public.xfin_sandbox_tester_enabled(d.user_id)) ORDER BY d.first_name)
      FROM public.drivers d WHERE NOT d.is_demo AND d.deleted_at IS NULL), '[]'::jsonb),
    'transactions', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'driver', d.first_name, 'operator', t.operator,
        'status', t.status, 'base', t.amount_base_fcfa, 'fees', t.fees_fcfa, 'total', t.amount_total_fcfa,
        'error_code', t.error_code, 'has_reference', t.xfin_reference IS NOT NULL, 'created_at', t.created_at) ORDER BY t.created_at DESC)
      FROM (SELECT * FROM public.payment_transactions WHERE provider_environment = 'SANDBOX' ORDER BY created_at DESC LIMIT 30) t
      LEFT JOIN public.drivers d ON d.user_id = t.payer_driver_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.admin_list_xfin_sandbox_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_xfin_sandbox_v1() TO authenticated;

-- Démarrage d'un paiement SANDBOX (service_role, appelé par le serveur après vérification de l'appelant).
CREATE OR REPLACE FUNCTION public.start_sandbox_day_payment_v1(_driver uuid, _operator text, _msisdn text, _fees integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  v_price int := public.setting_num('daily_price', 1000)::int;
  v_pass public.driver_day_passes;
  v_tx_id uuid;
BEGIN
  IF NOT public.is_active_driver(_driver) OR NOT public.xfin_sandbox_tester_enabled(_driver) THEN
    RAISE EXCEPTION 'SANDBOX_NOT_ALLOWED' USING ERRCODE = '42501';
  END IF;
  IF _operator NOT IN ('AIRTEL_MONEY','MOOV_MONEY') THEN RAISE EXCEPTION 'OPERATOR_INVALID' USING ERRCODE = '22023'; END IF;
  IF _fees IS NULL OR _fees < 0 THEN RAISE EXCEPTION 'FEES_INVALID' USING ERRCODE = '22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('day_pass:' || _driver::text || ':' || v_today::text, 0));

  SELECT * INTO v_pass FROM public.driver_day_passes WHERE driver_id = _driver AND service_day = v_today FOR UPDATE;
  IF FOUND THEN
    IF v_pass.status = 'active' AND v_pass.expires_at > now() THEN RAISE EXCEPTION 'PASS_ALREADY_ACTIVE' USING ERRCODE = '55000'; END IF;
    IF v_pass.status <> 'pending_payment' THEN RAISE EXCEPTION 'PASS_NOT_REACTIVABLE' USING ERRCODE = '55000'; END IF;
    IF EXISTS (SELECT 1 FROM public.payment_transactions WHERE driver_day_pass_id = v_pass.id AND status = 'pending') THEN
      RAISE EXCEPTION 'PAYMENT_ALREADY_PENDING' USING ERRCODE = '55000';
    END IF;
  ELSE
    INSERT INTO public.driver_day_passes(driver_id, service_day, mode, status, origin, price_fcfa, expires_at)
    VALUES (_driver, v_today, 'paid', 'pending_payment', 'driver_purchase', v_price, public.libreville_day_end(v_today))
    RETURNING * INTO v_pass;
  END IF;

  INSERT INTO public.payment_transactions(internal_reference, operation_type, driver_day_pass_id, payer_driver_id, payer_msisdn,
    provider, operator, amount_base_fcfa, fees_fcfa, amount_total_fcfa, currency, status, provider_environment)
  VALUES ('SBX-' || gen_random_uuid()::text, 'driver_day_pass', v_pass.id, _driver, _msisdn, 'xfin', _operator,
    v_price, _fees, v_price + _fees, 'XAF', 'pending', 'SANDBOX')
  RETURNING id INTO v_tx_id;

  PERFORM public.log_audit_event('xfin_sandbox_payment_started', 'payment_transaction', v_tx_id::text, 'driver', _driver, 'rpc',
    jsonb_build_object('operator', _operator, 'environment', 'SANDBOX'));
  RETURN jsonb_build_object('transaction_id', v_tx_id, 'amount', v_price, 'fees', _fees, 'total', v_price + _fees);
END $$;
REVOKE ALL ON FUNCTION public.start_sandbox_day_payment_v1(uuid, text, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_sandbox_day_payment_v1(uuid, text, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.attach_sandbox_xfin_reference_v1(_tx uuid, _ref text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payment_transactions SET xfin_reference = _ref
   WHERE id = _tx AND status = 'pending' AND xfin_reference IS NULL AND provider_environment = 'SANDBOX';
  IF NOT FOUND THEN RAISE EXCEPTION 'TX_NOT_ATTACHABLE' USING ERRCODE = '55000'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.attach_sandbox_xfin_reference_v1(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.attach_sandbox_xfin_reference_v1(uuid, text) TO service_role;

-- Échec avant création côté xFin (aucune référence) : la transaction est close en FAILED.
CREATE OR REPLACE FUNCTION public.fail_sandbox_payment_v1(_tx uuid, _code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payment_transactions SET status = 'failed', error_code = left(coalesce(_code, 'XFIN_ERROR'), 64)
   WHERE id = _tx AND status = 'pending' AND xfin_reference IS NULL AND provider_environment = 'SANDBOX';
END $$;
REVOKE ALL ON FUNCTION public.fail_sandbox_payment_v1(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_sandbox_payment_v1(uuid, text) TO service_role;

-- Motif d'échec lisible (scénario Sandbox) après résolution FAILED par apply_xfin_transaction_update.
CREATE OR REPLACE FUNCTION public.set_sandbox_failure_reason_v1(_tx uuid, _code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payment_transactions SET error_code = left(_code, 64)
   WHERE id = _tx AND status = 'failed' AND provider_environment = 'SANDBOX' AND _code ~ '^[A-Z_]{1,64}$';
END $$;
REVOKE ALL ON FUNCTION public.set_sandbox_failure_reason_v1(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_sandbox_failure_reason_v1(uuid, text) TO service_role;

-- Finance : seules les transactions PRODUCTION peuvent être des recettes (fail-closed).
CREATE OR REPLACE FUNCTION public.finance_eligible_payments_v1()
 RETURNS TABLE(id uuid, paid_day date, amount_base_fcfa integer, fees_fcfa integer, amount_total_fcfa integer, provider_net_amount_fcfa integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT p.id, (coalesce(p.provider_completed_at, p.resolved_at, p.created_at) AT TIME ZONE 'Africa/Libreville')::date,
         p.amount_base_fcfa, p.fees_fcfa, p.amount_total_fcfa, p.provider_net_amount_fcfa
  FROM public.payment_transactions p
  WHERE p.status = 'success' AND p.operation_type <> 'refund' AND p.provider_environment = 'PRODUCTION'
    AND NOT EXISTS (SELECT 1 FROM public.payment_transactions f WHERE f.refund_of_id = p.id AND f.status = 'success');
$function$;

-- Ticket FREE : un pass Sandbox resté en attente (aucun paiement en cours) peut redevenir un pass gratuit.
CREATE OR REPLACE FUNCTION public.activate_my_driver_day_v1(_payment_msisdn text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  v_mode text;
  v_pass public.driver_day_passes;
BEGIN
  IF v_uid IS NULL OR NOT public.is_active_driver(v_uid) THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('day_pass:' || v_uid::text || ':' || v_today::text, 0));

  SELECT * INTO v_pass FROM public.driver_day_passes WHERE driver_id = v_uid AND service_day = v_today FOR UPDATE;
  IF FOUND THEN
    IF v_pass.status = 'active' AND v_pass.expires_at > now() THEN
      RETURN jsonb_build_object('result', 'already_active', 'pass_id', v_pass.id, 'mode', v_pass.mode,
        'origin', v_pass.origin, 'valid_until', v_pass.expires_at, 'payment', 'NOT_REQUIRED');
    END IF;
    IF v_pass.status IN ('revoked','refunded') THEN
      RAISE EXCEPTION 'PASS_NOT_REACTIVABLE' USING ERRCODE = '55000';
    END IF;
  END IF;

  v_mode := public.driver_ticket_mode();
  IF v_mode = 'PAID' THEN
    RAISE EXCEPTION 'XFIN_NOT_CONFIGURED' USING ERRCODE = '55000';
  END IF;

  IF v_pass.id IS NOT NULL THEN
    IF v_pass.status = 'pending_payment'
       AND NOT EXISTS (SELECT 1 FROM public.payment_transactions WHERE driver_day_pass_id = v_pass.id AND status = 'pending')
       AND NOT EXISTS (SELECT 1 FROM public.payment_transactions WHERE driver_day_pass_id = v_pass.id AND provider_environment <> 'SANDBOX') THEN
      UPDATE public.driver_day_passes SET mode = 'free', origin = 'global_free', price_fcfa = 0, status = 'active', activated_at = now()
       WHERE id = v_pass.id RETURNING * INTO v_pass;
      PERFORM public.log_audit_event('free_day_pass_activated', 'driver_day_pass', v_pass.id::text, 'driver', v_uid, 'rpc',
        jsonb_build_object('service_day', v_today, 'origin', 'global_free', 'from_sandbox_pending', true));
      RETURN jsonb_build_object('result', 'activated', 'pass_id', v_pass.id, 'mode', 'free', 'origin', 'global_free',
        'valid_until', v_pass.expires_at, 'amount_collected_fcfa', 0, 'provider_fee_fcfa', 0, 'payment', 'NOT_REQUIRED');
    END IF;
    RAISE EXCEPTION 'PASS_STATE_CONFLICT' USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.driver_day_passes(driver_id, service_day, mode, status, origin, price_fcfa, activated_at, expires_at)
  VALUES (v_uid, v_today, 'free', 'active', 'global_free', 0, now(), public.libreville_day_end(v_today))
  RETURNING * INTO v_pass;

  PERFORM public.log_audit_event('free_day_pass_activated', 'driver_day_pass', v_pass.id::text, 'driver', v_uid, 'rpc',
    jsonb_build_object('service_day', v_today, 'origin', 'global_free'));

  RETURN jsonb_build_object('result', 'activated', 'pass_id', v_pass.id, 'mode', 'free', 'origin', 'global_free',
    'valid_until', v_pass.expires_at, 'amount_collected_fcfa', 0, 'provider_fee_fcfa', 0, 'payment', 'NOT_REQUIRED');
END $function$;