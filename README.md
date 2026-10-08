# SafeStack Findings Upload

A composite GitHub Action that uploads a scanner report file to SafeStack's
findings ingest API (`POST /api/ingest/findings`). It gzips the report,
authenticates with GitHub OIDC or a scanner token, retries on rate limits and
server errors, and polls the upload's status after a successful submission.

It does not run any scanner itself. Run your tool first, point `file` at its
report, and this action handles the upload.

## Usage

```yaml
permissions:
  id-token: write # omit if you pass `token` instead of using OIDC
  contents: read

jobs:
  upload-findings:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned-sha> # vX.Y.Z
      # ... run your scanner, producing report.json ...
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: semgrep
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

Pin `findings-upload-action` to a full commit SHA, the same as any other
third-party action, and keep the version comment next to it.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `file` | yes | | Path to the scanner report file. |
| `format` | yes | | `standard`, `sarif`, `semgrep`, `gosec`, `brakeman`, `sonarqube`, `trivy`, or `bandit`. |
| `repository-id` | yes | | SafeStack repository id (UUID), from the Scanner uploads page. |
| `mode` | no | `snapshot` | `snapshot` (authoritative for the scope; closes findings not seen) or `delta` (adds/updates only). |
| `scope` | no | `""` | Optional scope label, for splitting one repository's findings into independent reconciliation groups (for example per service in a monorepo). |
| `category` | no | `""` | `sast`, `sca`, `secret`, or `iac`. |
| `token` | no | `""` | A scanner token. When omitted, the action requests a GitHub OIDC token instead. |
| `api-url` | no | `https://api.safestackai.com` | SafeStack API base URL. |
| `audience` | no | `https://api.safestackai.com` | OIDC audience requested from GitHub. Ignored when `token` is set. |
| `fail-on-error` | no | `true` | When `false`, a rejected or failed upload is logged as a warning instead of failing the job. |

`ref`, `commit_sha`, and `source_root` are set automatically from
`$GITHUB_REF`, `$GITHUB_SHA`, and `$GITHUB_WORKSPACE`; they are not inputs.

## Outputs

| Output | Description |
|---|---|
| `upload-id` | Id of the created upload. |
| `status-url` | URL to check the upload's processing status later. |
| `status` | Last known status (`received`, `processing`, `completed`, `failed`, `skipped`, or an API error code if the upload itself was rejected). |

## Authentication

### GitHub OIDC (default)

Requires `permissions: id-token: write` on the job. The action requests an
OIDC token from GitHub, scoped to the `audience` input, and sends it as a
bearer token. SafeStack verifies the token against GitHub's JWKS and checks
that the token's `repository_id` and `repository` claims match the
repository you are uploading to, and that its `ref` and `commit_sha` claims
match the values this action sends. OIDC must be enabled for your account in
SafeStack first (Settings > Scanner uploads).

### Scanner token

Create a token from the Scanner uploads page in SafeStack and store it as a
repository or organization secret. Pass it as `token`:

```yaml
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: semgrep
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
          token: ${{ secrets.SAFESTACK_SCANNER_TOKEN }}
```

A token restricted to one repository does not need to match anything beyond
what SafeStack already enforces; an "all repositories" token still uses the
same `repository-id` input, since SafeStack needs it to resolve the upload's
tracked-branch mapping.

## Non-tracked branches

Each repository has one tracked branch in SafeStack. An upload whose `ref`
does not match it is accepted and returns `status: skipped`; this is not a
failure, so pull request jobs are never blocked by it. The action logs a
notice explaining the skip and exits successfully.

## Large snapshot closes

A `snapshot` upload that would close more than half, and more than 10, of a
scope's open findings is held for owner confirmation rather than applied
automatically. The upload still succeeds and `completed`, but
`reconcile_reason` comes back `needs_confirmation`; the action logs a notice
pointing at the SafeStack UI, since confirming the close is an owner action
the Action itself cannot take.

## Size limit

The gzipped report must be under 25 MB. The action checks this locally,
before making any request, and fails with a clear message if the file is
too large.

## Retries

On `429` (rate limited or over quota) or a `5xx`/network error, the action
retries up to 3 times with backoff, honoring the API's `retry_after` value
when present. A `4xx` response (bad input, auth, or a parse error) fails
immediately with the API's error code and detail; it is never retried.

## Per-tool examples

Each snippet produces the report file this action then uploads. Replace
`<pinned-sha>` with a real commit SHA before using any of these.

### Semgrep

```yaml
      - run: semgrep ci --json --output report.json
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: semgrep
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### gosec

Run without `-quiet`; a quiet run can suppress findings a native-id upload
needs for stable identity across runs. Pass `source_root` is handled by the
action automatically; just give it an absolute-path-free report.

```yaml
      - run: gosec -fmt json -out report.json ./...
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: gosec
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### Brakeman

```yaml
      - run: brakeman -f json -o report.json
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: brakeman
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### Trivy

```yaml
      - run: trivy fs --format json --output report.json .
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: trivy
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### Bandit

Install with the `sarif` extra and emit SARIF; Bandit's native JSON format
has weaker identity guarantees across runs than its SARIF output.

```yaml
      - run: pip install "bandit[sarif]"
      - run: bandit -r . -f sarif -o report.sarif
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.sarif
          format: sarif
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### Any other SARIF-producing tool

```yaml
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.sarif
          format: sarif
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
```

### SonarQube

SafeStack does not pull from or export SonarQube on your behalf. Build one
JSON file per page of `api/issues/search` yourself, with `resolved=false` so
closed issues are not re-reported, wrap the pages in `{"pages": [...]}`, and
upload that:

```yaml
      - name: Export SonarQube issues
        run: |
          page=1
          pages="[]"
          while :; do
            response="$(curl -fsSL -u "${SONAR_TOKEN}:" \
              "${SONAR_HOST}/api/issues/search?componentKeys=${SONAR_PROJECT}&resolved=false&p=${page}&ps=500")"
            pages="$(jq --argjson p "${response}" '. + [$p]' <<<"${pages}")"
            total="$(jq -r '.total' <<<"${response}")"
            fetched=$((page * 500))
            [ "${fetched}" -ge "${total}" ] && break
            page=$((page + 1))
          done
          jq -n --argjson pages "${pages}" '{"pages": $pages}' > report.json
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
      - uses: SafeStackAI/findings-upload-action@<pinned-sha> # vX.Y.Z
        with:
          file: report.json
          format: sonarqube
          repository-id: ${{ vars.SAFESTACK_REPOSITORY_ID }}
          token: ${{ secrets.SAFESTACK_SCANNER_TOKEN }}
```

## Development

```sh
shellcheck upload.sh tests/upload_test.sh
shfmt -d -i 2 upload.sh tests/upload_test.sh
actionlint .github/workflows/*.yml
zizmor .github/workflows/ action.yml
tests/upload_test.sh
```

`tests/upload_test.sh` starts a stdlib-only Python mock of the ingest API
and the GitHub OIDC token endpoint (`tests/mock_server.py`), then runs
`upload.sh` against it directly, so it needs no network access and no real
SafeStack account.

The `smoke` job in `.github/workflows/test.yml` runs real uploads against a
staging SafeStack instance with both OIDC and a scanner token. It is
disabled until the `SAFESTACK_STAGING_API_URL` and
`SAFESTACK_SMOKE_REPOSITORY_ID` repository variables and the
`SAFESTACK_SMOKE_SCANNER_TOKEN` secret are set and the `ENABLE_STAGING_SMOKE`
repository variable is set to `true`.
