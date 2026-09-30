# Database rules (V1 migration, legacy stays master)
- V1 tables are fed one-way from legacy by SECURITY DEFINER triggers, service_role-only, no RLS policies until their RPC lot.
- vehicles: one active per driver; capacity = registered_seats − 1 from the registration card, never invented.
- driver_documents/driver_document_checks: checks append-only so AI never overwrites a human decision.
- driver_presence mirrors drivers; availability = online/offline/paused only; busy/shared computed from rides.
- Money ≠ access: revenue only from payment_transactions status=success; driver_day_passes (one per driver per Libreville day) is access only; legacy subscriptions become FREE passes, never revenue.
- client_identities: phone-keyed, no auth, no normalization, attached on ride INSERT; restrictions only in append-only client_restrictions; ride access still needs the per-ride token.
- ride_assignments: history of drivers per ride, mirrored from rides.chauffeur_id/status (legacy master); one active per ride, none per driver (sharing), transitions guarded, never deleted, demo never mirrored so reset_demo_data stays unblocked.
