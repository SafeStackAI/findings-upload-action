#!/usr/bin/env bash
# Uploads a scanner report to the SafeStack findings ingest API.
#
# Reads INPUT_* environment variables set by action.yml, authenticates with
# a scanner token or GitHub OIDC, gzips the report, retries on 429/5xx/network
# errors, and polls the status URL for a bounded time after a 202 response.
set -euo pipefail

MAX_COMPRESSED_BYTES=$((25 * 1024 * 1024))
MAX_RETRIES=3
POLL_INTERVAL_SECONDS=3
POLL_MAX_ATTEMPTS=10
RETRY_AFTER_MIN_SECONDS=1
RETRY_AFTER_MAX_SECONDS=60
MAX_WORKFLOW_MESSAGE_LEN=500

# escape_workflow_command encodes text for safe interpolation into a GitHub
# Actions workflow command (::error::, ::warning::, ::notice::), per GitHub's
# documented escaping (% -> %25, CR -> %0D, LF -> %0A), and caps its length
# so a server-provided string can't inject extra command lines into the job
# log or blow up the log with unbounded text.
escape_workflow_command() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  if [ "${#s}" -gt "${MAX_WORKFLOW_MESSAGE_LEN}" ]; then
    s="${s:0:${MAX_WORKFLOW_MESSAGE_LEN}}...(truncated)"
  fi
  printf '%s' "${s}"
}

die() {
  echo "::error::$(escape_workflow_command "$1")"
  exit 1
}

warn() {
  echo "::warning::$(escape_workflow_command "$1")"
}

notice() {
  echo "::notice::$(escape_workflow_command "$1")"
}

fail_or_warn() {
  local message="$1"
  if [ "${fail_on_error}" = "true" ]; then
    die "${message}"
  fi
  warn "${message}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# error_code_of extracts the API's "error" field from a response body,
# falling back to "unknown_error" for an empty or non-JSON body.
error_code_of() {
  echo "$1" | jq -r '.error // "unknown_error"' 2>/dev/null || echo unknown_error
}

# print_warnings emits each string in a JSON array of warnings as its own
# ::warning::.
print_warnings() {
  local warnings_json="$1"
  while IFS= read -r w; do
    [ -n "${w}" ] && warn "${w}"
  done < <(echo "${warnings_json}" | jq -r '.[]')
}

set_output() {
  echo "$1=$2" >>"${GITHUB_OUTPUT}"
}

file="${INPUT_FILE:?file input is required}"
format="${INPUT_FORMAT:?format input is required}"
repository_id="${INPUT_REPOSITORY_ID:?repository-id input is required}"
mode="${INPUT_MODE:-snapshot}"
scope="${INPUT_SCOPE:-}"
category="${INPUT_CATEGORY:-}"
token="${INPUT_TOKEN:-}"
api_url="${INPUT_API_URL:-https://api.safestackai.com}"
audience="${INPUT_AUDIENCE:-https://api.safestackai.com}"
fail_on_error="${INPUT_FAIL_ON_ERROR:-true}"

[ -f "${file}" ] || die "file not found: ${file}"

workdir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/findings-upload.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

gz_file="${workdir}/report.gz"
gzip -c -- "${file}" >"${gz_file}"

gz_size=$(wc -c <"${gz_file}" | tr -d ' ')
if [ "${gz_size}" -gt "${MAX_COMPRESSED_BYTES}" ]; then
  die "gzipped report is ${gz_size} bytes, over the 25 MB (${MAX_COMPRESSED_BYTES} bytes) limit"
fi

auth_header=""
if [ -n "${token}" ]; then
  echo "::add-mask::${token}"
  auth_header="Authorization: Bearer ${token}"
else
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?OIDC requires permissions: id-token: write}"
  : "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?OIDC requires permissions: id-token: write}"
  oidc_response="$(curl --silent --show-error --fail \
    --url "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$(urlencode "${audience}")" \
    --header "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}")" || die "failed to request OIDC token"
  id_token="$(echo "${oidc_response}" | jq -r '.value // empty')"
  [ -n "${id_token}" ] || die "OIDC token request returned no value"
  echo "::add-mask::${id_token}"
  auth_header="Authorization: Bearer ${id_token}"
