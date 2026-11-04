---
name: pipeline-triage
description: Read-only triage of the EpicBook Infrastructure and Application Azure DevOps pipelines. Runs the approved triage script once, analyzes the generated health report and sanitized logs, and recommends one human action. Never edits files, triggers, retries, cancels, or approves pipelines, and never reads or reveals secrets.
disable-model-invocation: true
allowed-tools: Bash(./pipeline-triage.sh), Read, Grep, Glob
---

# Pipeline Triage

Use this skill only when the user runs `/pipeline-triage`. It gathers the latest pipeline evidence, analyzes it, and recommends one recovery action for a human to review and apply. It does not apply any fix.

## Step 0: Read the project rules

Before doing anything else, read `CLAUDE.md` in the assignment root and follow it. Its safety rules apply to every step below.

## Step 1: Gather

Run the triage script exactly once, from the assignment root:

```
week-10/assignment-05-pipeline-triage/pipeline-triage.sh
```

Do not pass arguments. The script authenticates to Azure DevOps with the PAT in `AZURE_DEVOPS_EXT_PAT`, read internally by the script. Never read, print, or refer to the PAT's value. Do not run the script again unless the user asks for a re-run after a human has applied a fix. Record the exit code:

| Exit code | Meaning |
|---|---|
| 0 | Both latest completed runs succeeded |
| 1 | Warning or incomplete state (queued, running, partially succeeded, canceled, or no completed run) |
| 2 | One or more pipeline failures detected |
| 3 | Configuration, authentication, API, or log-retrieval error. Health is not confirmed. |

## Step 2: Analyze

1. Read `reports/pipeline-health-report.txt`. It is the primary evidence source.
2. For any warning or failure, look for the matching lines in `reports/infra-last-run.log` or `reports/app-last-run.log` with `Grep`. Use the search only to confirm the report's evidence. Quote only sanitized lines.
3. Do not read or search any file outside `reports/` and `CLAUDE.md`. Do not read or search `.claude/settings*`, `.env` files, or any file that could contain credentials.
4. If a log line contains `[REDACTED`, say the line was redacted. Do not try to reconstruct the value.

## Step 3: Report

Use these headings in this order. For a healthy baseline, keep every heading and state "None" where it applies.

1. **Overall status:** HEALTHY, WARNING, UNHEALTHY, or UNKNOWN (exit 3), with the exit code.
2. **Affected pipeline:** Infrastructure, Application, or both, with the pipeline ID.
3. **Run ID:** the completed run ID from the report for each pipeline.
4. **Warning or failure checks:** every WARN, FAIL, or ERROR line in the report. Write "None" if there are none.
5. **Failure category:** the category from the report. Write "None" if there is no failure. Use "Unclassified Pipeline Failure" when the report says so.
6. **Exact sanitized evidence:** the report or log lines, quoted exactly, with secrets already redacted.
7. **Likely cause:** one explanation supported by the evidence. If the evidence is incomplete, write "Root cause not confirmed" and say what is missing.
8. **Recommended human action:** one specific action for the engineer to review and apply manually. Write "No fix required" when both pipelines are healthy. For an authentication error (HTTP 302 or 401, or "Authentication error" in the report), recommend that the engineer check that the PAT in `AZURE_DEVOPS_EXT_PAT` is valid and unexpired, and that its owner is a member of the organization with read access to the project and pipelines. Do not ask for the PAT or its value.
9. **Verification step:** one step the engineer runs after applying the fix, which is normally a re-run of `/pipeline-triage`.

For a healthy baseline (both pipelines succeeded, exit 0), state plainly that both pipelines are healthy and that no fix is required.

## Guardrails

- Never edit, create, rename, or delete any file, including reports, logs, pipeline YAML, Terraform, Ansible, and application code. The only files this skill writes are the ones the triage script writes.
- Never run any command other than `./pipeline-triage.sh`, unless the user explicitly asks for it. Do not use shell commands to inspect the environment, such as `env`, `printenv`, `set`, or `echo $VAR`.
- Never trigger, queue, retry, cancel, approve, or delete a pipeline run. Never change a Service Connection, Secure File, Variable Group, agent pool, or permission.
- Never run Terraform or Ansible. Never push, commit, or create Azure resources.
- Never read, print, store, or request a token, PAT, password, private key, authorization header, Service Connection credential, or database credential. Never ask the user to paste a secret into this session. If `AZURE_DEVOPS_EXT_PAT` is set, the script uses it internally; do not refer to its value.
- Do not claim a root cause without evidence from the report or sanitized logs.
- Recommend one fix. Do not apply it, even if the fix looks simple.
