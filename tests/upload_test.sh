#!/usr/bin/env bash
# Runs upload.sh against the local mock server in tests/mock_server.py,
# covering token auth, OIDC auth, polling, retries, limits and masking.
# Runnable locally: tests/upload_test.sh
set -euo pipefail

original_dir="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_dir="$(cd "${script_dir}/.." && pwd)"
upload_script="${action_dir}/upload.sh"
fixture="${script_dir}/fixtures/sample-report.json"
python_bin="${PYTHON_BIN:-python3}"

port=8787
base_url="http://127.0.0.1:${port}"
token_value="sst_test_token_abcdef0123456789"

workdir="$(mktemp -d)"
auth_log="${workdir}/auth.log"
: >"${auth_log}"

server_pid=""
cleanup() {
  if [ -n "${server_pid}" ]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

"${python_bin}" "${script_dir}/mock_server.py" "${port}" "${auth_log}" &
server_pid=$!

ready=0
for _ in $(seq 1 50); do
  if curl --silent --output /dev/null "${base_url}/oidc-token"; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "${ready}" -eq 1 ] || {
  echo "mock server did not start" >&2
  exit 1
}

failures=0
pass_count=0

report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "${ok}" = "0" ]; then
    echo "PASS: ${name}"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: ${name} -- ${detail}"
    failures=$((failures + 1))
  fi
}

common_env() {
  export INPUT_FILE="${fixture}"
  export INPUT_FORMAT="standard"
  export INPUT_MODE="snapshot"
  export INPUT_SCOPE=""
  export INPUT_CATEGORY=""
  export INPUT_API_URL="${base_url}"
  export INPUT_AUDIENCE="https://api.safestackai.com"
  export INPUT_FAIL_ON_ERROR="true"
  export GITHUB_REF="refs/heads/main"
  export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
  export GITHUB_RUN_ID="1001"
  export GITHUB_RUN_ATTEMPT="1"
  export GITHUB_WORKSPACE="${workdir}"
  unset INPUT_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
}

# run_upload <case-name> -> prints the exit code; writes
# <case-name>.out (combined stdout/stderr) and <case-name>.outputs
# (the GITHUB_OUTPUT file) under $workdir.
run_upload() {
  local case_name="$1"
  local out_file="${workdir}/${case_name}.out"
  local output_file="${workdir}/${case_name}.outputs"
  : >"${output_file}"
  set +e
  GITHUB_OUTPUT="${output_file}" "${upload_script}" >"${out_file}" 2>&1
  local rc=$?
  set -e
  echo "${rc}"
}

output_value() {
  grep "^$2=" "${workdir}/$1.outputs" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- token auth happy path + 202 then poll to completed --------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-ok"
rc="$(run_upload token_happy)"
upload_id="$(output_value token_happy upload-id)"
status="$(output_value token_happy status)"
if [ "${rc}" = "0" ] && [ -n "${upload_id}" ] && [ "${status}" = "completed" ]; then
  report "token auth happy path, 202 then poll to completed" 0
else
  report "token auth happy path, 202 then poll to completed" 1 \
    "rc=${rc} upload_id=${upload_id} status=${status}: $(cat "${workdir}/token_happy.out")"
fi

occurrences="$(grep -c -- "${token_value}" "${workdir}/token_happy.out" || true)"
mask_line="$(grep -- "${token_value}" "${workdir}/token_happy.out" | head -1)"
case "${mask_line}" in
::add-mask::*) mask_ok=0 ;;
*) mask_ok=1 ;;
esac
if [ "${occurrences}" = "1" ] && [ "${mask_ok}" = "0" ]; then
  report "token never printed outside ::add-mask::" 0
else
  report "token never printed outside ::add-mask::" 1 "occurrences=${occurrences} line=${mask_line}"
fi

# --- OIDC auth path -----------------------------------------------------

common_env
export INPUT_REPOSITORY_ID="repo-ok-oidc"
export ACTIONS_ID_TOKEN_REQUEST_URL="${base_url}/oidc-token?x=1"
export ACTIONS_ID_TOKEN_REQUEST_TOKEN="fake-runner-token"
rc="$(run_upload oidc_happy)"
upload_id="$(output_value oidc_happy upload-id)"
sent_auth="$(tail -1 "${auth_log}")"
if [ "${rc}" = "0" ] && [ -n "${upload_id}" ] && [ "${sent_auth}" = "Bearer mock-oidc-jwt-token-value" ]; then
  report "OIDC auth path sends the requested id-token" 0
