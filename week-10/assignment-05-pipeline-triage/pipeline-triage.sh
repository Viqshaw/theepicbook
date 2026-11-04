#!/usr/bin/env bash
#
# pipeline-triage.sh — READ-ONLY CI/CD failure triage for the EpicBook
# dual-pipeline project in Azure DevOps.
#
# Retrieves the latest run metadata and the step-by-step console logs for the
# Infrastructure and Application pipelines, sanitizes the logs, classifies any
# failure, and writes:
#   reports/pipeline-health-report.txt
#   reports/infra-last-run.log
#   reports/app-last-run.log
#
# Read-only: only HTTP GET requests are made (Builds and Pipelines REST APIs).
# No run is queued, retried, canceled, approved, or deleted, and no Azure,
# Terraform, or Ansible command is executed.
#
# Authentication: uses the existing Azure CLI login (`az login`). The script
# requests a short-lived Azure DevOps access token at runtime and never writes
# it to disk, to the report, or to the console. No PAT or password is stored
# in this file.
#
# Exit codes:
#   0 — Both latest completed runs succeeded and no warnings were raised
#   1 — Warning or incomplete state (queued/running, partially succeeded,
#       canceled, or no completed run found)
#   2 — One or more pipeline failures detected
#   3 — Configuration, authentication, API, log-retrieval, or dependency error
#       (health cannot be confirmed)

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Configuration — replace every <placeholder> before running.
# ---------------------------------------------------------------------------
FULL_NAME="tonye Bagshaw"  # Your full name, for the report header
ORG_URL="https://dev.azure.com/youngarneyikuroaa"
PROJECT="EpicBook-Deployment"  # Azure DevOps project name (case-sensitive)
INFRA_PIPELINE_ID="6"
APP_PIPELINE_ID="5"

# Azure DevOps API version and the well-known Azure DevOps resource ID used to
# request an access token from the Azure CLI.
API_VERSION="7.1"
ADO_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798"

# Maximum number of evidence lines copied into the report per category.
MAX_EVIDENCE_LINES=5

# ---------------------------------------------------------------------------
# Base directory: the directory that contains this script.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/pipeline-health-report.txt"
INFRA_LOG_FILE="${REPORT_DIR}/infra-last-run.log"
APP_LOG_FILE="${REPORT_DIR}/app-last-run.log"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
TOKEN=""
AUTH_MODE=""                # "pat" or "az"
TMP_DIR=""
CURRENT_PIPELINE_LABEL=""   # "Infrastructure" or "Application"
CURRENT_PIPELINE_ID=""
CURRENT_LOG_FILE=""
CURRENT_RUN_RESULT=""       # Azure DevOps result of the latest completed run
CURRENT_MATCHES=0           # Number of failure-pattern categories matched

# Each entry: LEVEL|Pipeline|Check|Detail   (LEVEL = PASS|WARN|FAIL|ERROR)
RESULTS=()
# Pipeline summary lines for the report.
PIPELINE_SUMMARIES=()

# Overall health derived from RESULTS.
OVERALL_HEALTH=""

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

add_result() {
    # add_result LEVEL PIPELINE CHECK DETAIL
    RESULTS+=("$1|$2|$3|$4")
}

cleanup() {
    TOKEN=""
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}
trap cleanup EXIT

# Fail fast with a configuration error (exit 3).
die_config() {
    log_error "Configuration error: $*"
    exit 3
}

