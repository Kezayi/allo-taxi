CREATE OR REPLACE FUNCTION public.admin_list_driver_ai_checks(_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.has_role(v_uid, 'super_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN jsonb_build_object(
    'eligibility', public.compute_driver_operational_eligibility(_driver_id) || jsonb_build_object('mode', public.onboarding_enforcement_mode()),
    'checks', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('document_id', c.document_id, 'ai_model', c.ai_model, 'result', c.result,
               'confidence', c.confidence, 'decision', c.decision, 'extracted_data', c.extracted_data,
               'anomalies', c.anomalies, 'created_at', c.created_at) ORDER BY c.created_at DESC)
        FROM public.driver_document_checks c JOIN public.driver_documents d ON d.id = c.document_id
       WHERE d.driver_id = _driver_id AND c.method = 'ai'), '[]'::jsonb),
    'runs', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('document_id', r.document_id, 'status', r.status, 'attempts', r.attempts, 'error_code', r.error_code))
        FROM public.driver_document_ai_runs r JOIN public.driver_documents d ON d.id = r.document_id
       WHERE d.driver_id = _driver_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.admin_list_driver_ai_checks(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_driver_ai_checks(uuid) TO authenticated, service_role;