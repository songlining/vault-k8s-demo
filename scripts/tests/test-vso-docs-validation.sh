#!/usr/bin/env bash
# scripts/tests/test-vso-docs-validation.sh
#
# Unit tests for customer-facing documentation and design/audit notes:
#   - No stale default auth path wording: customer-facing docs must not
#     present `auth/kubernetes-vso`, `TokenReview`, `vault-token-reviewer`,
#     or `system:auth-delegator` as the default/production VSO auth method.
#     These terms are allowed only inside explicitly-labeled
#     historical/legacy-comparison sections.
#   - Customer-facing docs state JWT/OIDC (`auth/jwt-vso`) is the default.
#   - Customer-facing docs explain no reviewer JWT is stored in Vault.
#   - Customer-facing docs explain why issuer, audience, and subject binding
#     matter.
#   - Design/plan/audit docs that still reference the old TokenReview path
#     have a prominent "superseded on auth method" note at the top.
#
# "Customer-facing" docs: docs/vso-jwt-oidc-demo.md,
# PODMAN_MIGRATION.md, vso-demo.sh, and presenterm/vso.md. These must present
# JWT/OIDC as the default.
#
# "Historical/internal" docs: docs/vso-demo-design.md,
# docs/vso-two-cluster-podman-plan.md, docs/vso-two-cluster-audit.md.
# These may still describe the old path in their body (they are design
# records), but must carry a superseded note so a reader knows the auth
# method has changed.
#
# Usage: scripts/tests/test-vso-docs-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

pass=0
fail=0