# ---------------------------------------------------------------------------
# Preflight: configuration, dependencies, authentication
# ---------------------------------------------------------------------------
check_config() {
    local value name
    for name in FULL_NAME ORG_URL PROJECT INFRA_PIPELINE_ID APP_PIPELINE_ID; do
        value="${!name}"
        if [[ -z "${value}" || "${value}" == *"<"* || "${value}" == *">"* ]]; then
            die_config "${name} still contains a placeholder. Edit pipeline-triage.sh."
        fi
    done

    if [[ ! "${ORG_URL}" =~ ^https://dev\.azure\.com/[^/[:space:]]+/?$ ]]; then
        die_config "ORG_URL must look like https://dev.azure.com/<organization>."
    fi
    ORG_URL="${ORG_URL%/}"

    if [[ ! "${INFRA_PIPELINE_ID}" =~ ^[0-9]+$ ]]; then
        die_config "INFRA_PIPELINE_ID must be the numeric pipeline ID, not a name."
    fi
    if [[ ! "${APP_PIPELINE_ID}" =~ ^[0-9]+$ ]]; then
        die_config "APP_PIPELINE_ID must be the numeric pipeline ID, not a name."
    fi
}

check_dependencies() {
    local tool
    for tool in az curl jq sed awk grep mktemp; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            die_config "Required tool '${tool}' was not found on PATH."
        fi
    done
}

prepare_report_dir() {
    mkdir -p -- "${REPORT_DIR}" || die_config "Cannot create report directory: ${REPORT_DIR}"
    TMP_DIR="$(mktemp -d "${REPORT_DIR}/.triage-tmp.XXXXXX")" \
        || die_config "Cannot create temporary working directory."
}

acquire_token() {
    # Option 1: a personal access token supplied through the environment.
    # It is read here, used only for the curl config, and never printed or saved.
    if [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]]; then
        AUTH_MODE="pat"
        log_info "Authenticating with the personal access token in AZURE_DEVOPS_EXT_PAT (value not shown)."
        return 0
    fi

    # Option 2: the Azure CLI login. The token is held only in memory. Errors
    # from az are suppressed so that no credential-adjacent output reaches the console.
    AUTH_MODE="az"
    if ! az account show >/dev/null 2>&1; then
        exit_auth_error "Azure CLI is not logged in. Run 'az login' and retry."
    fi
    TOKEN="$(az account get-access-token --resource "${ADO_RESOURCE_ID}" \
                --query accessToken -o tsv 2>/dev/null || true)"
    if [[ -z "${TOKEN}" ]]; then
        exit_auth_error "Could not obtain an Azure DevOps access token from the Azure CLI."
    fi
}

exit_auth_error() {
    log_error "Authentication error: $*"
    exit 3
}

# ---------------------------------------------------------------------------
# Read-only API access (HTTP GET only)
# ---------------------------------------------------------------------------
# auth_curl_config
#   Prints the curl credential line(s) for the active auth mode. It is used
#   only through a process substitution, so the secret never appears in argv.
#   PAT mode uses HTTP Basic with an empty username, which is how Azure DevOps
#   accepts personal access tokens.
auth_curl_config() {
    if [[ "${AUTH_MODE}" == "pat" ]]; then
        printf 'user = ":%s"\n' "${AZURE_DEVOPS_EXT_PAT}"
    else
        printf 'header = "Authorization: Bearer %s"\n' "${TOKEN}"
    fi
}

# api_get RELATIVE_PATH OUTPUT_FILE
#   Sends an authenticated GET to ${ORG_URL}/${PROJECT}/_apis/${RELATIVE_PATH}.
#   The Authorization header is passed through a curl config read from a
#   process substitution so the token never appears in argv or on screen.
#   Returns 0 on HTTP 200. Otherwise prints a classified error and returns 1.
api_get() {
    local relative_path="$1"
    local output_file="$2"
    # Optional third argument: the Accept type. Step logs must be requested as
    # text/plain; asking for JSON makes the API wrap each log line in JSON.
    local accept="${3:-application/json}"
    local encoded_project url http_code curl_rc

    encoded_project="$(printf '%s' "${PROJECT}" | jq -sRr '@uri')"
    url="${ORG_URL}/${encoded_project}/_apis/${relative_path}"

    # Redirects are NOT followed: Azure DevOps answers an unauthorized request
    # with a 403 that redirects to a sign-out HTML page, which would otherwise
    # look like a successful 200 response.
    local response content_type
    set +e
    response="$(curl --silent --show-error \
                    --request GET \
                    --output "${output_file}" \
                    --write-out '%{http_code} %{content_type}' \
                    --config <(auth_curl_config) \
                    --header "Accept: ${accept}" \
                    "${url}" 2>"${TMP_DIR}/curl.err")"
    curl_rc=$?
    set -e

    if (( curl_rc != 0 )); then
        log_error "API error: network or TLS failure calling ${relative_path%%\?*} (curl exit ${curl_rc})."
        return 1
    fi

    http_code="${response%% *}"
    content_type="${response#* }"

    case "${http_code}" in
        200)
            # An HTML body on a 200 means a sign-in or redirect page, not API data.
            if [[ "${content_type}" == text/html* ]]; then
                log_error "Authentication error: the API returned a web page instead of data for ${relative_path%%\?*}. The account is likely not a member of this organization."
                return 1
            fi
            return 0 ;;
        401|403)     log_error "Authentication/authorization error (HTTP ${http_code}) calling ${relative_path%%\?*}. Check Azure CLI login and project permissions."
                     return 1 ;;
        30[0-9])     log_error "Authentication error (HTTP ${http_code}): the request was redirected to a sign-in page for ${relative_path%%\?*}. The account is likely not a member of this organization."
                     return 1 ;;
        404)         log_error "Not found (HTTP 404) calling ${relative_path%%\?*}. Check ORG_URL, PROJECT, and pipeline IDs."
                     return 1 ;;
        *)           log_error "API error (HTTP ${http_code}) calling ${relative_path%%\?*}."
                     return 1 ;;
    esac
}