fi

file_hash="$(sha256_of "${file}")"
idempotency_key="${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}-${file_hash}"

ref="${GITHUB_REF:?GITHUB_REF is not set}"
commit_sha="${GITHUB_SHA:?GITHUB_SHA is not set}"
source_root="${GITHUB_WORKSPACE:-}"

query="repository=$(urlencode "${repository_id}")"
query="${query}&ref=$(urlencode "${ref}")"
query="${query}&commit_sha=$(urlencode "${commit_sha}")"
query="${query}&format=$(urlencode "${format}")"
query="${query}&mode=$(urlencode "${mode}")"
[ -n "${scope}" ] && query="${query}&scope=$(urlencode "${scope}")"
[ -n "${category}" ] && query="${query}&category=$(urlencode "${category}")"
[ -n "${source_root}" ] && query="${query}&source_root=$(urlencode "${source_root}")"

url="${api_url%/}/api/ingest/findings?${query}"

status_file="${workdir}/status"
body_file="${workdir}/body"
http_status_code=""

post_upload() {
  if curl --silent --show-error \
    --output "${body_file}" --write-out '%{http_code}' \
    --request POST \
    --header "${auth_header}" \
    --header "Content-Encoding: gzip" \
    --header "Content-Type: application/octet-stream" \
    --header "Idempotency-Key: ${idempotency_key}" \
    --data-binary "@${gz_file}" \
    "${url}" >"${status_file}" 2>"${workdir}/curl_err"; then
    http_status_code="$(cat "${status_file}")"
  else
    http_status_code="curl_error"
  fi
}

get_status() {
  if curl --silent --show-error \
    --output "${body_file}" --write-out '%{http_code}' \
    --header "${auth_header}" \
    "$1" >"${status_file}" 2>"${workdir}/poll_err"; then
    http_status_code="$(cat "${status_file}")"
  else
    http_status_code="curl_error"
  fi
}

# clamp_retry_after validates that $1 is a non-negative integer and clamps
# it to [RETRY_AFTER_MIN_SECONDS, RETRY_AFTER_MAX_SECONDS]; prints nothing
# (so the caller's own attempt-based backoff is used instead) when $1 is
# empty or not a plain integer, which also protects `sleep` from a
# negative or non-numeric value that would otherwise make it fail.
clamp_retry_after() {
  case "$1" in
  '' | *[!0-9]*) return ;;
  esac
  local seconds="$1"
  [ "${seconds}" -lt "${RETRY_AFTER_MIN_SECONDS}" ] && seconds="${RETRY_AFTER_MIN_SECONDS}"
  [ "${seconds}" -gt "${RETRY_AFTER_MAX_SECONDS}" ] && seconds="${RETRY_AFTER_MAX_SECONDS}"
  printf '%s' "${seconds}"
}

attempt=0
while :; do
  attempt=$((attempt + 1))
  post_upload
  case "${http_status_code}" in
  2??)
    break
    ;;
  429)
    [ "${attempt}" -ge "${MAX_RETRIES}" ] && break
    retry_after="$(jq -r '.retry_after // empty' "${body_file}" 2>/dev/null || true)"
    sleep_for="$(clamp_retry_after "${retry_after}")"
    sleep_for="${sleep_for:-$((attempt * 2))}"
    warn "upload rate limited (429); retrying in ${sleep_for}s (attempt ${attempt}/${MAX_RETRIES})"
    sleep "${sleep_for}"
    ;;
  5?? | curl_error)
    [ "${attempt}" -ge "${MAX_RETRIES}" ] && break
    sleep_for=$((attempt * 2))
    warn "upload attempt ${attempt} failed (${http_status_code}); retrying in ${sleep_for}s"
    sleep "${sleep_for}"
    ;;
  *)
    break
    ;;
  esac
