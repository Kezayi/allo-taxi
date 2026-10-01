-- LOT 3A : ticket journalier V1 (backend à côté du legacy, aucune bascule écran)

-- 1. Intégration xFin réelle : AUCUNE à ce jour (aucune documentation, aucun secret).
--    Ce verrou ne devient true que par une migration livrant une intégration réelle testée.
CREATE OR REPLACE FUNCTION public.xfin_integration_ready()
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT false $$;

-- 2. Mode global non secret FREE/PAID (défaut FREE si aucune configuration)
CREATE OR REPLACE FUNCTION public.driver_ticket_mode()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE((SELECT value #>> '{}' FROM public.system_settings WHERE key = 'driver_ticket_mode'), 'FREE')
$$;

-- 3. Le mode ne peut être modifié que via set_driver_ticket_mode (audit + raison)
CREATE OR REPLACE FUNCTION public.system_settings_ticket_mode_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF (TG_OP = 'DELETE' AND OLD.key = 'driver_ticket_mode')
     OR (TG_OP <> 'DELETE' AND (NEW.key = 'driver_ticket_mode' OR (TG_OP = 'UPDATE' AND OLD.key = 'driver_ticket_mode'))) THEN
    IF COALESCE(current_setting('app.ticket_mode_rpc', true), '') <> '1' THEN
      RAISE EXCEPTION 'TICKET_MODE_RPC_ONLY' USING ERRCODE = '42501';
    END IF;
    IF TG_OP <> 'DELETE' AND (NEW.value #>> '{}') NOT IN ('FREE','PAID') THEN
      RAISE EXCEPTION 'TICKET_MODE_INVALID' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER system_settings_ticket_mode_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.system_settings
FOR EACH ROW EXECUTE FUNCTION public.system_settings_ticket_mode_guard();

-- 4. Changement de mode (Superadmin, raison obligatoire, PAID refusé sans xFin réel)
CREATE OR REPLACE FUNCTION public.set_driver_ticket_mode(_mode text, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_old text;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF _mode IS NULL OR _mode NOT IN ('FREE','PAID') THEN
    RAISE EXCEPTION 'TICKET_MODE_INVALID' USING ERRCODE = '22023';
  END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF _mode = 'PAID' AND NOT public.xfin_integration_ready() THEN
    RAISE EXCEPTION 'XFIN_NOT_CONFIGURED' USING ERRCODE = '55000';
  END IF;
  v_old := public.driver_ticket_mode();
  IF v_old = _mode THEN
    RETURN jsonb_build_object('mode', _mode, 'changed', false);
  END IF;
  PERFORM set_config('app.ticket_mode_rpc', '1', true);
  INSERT INTO public.system_settings(key, value) VALUES ('driver_ticket_mode', to_jsonb(_mode))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM set_config('app.ticket_mode_rpc', '', true);
  PERFORM public.log_audit_event('ticket_mode_changed', 'system_setting', 'driver_ticket_mode', 'admin', auth.uid(), 'rpc',
    jsonb_build_object('from', v_old, 'to', _mode, 'reason', btrim(_reason)));
  RETURN jsonb_build_object('mode', _mode, 'changed', true);
END $$;

-- 5. État journalier du chauffeur connecté
CREATE OR REPLACE FUNCTION public.get_my_driver_day_access()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  v_mode text := public.driver_ticket_mode();
  v_pass public.driver_day_passes;
  v_valid boolean := false;
  v_tx jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.is_active_driver(v_uid) THEN
    RAISE EXCEPTION 'FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_pass FROM public.driver_day_passes WHERE driver_id = v_uid AND service_day = v_today;
  IF FOUND THEN
    v_valid := v_pass.status = 'active' AND v_pass.service_day = v_today AND v_pass.expires_at > now();
    SELECT jsonb_build_object('id', t.id, 'status', t.status, 'amount_base_fcfa', t.amount_base_fcfa,
             'fees_fcfa', t.fees_fcfa, 'amount_total_fcfa', t.amount_total_fcfa, 'created_at', t.created_at)
      INTO v_tx
      FROM public.payment_transactions t
     WHERE t.driver_day_pass_id = v_pass.id AND t.status = 'pending'
     ORDER BY t.created_at DESC LIMIT 1;
  END IF;
  RETURN jsonb_build_object(
    'service_day', v_today,
    'ticket_mode', v_mode,
    'ticket_price_fcfa', public.setting_num('daily_price', 1000)::int,
    'pass', CASE WHEN v_pass.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_pass.id, 'mode', v_pass.mode, 'origin', v_pass.origin, 'status', v_pass.status,
      'activated_at', v_pass.activated_at, 'valid_until', v_pass.expires_at) END,
    'access_valid', v_valid,
    'payment_required', (NOT v_valid) AND v_mode = 'PAID',
    'pending_transaction', v_tx,
    'xfin_configured', public.xfin_integration_ready(),
    'can_activate', (NOT v_valid) AND (v_pass.id IS NULL OR v_pass.status = 'pending_payment')
                    AND (v_mode = 'FREE' OR public.xfin_integration_ready())
  );
END $$;

-- 6. Activation V1 (idempotente ; driver = auth.uid())
CREATE OR REPLACE FUNCTION public.activate_my_driver_day_v1(_payment_msisdn text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
    -- Fail closed : aucune intégration xFin réelle → aucun pass, aucune transaction.
    IF NOT public.xfin_integration_ready() THEN
      RAISE EXCEPTION 'XFIN_NOT_CONFIGURED' USING ERRCODE = '55000';
    END IF;
    RAISE EXCEPTION 'XFIN_NOT_CONFIGURED' USING ERRCODE = '55000';
  END IF;

  IF v_pass.id IS NOT NULL THEN
    -- pending_payment d'un ancien mode PAID : ne pas convertir silencieusement
    RAISE EXCEPTION 'PASS_STATE_CONFLICT' USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.driver_day_passes(driver_id, service_day, mode, status, origin, price_fcfa, activated_at, expires_at)
  VALUES (v_uid, v_today, 'free', 'active', 'global_free', 0, now(), public.libreville_day_end(v_today))
  RETURNING * INTO v_pass;

  PERFORM public.log_audit_event('free_day_pass_activated', 'driver_day_pass', v_pass.id::text, 'driver', v_uid, 'rpc',
    jsonb_build_object('service_day', v_today, 'origin', 'global_free'));

  RETURN jsonb_build_object('result', 'activated', 'pass_id', v_pass.id, 'mode', 'free', 'origin', 'global_free',
    'valid_until', v_pass.expires_at, 'amount_collected_fcfa', 0, 'provider_fee_fcfa', 0, 'payment', 'NOT_REQUIRED');
END $$;

REVOKE ALL ON FUNCTION public.xfin_integration_ready() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.driver_ticket_mode() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.system_settings_ticket_mode_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_driver_ticket_mode(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_driver_day_access() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.activate_my_driver_day_v1(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_driver_ticket_mode(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_driver_day_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.activate_my_driver_day_v1(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.xfin_integration_ready() TO service_role;
GRANT EXECUTE ON FUNCTION public.driver_ticket_mode() TO service_role;