# Authentication/config/API errors must never be reported as healthy.
# A failed API call marks the pipeline as ERROR; the caller then stops.
api_fail_pipeline() {
    # Returns 0 on purpose: under `set -e` a non-zero return here would stop the
    # script before the other pipeline is checked and before the report is written.
    add_result "ERROR" "${CURRENT_PIPELINE_LABEL}" "$1" "$2"
    return 0
}

# ---------------------------------------------------------------------------
# Sanitization — applied to every log line before it is written to disk or
# copied into the report. Redacts authorization headers, bearer/basic tokens,
# passwords/secrets/keys in key=value or key: value form, SAS signatures,
# long opaque tokens, and private-key blocks.
# ---------------------------------------------------------------------------
sanitize_stream() {
    awk '
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { print "[REDACTED: private key content]"; in_key = 1; next }
        in_key && /-----END [A-Z ]*PRIVATE KEY-----/ { in_key = 0; next }
        in_key { next }
        { print }
    ' | sed -E \
        -e 's/((Proxy-)?Authorization)[[:space:]]*[:=].*/\1: [REDACTED]/Ig' \
        -e 's/(Bearer|Basic|Token)[[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/\1 [REDACTED]/Ig' \
        -e 's/(password|passwd|pwd|client[_ -]?secret|secret|token|pat|accountkey|access[_ -]?key|sharedaccesssignature|sas[_ -]?token|connection[_ -]?string)([[:space:]]*[=:][[:space:]]*)[^;,"'\''[:space:]]+/\1\2[REDACTED]/Ig' \
        -e 's/(sig=)[^&[:space:]]+/\1[REDACTED]/Ig' \
        -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1[REDACTED]@#g' \
        -e 's/[A-Za-z0-9+\/_-]{40,}/[REDACTED_LONG_VALUE]/g'
}

# ---------------------------------------------------------------------------
# Run metadata
# ---------------------------------------------------------------------------
# Latest run of any state (used to detect queued/running runs).
fetch_latest_run() {
    local out="${TMP_DIR}/latest-${CURRENT_PIPELINE_ID}.json"
    api_get "build/builds?definitions=${CURRENT_PIPELINE_ID}&\$top=1&queryOrder=queueTimeDescending&api-version=${API_VERSION}" "${out}" || return 1
    jq -c '.value[0] // empty' "${out}"
}

# Latest completed run (used for the health result and the log download).
fetch_latest_completed_run() {
    local out="${TMP_DIR}/completed-${CURRENT_PIPELINE_ID}.json"
    api_get "build/builds?definitions=${CURRENT_PIPELINE_ID}&statusFilter=completed&\$top=1&queryOrder=finishTimeDescending&api-version=${API_VERSION}" "${out}" || return 1
    jq -c '.value[0] // empty' "${out}"
}

fetch_pipeline_name() {
    local out="${TMP_DIR}/pipeline-${CURRENT_PIPELINE_ID}.json"
    api_get "pipelines/${CURRENT_PIPELINE_ID}?api-version=${API_VERSION}" "${out}" || return 1
    jq -r '.name // "unknown"' "${out}"
}

# ---------------------------------------------------------------------------
# Log retrieval — downloads each step log as plain text via the Build Logs API
# ---------------------------------------------------------------------------
# download_run_log BUILD_ID DEST_FILE
download_run_log() {
    local build_id="$1"
    local dest="$2"
    local list_file="${TMP_DIR}/logs-${build_id}.json"
    local log_id part_file ids count=0

    api_get "build/builds/${build_id}/logs?api-version=${API_VERSION}" "${list_file}" || return 1

    # Log IDs in step order.
    ids="$(jq -r '.value[]?.id' "${list_file}")"
    if [[ -z "${ids}" ]]; then
        log_error "No step logs were returned for build ${build_id}."
        return 1
    fi

    : > "${TMP_DIR}/raw-${build_id}.log"
    while IFS= read -r log_id; do
        [[ -z "${log_id}" ]] && continue
        part_file="${TMP_DIR}/step-${build_id}-${log_id}.txt"
        api_get "build/builds/${build_id}/logs/${log_id}?api-version=${API_VERSION}" "${part_file}" "text/plain" || return 1
        {
            printf '===== Step log %s =====\n' "${log_id}"
            cat -- "${part_file}"
            printf '\n'
        } >> "${TMP_DIR}/raw-${build_id}.log"
        count=$((count + 1))
    done <<< "${ids}"

    # Sanitize BEFORE the log is stored anywhere in the report directory.
    sanitize_stream < "${TMP_DIR}/raw-${build_id}.log" > "${dest}.tmp"
    mv -f -- "${dest}.tmp" "${dest}"
    log_info "Downloaded ${count} step log(s) for build ${build_id} -> ${dest}"
}

# ---------------------------------------------------------------------------
# Failure classification
# ---------------------------------------------------------------------------
# scan_category CATEGORY_NAME PATTERN
#   Case-insensitive search of the sanitized log. Each matching line is added
#   as evidence (truncated). Increments CURRENT_MATCHES when anything matches.
scan_category() {
    local category="$1"
    local pattern="$2"
    local hits line_count evidence

    hits="$(grep -n -i -E -- "${pattern}" "${CURRENT_LOG_FILE}" 2>/dev/null || true)"
    if [[ -z "${hits}" ]]; then
        return 0
    fi

    CURRENT_MATCHES=$((CURRENT_MATCHES + 1))
    line_count="$(printf '%s\n' "${hits}" | wc -l)"
    evidence="$(printf '%s\n' "${hits}" | head -n "${MAX_EVIDENCE_LINES}" | cut -c1-300)"
    if [[ "${evidence}" == *"[REDACTED"* ]]; then
        evidence="${evidence}"$'\n'"(one or more lines contained redacted secret material)"
    fi
    add_result "FAIL" "${CURRENT_PIPELINE_LABEL}" "${category}" \
        "${line_count} matching line(s). Evidence:"$'\n'"${evidence}"
}

check_dependency_failure() {
    scan_category "Dependency installation failure" \
        'npm ERR!|ERESOLVE|Could not resolve dependencies|No matching distribution found|Could not find a version that satisfies|pip install .*(failed|error)|apt-get.*(failed|E: Unable)|Failed to install|Unable to resolve dependencies'
}

check_build_failure() {
    scan_category "Build or compilation failure" \
        'compilation failed|compilation terminated|build failed|error TS[0-9]+|error CS[0-9]+|error: could not compile|cannot find symbol|make: \*\*\*|webpack.*error'
}

check_test_failure() {
    scan_category "Test failure" \
        'tests? failed|[0-9]+ failing|AssertionError|FAILED tests?|Test Run Failed|pytest.*failed|##\[error\].*test'
}

check_auth_failure() {
    scan_category "Authentication, authorization, or SSH failure" \
        'unauthori[sz]ed|HTTP 40[13]|permission denied|authentication failed|could not authenticate|Host key verification failed|Access denied|AADSTS[0-9]+|service connection.*(not found|invalid|failed)|authorization failed|Permission denied \(publickey'
}

check_agent_failure() {
    scan_category "Agent availability, timeout, or queue failure" \
        'no agent(s)? (found|available)|waiting for an available agent|agent.*(offline|unavailable|not found)|timed out|timeout exceeded|job was canceled due to timeout|queue.*(timed out|failed)|The operation was canceled'
}

check_terraform_failure() {
    scan_category "Terraform infrastructure or provisioning failure" \
        '^Error: |terraform (init|plan|apply|validate).*(failed|error)|Error acquiring the state lock|Provider produced|Error: creating|Error: deleting|InvalidTemplateDeployment|DeploymentFailed|ResourceNotFound'
}

check_ansible_nginx_failure() {
    scan_category "Ansible, Nginx, or application deployment failure" \
        'fatal: \[|PLAY RECAP.*failed=[1-9]|UNREACHABLE!|nginx: \[emerg\]|nginx.*(failed|error)|Failed to start|systemctl.*failed|ansible.*ERROR|deploy.*failed'
}

# Runs last. Applies only when the run failed and no known category matched.
check_unclassified_failure() {
    if [[ "${CURRENT_RUN_RESULT}" == "failed" && "${CURRENT_MATCHES}" -eq 0 ]]; then
        add_result "FAIL" "${CURRENT_PIPELINE_LABEL}" "Unclassified Pipeline Failure" \
            "Azure DevOps reports the run failed but no known failure pattern matched. Review the sanitized log manually."
    fi
}

# Ordered list of check functions, executed in order by the loop below.
CHECK_FUNCTIONS=(
    check_dependency_failure
    check_build_failure
    check_test_failure
    check_auth_failure
    check_agent_failure
    check_terraform_failure
    check_ansible_nginx_failure
    check_unclassified_failure
)

run_classification() {
    local fn
    CURRENT_MATCHES=0
    for fn in "${CHECK_FUNCTIONS[@]}"; do
        "${fn}"
    done
}

# ---------------------------------------------------------------------------
# Per-pipeline workflow
# ---------------------------------------------------------------------------
# process_pipeline LABEL PIPELINE_ID LOG_FILE
process_pipeline() {
    CURRENT_PIPELINE_LABEL="$1"
    CURRENT_PIPELINE_ID="$2"
    CURRENT_LOG_FILE="$3"
    CURRENT_RUN_RESULT=""

    local name latest completed
    local latest_id latest_state latest_result latest_branch latest_queued
    local comp_id comp_number comp_state comp_result comp_branch comp_finish comp_number_str
    local state_level state_detail

    # 1. Pipeline name (metadata)
    if ! name="$(fetch_pipeline_name)"; then
        api_fail_pipeline "Pipeline metadata" "Could not read pipeline ${CURRENT_PIPELINE_ID}."
        PIPELINE_SUMMARIES+=("${CURRENT_PIPELINE_LABEL}|ID ${CURRENT_PIPELINE_ID}|ERROR: metadata unavailable")
        return 0
    fi

    # 2. Latest run of any state
    if ! latest="$(fetch_latest_run)"; then
        api_fail_pipeline "Latest run lookup" "API call failed for pipeline ${CURRENT_PIPELINE_ID}."
        PIPELINE_SUMMARIES+=("${CURRENT_PIPELINE_LABEL}|${name}|ERROR: run lookup failed")
        return 0
    fi

    # 3. Latest completed run
    if ! completed="$(fetch_latest_completed_run)"; then
        api_fail_pipeline "Completed run lookup" "API call failed for pipeline ${CURRENT_PIPELINE_ID}."
        PIPELINE_SUMMARIES+=("${CURRENT_PIPELINE_LABEL}|${name}|ERROR: completed-run lookup failed")
        return 0
    fi

    latest_id="" ; latest_state="" ; latest_result="" ; latest_branch="" ; latest_queued=""
    if [[ -n "${latest}" ]]; then
        latest_id="$(jq -r '.id // "unknown"' <<< "${latest}")"
        latest_state="$(jq -r '.status // "unknown"' <<< "${latest}")"
        latest_result="$(jq -r '.result // "none"' <<< "${latest}")"
        latest_branch="$(jq -r '.sourceBranch // "unknown"' <<< "${latest}")"
        latest_queued="$(jq -r '.queueTime // "unknown"' <<< "${latest}")"
    fi

    if [[ -z "${completed}" ]]; then
        add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run state" \
            "${name} (ID ${CURRENT_PIPELINE_ID}): no completed run found. Latest run ${latest_id:-none} is '${latest_state:-none}'."
        PIPELINE_SUMMARIES+=("${CURRENT_PIPELINE_LABEL}|${name}|ID ${CURRENT_PIPELINE_ID}|NO COMPLETED RUN|latest run: ${latest_id:-none} (${latest_state:-none})")
        return 0
    fi

    comp_id="$(jq -r '.id // "unknown"' <<< "${completed}")"
    comp_number="$(jq -r '.buildNumber // "unknown"' <<< "${completed}")"
    comp_state="$(jq -r '.status // "unknown"' <<< "${completed}")"
    comp_result="$(jq -r '.result // "none"' <<< "${completed}")"
    comp_branch="$(jq -r '.sourceBranch // "unknown"' <<< "${completed}")"
    comp_finish="$(jq -r '.finishTime // "unknown"' <<< "${completed}")"
    comp_number_str="${comp_number}"

    # Record the metadata block for the report.
    PIPELINE_SUMMARIES+=("${CURRENT_PIPELINE_LABEL}|${name}|ID ${CURRENT_PIPELINE_ID}|Run ID ${comp_id} (${comp_number_str})|Branch ${comp_branch}|Status ${comp_state}|Result ${comp_result}|Completed ${comp_finish}")

    # 4. Map the latest run state to a health level. Queued/running runs are
    #    never reported as healthy, because their final result is not known.
    if [[ -n "${latest_id}" && "${latest_id}" != "${comp_id}" ]]; then
        if [[ "${latest_state}" != "completed" ]]; then
            add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run state" \
                "${name}: newer run ${latest_id} is '${latest_state}' (queued ${latest_queued}); its result is not yet known."
        fi
    fi

    case "${comp_state}" in
        completed)
            case "${comp_result}" in
                succeeded)
                    add_result "PASS" "${CURRENT_PIPELINE_LABEL}" "Run result" \
                        "${name}: run ${comp_id} succeeded." ;;
                partiallySucceeded)
                    add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run result" \
                        "${name}: run ${comp_id} partially succeeded." ;;
                canceled)
                    add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run result" \
                        "${name}: run ${comp_id} was canceled." ;;
                failed)
                    add_result "FAIL" "${CURRENT_PIPELINE_LABEL}" "Run result" \
                        "${name}: run ${comp_id} failed." ;;
                *)
                    add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run result" \
                        "${name}: run ${comp_id} completed with unrecognized result '${comp_result}'." ;;
            esac ;;
        notStarted|inProgress|cancelling|postponed|all)
            add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run state" \
                "${name}: run ${comp_id} is '${comp_state}'; final result not yet known." ;;
        *)
            add_result "WARN" "${CURRENT_PIPELINE_LABEL}" "Run state" \
                "${name}: run ${comp_id} has unrecognized status '${comp_state}'." ;;
    esac

    CURRENT_RUN_RESULT="${comp_result}"

    # 5. Logs and classification. Only failed runs are classified, and the
    #    classification uses the sanitized log of the latest completed run.
    if ! download_run_log "${comp_id}" "${CURRENT_LOG_FILE}"; then
        add_result "ERROR" "${CURRENT_PIPELINE_LABEL}" "Log retrieval" \
            "Could not download step logs for run ${comp_id}."
        return 0
    fi
    add_result "PASS" "${CURRENT_PIPELINE_LABEL}" "Log retrieval" \
        "Sanitized step logs for run ${comp_id} saved to $(basename -- "${CURRENT_LOG_FILE}")."

    if [[ "${comp_result}" == "failed" ]]; then
        run_classification
    fi
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
compute_overall_health() {
    local entry level pass=0 warn=0 fail=0 error=0
    for entry in "${RESULTS[@]}"; do
        level="${entry%%|*}"
        case "${level}" in
            PASS)  pass=$((pass + 1)) ;;
            WARN)  warn=$((warn + 1)) ;;
            FAIL)  fail=$((fail + 1)) ;;
            ERROR) error=$((error + 1)) ;;
        esac
    done
    SUMMARY_PASS=${pass}; SUMMARY_WARN=${warn}; SUMMARY_FAIL=${fail}; SUMMARY_ERROR=${error}

    if (( error > 0 )); then
        OVERALL_HEALTH="UNKNOWN - ERROR (configuration, authentication, API, or log retrieval; health not confirmed)"
    elif (( fail > 0 )); then
        OVERALL_HEALTH="UNHEALTHY - one or more pipeline failures"
    elif (( warn > 0 )); then
        OVERALL_HEALTH="WARNING - incomplete or non-successful state"
    else
        OVERALL_HEALTH="HEALTHY - both latest completed runs succeeded"
    fi
}