done

body="$(cat "${body_file}" 2>/dev/null || echo '{}')"

case "${http_status_code}" in
2??) ;;
*)
  error_code="unknown_error"
  if [ "${http_status_code}" != "curl_error" ]; then
    error_code="$(error_code_of "${body}")"
  fi
  fail_or_warn "upload failed: HTTP ${http_status_code} (${error_code}): ${body}"
  set_output "status" "${error_code}"
  exit 0
  ;;
esac

upload_id="$(echo "${body}" | jq -r '.upload.id // empty')"
status_url="$(echo "${body}" | jq -r '.upload.status_url // empty')"
upload_status="$(echo "${body}" | jq -r '.upload.status // empty')"
warnings_json="$(echo "${body}" | jq -c '.upload.warnings // []')"
print_warnings "${warnings_json}"

if [ -n "${status_url}" ]; then
  case "${status_url}" in
  http*://*) ;;
  *) status_url="${api_url%/}${status_url}" ;;
  esac
fi

if [ "${upload_status}" = "skipped" ]; then
  skip_reason="$(echo "${body}" | jq -r '.upload.status_reason // "unknown_reason"' 2>/dev/null || echo "unknown_reason")"
  notice "upload skipped: ${skip_reason}"
fi

final_status="${upload_status}"

is_pending() {
  [ "$1" = "received" ] || [ "$1" = "processing" ]
}

if is_pending "${upload_status}" && [ -n "${status_url}" ]; then
  poll_attempt=0
  while [ "${poll_attempt}" -lt "${POLL_MAX_ATTEMPTS}" ]; do
    poll_attempt=$((poll_attempt + 1))
    sleep "${POLL_INTERVAL_SECONDS}"
    get_status "${status_url}"
    case "${http_status_code}" in
    2??)
      body="$(cat "${body_file}" 2>/dev/null || echo '{}')"
      final_status="$(echo "${body}" | jq -r '.upload.status // empty')"
      is_pending "${final_status}" || break
      ;;
    401 | 403 | 404)
      poll_body="$(cat "${body_file}" 2>/dev/null || echo '{}')"
      poll_error_code="$(error_code_of "${poll_body}")"
      fail_or_warn "polling upload ${upload_id} failed: HTTP ${http_status_code} (${poll_error_code})"
      final_status="poll_error_${http_status_code}"
      break
      ;;
    *) ;;
    esac
  done
  case "${http_status_code}" in
  2??)
    warnings_json="$(echo "${body}" | jq -c '.upload.warnings // []')"
    print_warnings "${warnings_json}"
    ;;
  esac
  if is_pending "${final_status}"; then
    notice "upload ${upload_id} is still ${final_status} after ${POLL_MAX_ATTEMPTS} polling attempts; check status-url later"
  fi
fi

if [ "${final_status}" = "failed" ]; then
  failure_reason="$(echo "${body}" | jq -r '.upload.status_reason // "unknown_reason"' 2>/dev/null || echo "unknown_reason")"
  fail_or_warn "processing failed for upload ${upload_id}: ${failure_reason}"
fi

if [ "${final_status}" = "completed" ]; then
  reconcile_reason="$(echo "${body}" | jq -r '.upload.reconcile_reason // empty' 2>/dev/null || true)"
  if [ "${reconcile_reason}" = "needs_confirmation" ]; then
    warn "snapshot would close more findings than the shrink guard allows; an owner must confirm this close in the SafeStack UI before it applies"
  fi
fi

set_output "upload-id" "${upload_id}"
set_output "status-url" "${status_url}"
set_output "status" "${final_status}"

notice "upload ${upload_id}: ${final_status}"
