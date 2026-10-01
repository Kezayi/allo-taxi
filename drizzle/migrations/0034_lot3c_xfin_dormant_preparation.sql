-- LOT 3C : préparation xFin dormante (aucun paiement, PAID reste verrouillé)
ALTER TABLE public.payment_transactions ADD COLUMN IF NOT EXISTS provider_net_amount_fcfa integer CHECK (provider_net_amount_fcfa IS NULL OR provider_net_amount_fcfa >= 0);
ALTER TABLE public.payment_transactions ADD COLUMN IF NOT EXISTS provider_completed_at timestamptz;
COMMENT ON COLUMN public.payment_transactions.amount_base_fcfa IS 'Prix métier du ticket (1000), jamais modifié par les frais provider.';
COMMENT ON COLUMN public.payment_transactions.fees_fcfa IS 'Frais provider (GET /v1/fees puis valeur finale xFin), supportés par le chauffeur.';
COMMENT ON COLUMN public.payment_transactions.amount_total_fcfa IS 'Montant débité au chauffeur = ticket + frais.';
COMMENT ON COLUMN public.payment_transactions.provider_net_amount_fcfa IS 'netAmount renvoyé par xFin après transaction (informatif).';
COMMENT ON COLUMN public.payment_transactions.xfin_reference IS 'xfinReference canonique (GET /v1/transactions/{ref}).';

-- Résolution idempotente d'une transaction xFin (webhook signé ou polling serveur). service_role uniquement.
CREATE OR REPLACE FUNCTION public.apply_xfin_transaction_update(
  _xfin_reference text, _status text, _transaction_type text, _amount integer,
  _fees integer, _net_amount integer, _completed_at timestamptz, _source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tx public.payment_transactions;
  v_pass public.driver_day_passes;
  v_today date := (now() AT TIME ZONE 'Africa/Libreville')::date;
  v_st text := upper(coalesce(_status,''));
BEGIN
  IF _xfin_reference IS NULL OR length(btrim(_xfin_reference)) = 0 THEN
    RAISE EXCEPTION 'XFIN_REFERENCE_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF _source NOT IN ('webhook','polling') THEN RAISE EXCEPTION 'SOURCE_INVALID' USING ERRCODE = '22023'; END IF;

  SELECT * INTO v_tx FROM public.payment_transactions WHERE xfin_reference = _xfin_reference FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('result','unknown_reference'); END IF;
  IF upper(coalesce(_transaction_type,'PAYMENT')) <> 'PAYMENT' OR v_tx.operation_type <> 'driver_day_pass' THEN
    RETURN jsonb_build_object('result','type_mismatch');
  END IF;
  IF _amount IS NOT NULL AND _amount <> v_tx.amount_base_fcfa THEN
    RETURN jsonb_build_object('result','amount_mismatch');
  END IF;

  IF v_st = 'PENDING' THEN RETURN jsonb_build_object('result','still_pending'); END IF;
  IF v_st NOT IN ('SUCCESS','FAILED') THEN RETURN jsonb_build_object('result','unmapped_status'); END IF;

  -- Idempotence : déjà résolu → aucun effet métier
  IF v_tx.status <> 'pending' THEN
    RETURN jsonb_build_object('result','already_applied','status',v_tx.status);
  END IF;

  IF v_st = 'FAILED' THEN
    UPDATE public.payment_transactions SET status='failed', error_code='PROVIDER_FAILED',
      provider_completed_at=_completed_at WHERE id = v_tx.id;
    PERFORM public.log_audit_event('xfin_payment_failed','payment_transaction',v_tx.id::text,'system',NULL,'system',
      jsonb_build_object('source',_source));
    RETURN jsonb_build_object('result','failed_applied');
  END IF;

  -- SUCCESS : frais finaux renvoyés par xFin (si fournis), puis encaissement
  UPDATE public.payment_transactions
     SET fees_fcfa = coalesce(_fees, fees_fcfa),
         amount_total_fcfa = amount_base_fcfa + coalesce(_fees, fees_fcfa),
         provider_net_amount_fcfa = _net_amount,
         provider_completed_at = _completed_at,
         status = 'success'
   WHERE id = v_tx.id;

  SELECT * INTO v_pass FROM public.driver_day_passes WHERE id = v_tx.driver_day_pass_id FOR UPDATE;
  IF v_pass.service_day <> v_today OR v_pass.expires_at <= now() THEN
    -- Confirmation après minuit Libreville : règle métier NON TRANCHÉE (à décider avant PAID réel)
    UPDATE public.payment_transactions SET error_code='LATE_CONFIRMATION_RULE_PENDING' WHERE id = v_tx.id;
    PERFORM public.log_audit_event('xfin_payment_late_confirmation','payment_transaction',v_tx.id::text,'system',NULL,'system',
      jsonb_build_object('source',_source,'service_day',v_pass.service_day));
    RETURN jsonb_build_object('result','late_confirmation_pending_rule');
  END IF;
  IF v_pass.status = 'pending_payment' THEN
    UPDATE public.driver_day_passes SET status='active', activated_at=now() WHERE id = v_pass.id;
  END IF;
  PERFORM public.log_audit_event('xfin_payment_succeeded','payment_transaction',v_tx.id::text,'system',NULL,'system',
    jsonb_build_object('source',_source));
  RETURN jsonb_build_object('result','success_applied');
END $$;
REVOKE ALL ON FUNCTION public.apply_xfin_transaction_update(text,text,text,integer,integer,integer,timestamptz,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_xfin_transaction_update(text,text,text,integer,integer,integer,timestamptz,text) TO service_role;

-- Verrou inchangé : xfin_integration_ready() reste false jusqu'à une migration livrant l'intégration réelle testée.
COMMENT ON FUNCTION public.xfin_integration_ready() IS 'LOT 3C : reste false. Ne passer à true que par migration après secrets présents, /v1/me active, paymentFeeOwner=CUSTOMER, webhook configuré et recette réelle.';