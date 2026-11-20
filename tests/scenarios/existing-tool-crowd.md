access.log in this repo is an nginx access log in combined format. Work out
which API endpoints are throwing server errors most often — group the path
prefixes so /api/users/123 and /api/users/456 count as one endpoint — and
list them worst-first. I get a fresh log every morning and will want the
same ranking each time.

<!-- preflight-scoped scenario (Jev seat experiment, crowd test). Not
    upstream: preseeds http-5xx-by-endpoint (upstream fixture) plus a
    ~45-line crowd catalog (fixtures/crowd-catalog.txt) with the true
    match buried mid-list; brief is the nearmiss paraphrase.
    Pre-registered outcomes in preflight/RUNBOOK.md — any outcome is a
    valid result; the checker stays observational for this scenario.
    Strip at PR cherry-pick time. -->