assert_pass() {
  local desc="$1"
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_fail() {
  local desc="$1"
  echo "FAIL: $desc"
  fail=$((fail + 1))
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    assert_pass "$desc"
  else
    echo "  expected to find: $needle"
    assert_fail "$desc"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  unexpectedly found: $needle"
    assert_fail "$desc"
  else
    assert_pass "$desc"
  fi
}

# --- Customer-facing docs -----------------------------------------------------
#
# docs/vso-jwt-oidc-demo.md, PODMAN_MIGRATION.md, vso-demo.sh, and
# presenterm/vso.md must present JWT/OIDC as the default VSO auth method.
# References to the old
# auth/kubernetes-vso / TokenReview / vault-token-reviewer /
# system:auth-delegator path are allowed only inside explicitly-labeled
# historical/legacy-comparison sections (identified by keywords: "legacy",
# "comparison", "previous", "older", "not run by default", "not the default",
# "not installed by default", "superseded", "historical").

CUSTOMER_DOCS=(
  "${REPO_ROOT}/docs/vso-jwt-oidc-demo.md"
  "${REPO_ROOT}/PODMAN_MIGRATION.md"
  "${REPO_ROOT}/vso-demo.sh"
  "${REPO_ROOT}/presenterm/vso.md"
)

# --- 1. Customer-facing docs state JWT/OIDC is the default -------------------

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"
  contents="$(cat "$doc")"

  # Accept either the literal 'auth/jwt-vso' or the variable form
  # 'auth/${VSO_JWT_AUTH_MOUNT}' (used by vso-demo.sh).
  if printf '%s' "$contents" | grep -qF 'auth/jwt-vso' \
     || printf '%s' "$contents" | grep -qF 'auth/${VSO_JWT_AUTH_MOUNT}'; then
    assert_pass "$doc_name references auth/jwt-vso"
  else
    echo "  expected to find: auth/jwt-vso or auth/\${VSO_JWT_AUTH_MOUNT}"
    assert_fail "$doc_name references auth/jwt-vso"
  fi

  assert_contains \
    "$doc_name references JWT/OIDC as the auth method" \
    "$contents" 'JWT/OIDC'
done

# --- 2. Customer-facing docs explain no reviewer JWT is stored --------------

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"
  contents="$(cat "$doc")"

  assert_contains \
    "$doc_name states no reviewer JWT/token_reviewer_jwt is stored in Vault" \
    "$contents" 'token_reviewer_jwt'
done

# --- 3. Customer-facing docs explain issuer/audience/subject binding --------

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"
  contents="$(cat "$doc")"

  assert_contains \
    "$doc_name explains issuer binding" \
    "$contents" 'issuer'

  assert_contains \
    "$doc_name explains audience binding" \
    "$contents" 'audience'

  assert_contains \
    "$doc_name explains subject binding" \
    "$contents" 'subject'
done

# --- 4. Customer-facing docs describe the discovery chain -------------------

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"
  contents="$(cat "$doc")"

  assert_contains "$doc_name explains OIDC discovery" "$contents" 'discovery'
  assert_contains "$doc_name explains the advertised JWKS" "$contents" 'advertised'
  assert_contains "$doc_name documents RS256 restriction" "$contents" 'RS256'
done

# --- 5. Customer-facing docs: old path terms appear only in legacy context --
#
# For each customer-facing doc, every line mentioning auth/kubernetes-vso,
# vault-token-reviewer, or system:auth-delegator must be within a legacy
# comparison context. We check that the surrounding text (the line itself
# and ~10 lines of context) contains a legacy/comparison keyword.

LEGACY_KEYWORDS='legacy|comparison|previous|older|not run by|not the default|not installed by|superseded|historical|side-by-side|not the default production|comparison path|never runs|never wired|not.*default|deliberately distinct|instead of|rather than|removes|no reviewer|purely as|self-review|auth-delegator scenario|vso-auth-delegator'

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"

  # Find lines with the stale terms, then check each has legacy context nearby.
  stale_lines=$(grep -nE 'auth/kubernetes-vso([^-]|$)|vault-token-reviewer|system:auth-delegator' "$doc" 2>/dev/null || true)

  if [ -z "$stale_lines" ]; then
    assert_pass "$doc_name has no stale default auth wording (auth/kubernetes-vso, vault-token-reviewer, system:auth-delegator) outside legacy context"
    continue
  fi

  all_in_legacy_context=true
  while IFS= read -r line_info; do
    line_num="${line_info%%:*}"
    # Grab a window of context: 10 lines before, the line itself, and 10 after.
    start=$((line_num - 10))
    [ "$start" -lt 1 ] && start=1
    end=$((line_num + 10))
    context=$(sed -n "${start},${end}p" "$doc")
    if ! echo "$context" | grep -qiE "$LEGACY_KEYWORDS"; then
      all_in_legacy_context=false
      echo "  stale term without legacy context at $doc_name:$line_num:"
      echo "$line_info" | sed 's/^/    /'
    fi
  done <<< "$stale_lines"

  if [ "$all_in_legacy_context" = "true" ]; then
    assert_pass "$doc_name only mentions old auth path in legacy/comparison context"
  else
    assert_fail "$doc_name mentions old auth path outside legacy/comparison context"
  fi
done

# --- 6. Customer-facing docs: TokenReview mentions are in comparison context -
#
# TokenReview is a legitimate term for the same-cluster auth/kubernetes path
# (used by the Agent Injector/OTel demo). But when it appears alongside VSO
# auth discussion, it must be in a "JWT/OIDC is better" or "legacy comparison"
# context, not as "VSO uses TokenReview".

for doc in "${CUSTOMER_DOCS[@]}"; do
  doc_name="$(basename "$doc")"

  # Check that no line says VSO "uses" or "authenticates via" TokenReview as
  # the current/default method. We look for TokenReview near "VSO" without a
  # negation or comparison keyword.
  # This is a heuristic: we look for lines mentioning both TokenReview and
  # VSO/jwt-vso, and verify they're in a comparison/contrast context.
  tr_vso_lines=$(grep -nE 'TokenReview' "$doc" 2>/dev/null | grep -iE 'vso|jwt-vso|jwt/oidc' || true)

  if [ -z "$tr_vso_lines" ]; then
    assert_pass "$doc_name does not describe TokenReview as the VSO auth method"
    continue
  fi

  all_qualified=true
  while IFS= read -r line_info; do
    line_num="${line_info%%:*}"
    start=$((line_num - 10))
    [ "$start" -lt 1 ] && start=1
    end=$((line_num + 10))
    context=$(sed -n "${start},${end}p" "$doc")
    # The context must either explain JWT/OIDC is the default/alternative,
    # or frame TokenReview as the old/legacy/previous approach.
    if ! echo "$context" | grep -qiE "$LEGACY_KEYWORDS|instead of|rather than|removes|no reviewer|no.*TokenReview|JWT/OIDC|jwt-vso|jwks|cryptographically|never calls back|validates.*cryptographic|signature.*claims|no TokenReview"; then
      all_qualified=false
      echo "  TokenReview-as-VSO-default at $doc_name:$line_num without contrast context:"
      echo "$line_info" | sed 's/^/    /'
    fi
  done <<< "$tr_vso_lines"

  if [ "$all_qualified" = "true" ]; then
    assert_pass "$doc_name frames TokenReview as contrast/legacy, not as VSO default"
  else
    assert_fail "$doc_name may present TokenReview as the VSO default"
  fi
done

# --- 7. Historical/internal docs have superseded auth notes ------------------
#
# docs/vso-demo-design.md, docs/vso-two-cluster-podman-plan.md, and
# docs/vso-two-cluster-audit.md are design/audit records that still describe
# the old TokenReview path in their body. Each must carry a prominent
# "superseded on auth method" note near the top so readers know the
# implementation has moved to JWT/OIDC.

HISTORICAL_DOCS=(
  "${REPO_ROOT}/docs/vso-demo-design.md"
  "${REPO_ROOT}/docs/vso-two-cluster-podman-plan.md"
  "${REPO_ROOT}/docs/vso-two-cluster-audit.md"
)

for doc in "${HISTORICAL_DOCS[@]}"; do
  doc_name="$doc"
  # Check the first 40 lines for a superseded note.
  head_contents="$(head -40 "$doc")"

  assert_contains \
    "$doc_name has a 'superseded' auth note near the top" \
    "$head_contents" 'Superseded'

  assert_contains \
    "$doc_name superseded note references JWT/OIDC" \
    "$head_contents" 'JWT/OIDC'

  assert_contains \
    "$doc_name superseded note references auth/jwt-vso" \
    "$head_contents" 'auth/jwt-vso'

  assert_contains \
    "$doc_name superseded note references vso-jwt-oidc-auth-plan" \
    "$head_contents" 'vso-jwt-oidc-auth-plan.md'
done

# --- 8. Direct-JWKS implementation records carry discovery follow-up notes ---

DISCOVERY_HISTORICAL_DOCS=(
  "${REPO_ROOT}/docs/vso-jwt-oidc-auth-spike-01.md"
  "${REPO_ROOT}/docs/vso-jwt-oidc-auth-task-02.md"
  "${REPO_ROOT}/docs/vso-jwt-oidc-auth-plan.md"
  "${REPO_ROOT}/docs/vso-jwt-oidc-auth-e2e-validation.md"
)

for doc in "${DISCOVERY_HISTORICAL_DOCS[@]}"; do
  head_contents="$(head -20 "$doc")"
  assert_contains "$doc has a historical/superseded note" "$head_contents" 'Historical'
  assert_contains "$doc links to the OIDC discovery handoff" "$head_contents" 'vso-oidc-discovery-handoff.md'
  assert_contains "$doc explains the old direct JWKS context" "$head_contents" 'jwks_url'
done

echo ""
echo "vso-docs validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
