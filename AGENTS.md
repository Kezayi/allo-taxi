<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

- Keep Client, Chauffeur, and Administration as distinct top-level routes so each product space remains isolated and independently extensible.
- Store account profiles separately from role assignments; this prevents profile edits from becoming privilege escalation paths.
- Express rides are created only via the create_ride_public RPC (server-side id/token/status, 5/h per phone) and followed via get_ride_status(id, token) polling; anon has no direct table access so no ride data is readable without its token.
- Driver actions (activation, pool, take, close) go through SECURITY DEFINER RPCs that check has_role + approved driver; localStorage only caches UI state for offline resilience.
- Administration derives its view from server-validated user_roles; finances come from financial_dashboard_split/financial_today_split and the audit from export_full_ride_logs (ride_logs is immutable by trigger).
- Ride lifecycle is pending → negotiating → onboard (Embarqué) → completed (drop_off_ride logs to ride_logs); shared rides attach to the driver's anchor ride via anchor_ride_id and are gated server-side in get_localized_pool_for_driver/take_ride by ride_same_direction, so the lock can't be bypassed from the client.
- V1 vehicles live in their own table (one active per driver, capacity = registered_seats − 1 from the registration card, never invented); driver_documents/driver_document_checks are service_role-only until Lot 2 RPCs, and checks are append-only so AI can never overwrite a human decision.
- driver_presence is a one-way projection of drivers (is_online/last_lat/last_lng/last_seen_at) via SECURITY DEFINER trigger; availability stores only online/offline/paused — busy/shared states are computed from rides, never stored.
- Money and access are separate truths: payment_transactions (status=success only) is the sole revenue source; driver_day_passes (one per driver per Libreville calendar day) is access only, fed one-way from legacy subscriptions as FREE passes, so legacy 1 000 FCFA never becomes V1 revenue.
- client_identities is a phone-keyed identity (no auth, no normalization) auto-attached to non-demo rides by a BEFORE INSERT SECURITY DEFINER upsert; restrictions live only in append-only client_restrictions, and ride access still requires the per-ride token.