else
  report "OIDC auth path sends the requested id-token" 1 \
    "rc=${rc} upload_id=${upload_id} sent_auth=${sent_auth}: $(cat "${workdir}/oidc_happy.out")"
fi

occurrences="$(grep -c -- "mock-oidc-jwt-token-value" "${workdir}/oidc_happy.out" || true)"
mask_line="$(grep -- "mock-oidc-jwt-token-value" "${workdir}/oidc_happy.out" | head -1)"
case "${mask_line}" in
::add-mask::*) mask_ok=0 ;;
*) mask_ok=1 ;;
esac
if [ "${occurrences}" = "1" ] && [ "${mask_ok}" = "0" ]; then
  report "OIDC id-token never printed outside ::add-mask::" 0
else
  report "OIDC id-token never printed outside ::add-mask::" 1 "occurrences=${occurrences} line=${mask_line}"
fi

# --- 422 parse error -> failure with message ----------------------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-422"
rc="$(run_upload parse_error)"
out="$(cat "${workdir}/parse_error.out")"
if [ "${rc}" != "0" ] && printf '%s' "${out}" | grep -q "invalid_report" &&
  printf '%s' "${out}" | grep -q "bad json at offset 4"; then
  report "422 parse error fails with the API's message" 0
else
  report "422 parse error fails with the API's message" 1 "rc=${rc} out=${out}"
fi

# --- fail-on-error=false downgrades failure to a warning ----------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-422"
export INPUT_FAIL_ON_ERROR="false"
rc="$(run_upload soft_fail)"
out="$(cat "${workdir}/soft_fail.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "::warning::upload failed"; then
  report "fail-on-error=false downgrades failure to a warning" 0
else
  report "fail-on-error=false downgrades failure to a warning" 1 "rc=${rc} out=${out}"
fi

# --- 429 retry/backoff honoring retry_after, then success ---------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-429-then-ok"
rc="$(run_upload retry_429)"
out="$(cat "${workdir}/retry_429.out")"
upload_id="$(output_value retry_429 upload-id)"
if [ "${rc}" = "0" ] && [ -n "${upload_id}" ] && printf '%s' "${out}" | grep -q "rate limited (429); retrying"; then
  report "429 retry/backoff honors retry_after, then succeeds" 0
else
  report "429 retry/backoff honors retry_after, then succeeds" 1 "rc=${rc} upload_id=${upload_id} out=${out}"
fi

# --- 5xx retry/backoff, then success -------------------------------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-500-then-ok"
rc="$(run_upload retry_500)"
out="$(cat "${workdir}/retry_500.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "retrying in"; then
  report "5xx retry/backoff, then succeeds" 0
else
  report "5xx retry/backoff, then succeeds" 1 "rc=${rc} out=${out}"
fi

# --- oversize file rejected locally, before any request ------------------

oversize_file="${workdir}/oversize.bin"
head -c 27000000 /dev/urandom >"${oversize_file}"
common_env
export INPUT_FILE="${oversize_file}"
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-should-not-be-called"
pre_auth_lines="$(wc -l <"${auth_log}" | tr -d ' ')"
rc="$(run_upload oversize)"
post_auth_lines="$(wc -l <"${auth_log}" | tr -d ' ')"
out="$(cat "${workdir}/oversize.out")"
if [ "${rc}" != "0" ] && [ "${pre_auth_lines}" = "${post_auth_lines}" ] && printf '%s' "${out}" | grep -q "25 MB"; then
  report "oversize file rejected locally before any upload request" 0
else
  report "oversize file rejected locally before any upload request" 1 "rc=${rc} out=${out}"
fi

# --- warnings surfaced as ::warning:: -------------------------------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-warnings"
rc="$(run_upload warnings)"
out="$(cat "${workdir}/warnings.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "::warning::semgrep_integration_active"; then
  report "warnings are surfaced as ::warning::" 0
