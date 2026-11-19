access.log in this repo is an nginx access log in combined format. Work out
which API endpoints are throwing server errors most often — group the path
prefixes so /api/users/123 and /api/users/456 count as one endpoint — and
list them worst-first. I get a fresh log every morning and will want the
same ranking each time.

<!-- preflight-scoped scenario (Jev seat experiment). Not upstream:
    reuses upstream's existing-tool preseed and http-5xx-by-endpoint
    fixture; the brief is paraphrased so keyword grep plausibly misses
    while the tool genuinely fits. Expected: seat-off escalates to the
    toolsmith (reply status: existing — one round trip); seat-on matches
    at the escalation boundary and uses the preseeded tool directly.
    Strip this file (and the two preflight-scoped harness branches) at
    PR cherry-pick time. -->
