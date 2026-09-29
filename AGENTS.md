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
- Keep the express ride journey client-local until a later real-time dispatch milestone; this preserves the requested simulation boundary without fake persistence.