else
  report "warnings are surfaced as ::warning::" 1 "rc=${rc} out=${out}"
fi

# --- skip reason reads status_reason, not an unrelated drop reason -----

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-skip-with-drop"
rc="$(run_upload skip_reason)"
out="$(cat "${workdir}/skip_reason.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "upload skipped: ref_not_tracked" &&
  ! printf '%s' "${out}" | grep -q "unrelated_drop_reason"; then
  report "skip reason reads status_reason, not errors[0].reason" 0
else
  report "skip reason reads status_reason, not errors[0].reason" 1 "rc=${rc} out=${out}"
fi

# --- failed upload surfaces status_reason and fails the job ------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-failed"
rc="$(run_upload failed_reason)"
out="$(cat "${workdir}/failed_reason.out")"
if [ "${rc}" != "0" ] && printf '%s' "${out}" | grep -q "payload_corrupt"; then
  report "failed upload surfaces status_reason and fails per fail-on-error" 0
else
  report "failed upload surfaces status_reason and fails per fail-on-error" 1 "rc=${rc} out=${out}"
fi

# --- filename starting with '-' doesn't break gzip/sha256sum -----------

dash_dir="${workdir}/dashtest"
mkdir -p "${dash_dir}"
cp "${fixture}" "${dash_dir}/-dash-report.json"
common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-ok"
export INPUT_FILE="-dash-report.json"
cd "${dash_dir}" || exit 1
rc="$(run_upload dash_filename)"
cd "${original_dir}" || exit 1
upload_id="$(output_value dash_filename upload-id)"
if [ "${rc}" = "0" ] && [ -n "${upload_id}" ]; then
  report "filename starting with '-' uploads successfully" 0
else
  report "filename starting with '-' uploads successfully" 1 \
    "rc=${rc} upload_id=${upload_id}: $(cat "${workdir}/dash_filename.out")"
fi

# --- needs_confirmation is surfaced as ::warning::, not ::notice:: ------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-needs-confirmation"
rc="$(run_upload needs_confirmation)"
out="$(cat "${workdir}/needs_confirmation.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "::warning::.*shrink guard" &&
  ! printf '%s' "${out}" | grep -q "::notice::.*shrink guard"; then
  report "needs_confirmation is surfaced as ::warning::" 0
else
  report "needs_confirmation is surfaced as ::warning::" 1 "rc=${rc} out=${out}"
fi

# --- poll 403 is a terminal error, not silent "still processing" -------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-poll-403"
rc="$(run_upload poll_403)"
out="$(cat "${workdir}/poll_403.out")"
if [ "${rc}" != "0" ] && printf '%s' "${out}" | grep -q "::error::polling upload"; then
  report "poll 403 fails the job instead of silently retrying forever" 0
else
  report "poll 403 fails the job instead of silently retrying forever" 1 "rc=${rc} out=${out}"
fi

# --- poll 404, with fail-on-error=false, warns and exits 0 -------------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-poll-404"
export INPUT_FAIL_ON_ERROR="false"
rc="$(run_upload poll_404)"
out="$(cat "${workdir}/poll_404.out")"
if [ "${rc}" = "0" ] && printf '%s' "${out}" | grep -q "::warning::polling upload"; then
  report "poll 404 with fail-on-error=false warns and exits 0" 0
else
  report "poll 404 with fail-on-error=false warns and exits 0" 1 "rc=${rc} out=${out}"
fi

# --- poll 5xx retries within the existing bound, then succeeds ---------

common_env
export INPUT_TOKEN="${token_value}"
export INPUT_REPOSITORY_ID="repo-poll-500-then-ok"
rc="$(run_upload poll_500)"
out="$(cat "${workdir}/poll_500.out")"
status="$(output_value poll_500 status)"
if [ "${rc}" = "0" ] && [ "${status}" = "completed" ]; then
  report "poll 5xx is retried within the existing bound, then succeeds" 0
else
  report "poll 5xx is retried within the existing bound, then succeeds" 1 "rc=${rc} status=${status} out=${out}"
fi

echo "----"
echo "${pass_count} passed, ${failures} failed"
[ "${failures}" -eq 0 ]