exit_code_for_health() {
    if (( SUMMARY_ERROR > 0 )); then
        return 3
    elif (( SUMMARY_FAIL > 0 )); then
        return 2
    elif (( SUMMARY_WARN > 0 )); then
        return 1
    fi
    return 0
}

write_report() {
    local tmp_report="${REPORT_FILE}.tmp"
    local entry summary level pipeline check detail rest

    {
        printf 'EpicBook CI/CD Pipeline Health Report\n'
        printf '=====================================\n'
        printf 'Prepared by:    %s\n' "${FULL_NAME}"
        printf 'Generated (UTC): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
        printf 'Organization:   %s\n' "${ORG_URL}"
        printf 'Project:        %s\n' "${PROJECT}"
        printf '\n'
        printf 'OVERALL HEALTH: %s\n' "${OVERALL_HEALTH}"
        printf '\n'

        printf 'Pipeline Run Metadata\n'
        printf -- '---------------------\n'
        for summary in "${PIPELINE_SUMMARIES[@]}"; do
            printf '%s\n' "${summary//|/ | }"
        done
        printf '\n'

        printf 'Checks\n'
        printf -- '------\n'
        for entry in "${RESULTS[@]}"; do
            # Split on the first three '|' separators only; the detail may span lines.
            level="${entry%%|*}"
            rest="${entry#*|}"
            pipeline="${rest%%|*}"
            rest="${rest#*|}"
            check="${rest%%|*}"
            detail="${rest#*|}"
            printf '[%s] %s — %s\n' "${level}" "${pipeline}" "${check}"
            printf '%s\n' "${detail}" | sed 's/^/    /'
        done
        printf '\n'

        printf 'Summary\n'
        printf -- '-------\n'
        printf 'PASS:  %d\n' "${SUMMARY_PASS}"
        printf 'WARN:  %d\n' "${SUMMARY_WARN}"
        printf 'FAIL:  %d\n' "${SUMMARY_FAIL}"
        printf 'ERROR: %d\n' "${SUMMARY_ERROR}"
        printf '\n'
        printf 'Exit codes: 0 healthy | 1 warning/incomplete | 2 failure | 3 config/auth/API/log error\n'
        printf 'Note: This report is read-only triage output. No recovery action has been applied.\n'
    } > "${tmp_report}"

    mv -f -- "${tmp_report}" "${REPORT_FILE}"
    log_info "Report written: ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_dependencies
    check_config
    prepare_report_dir
    acquire_token

    local pipeline_spec label id log_file
    local -a PIPELINES=(
        "Infrastructure|${INFRA_PIPELINE_ID}|${INFRA_LOG_FILE}"
        "Application|${APP_PIPELINE_ID}|${APP_LOG_FILE}"
    )

    for pipeline_spec in "${PIPELINES[@]}"; do
        IFS='|' read -r label id log_file <<< "${pipeline_spec}"
        log_info "Triaging ${label} pipeline (ID ${id})..."
        process_pipeline "${label}" "${id}" "${log_file}"
    done

    compute_overall_health
    write_report

    log_info "Overall: ${OVERALL_HEALTH}"
    log_info "Totals: PASS=${SUMMARY_PASS} WARN=${SUMMARY_WARN} FAIL=${SUMMARY_FAIL} ERROR=${SUMMARY_ERROR}"

    exit_code_for_health
    exit $?
}

# Run main only when executed directly, not when sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
