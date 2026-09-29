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
- Express rides are inserted anonymously into rides (insert-only RLS) and clients follow them via the PII-free ride_public_status table over Realtime; phones never become anon-readable.
- Driver actions (activation, pool, take, close) go through SECURITY DEFINER RPCs that check has_role + approved driver; localStorage only caches UI state for offline resilience.
- Administration derives its view from server-validated user_roles; finances come from financial_dashboard_split/financial_today_split and the audit from export_full_ride_logs (ride_logs is immutable by trigger).
