#!/usr/bin/env bash
# scripts/tests/test-makefile-vso-jwt-auth-validation.sh
#
# Static validation for the Makefile's JWT/OIDC auth setup flow (see
# docs/vso-jwt-oidc-auth-plan.md Phase 8,
# tasks/vso-jwt-oidc-auth/07-update-make-targets-and-setup-flow.md):
#   - `make help` lists a `configure-vso-jwt-auth` target with a JWT/OIDC
#     description.
#   - `configure-vso-jwt-auth` is declared .PHONY and runs
#     scripts/configure-vso-jwt-auth.sh.
#   - `configure-vso-auth` remains usable (declared, in .PHONY) as a
#     compatibility alias that depends on/calls configure-vso-jwt-auth.
#   - `setup` invokes scripts/configure-vso-jwt-auth.sh (and does so before
#     scripts/apply-vso-demo.sh).
#   - No target reachable from the default `setup` sequence invokes
#     scripts/configure-vso-kubernetes-auth.sh.
#
# This never runs `make` against a live cluster -- it only inspects the
# Makefile's text and `make help`/`make -n setup` output.
#
# Usage: scripts/tests/test-makefile-vso-jwt-auth-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MAKEFILE="${REPO_ROOT}/Makefile"

pass=0
fail=0

check() {
  local desc="$1" cond="$2"
  if [ "$cond" -eq 0 ]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

# 1. Makefile exists.
check "Makefile exists" $([ -f "$MAKEFILE" ]; echo $?)

# 2. configure-vso-jwt-auth is declared in .PHONY.
grep -qE '^\.PHONY:.*\bconfigure-vso-jwt-auth\b' "$MAKEFILE"
check ".PHONY declares configure-vso-jwt-auth" $?

# 3. configure-vso-auth is still declared in .PHONY (compatibility entry point).
grep -qE '^\.PHONY:.*\bconfigure-vso-auth\b' "$MAKEFILE"
check ".PHONY still declares configure-vso-auth" $?

# 4. configure-vso-jwt-auth target runs scripts/configure-vso-jwt-auth.sh.
awk '/^configure-vso-jwt-auth:/{found=1} found && /scripts\/configure-vso-jwt-auth\.sh/{print; exit}' "$MAKEFILE" \
  | grep -q 'scripts/configure-vso-jwt-auth.sh'
check "configure-vso-jwt-auth target runs scripts/configure-vso-jwt-auth.sh" $?

# 5. configure-vso-auth depends on (or otherwise calls) configure-vso-jwt-auth.
grep -qE '^configure-vso-auth:.*configure-vso-jwt-auth' "$MAKEFILE"
check "configure-vso-auth depends on configure-vso-jwt-auth" $?

# 6. configure-vso-jwt-auth has a JWT/OIDC-flavored ## description.
grep -qE '^configure-vso-jwt-auth:.*## .*(JWT|OIDC)' "$MAKEFILE"
check "configure-vso-jwt-auth has a JWT/OIDC description" $?

grep -qE '^configure-vso-jwt-auth:.*## .*OIDC discovery.*advertised JWKS' "$MAKEFILE"
check "configure-vso-jwt-auth description names discovery and advertised JWKS" $?

grep -qF 'VSO_API_ADDR ?= https://$(TWO_CLUSTER_HOST):$(VSO_API_HOST_PORT)' "$MAKEFILE"
check "VSO_API_ADDR derives from the same host/port rendered into kind" $?

# 7. setup target's recipe invokes scripts/configure-vso-jwt-auth.sh.
setup_recipe=$(awk '/^setup:/{flag=1; next} /^[a-zA-Z_-]+:/{flag=0} flag' "$MAKEFILE")
echo "$setup_recipe" | grep -q 'scripts/configure-vso-jwt-auth.sh'
check "setup recipe invokes scripts/configure-vso-jwt-auth.sh" $?

# 8. setup does NOT invoke scripts/configure-vso-kubernetes-auth.sh.
if echo "$setup_recipe" | grep -q 'scripts/configure-vso-kubernetes-auth.sh'; then
  check "setup recipe does not invoke scripts/configure-vso-kubernetes-auth.sh" 1
else
  check "setup recipe does not invoke scripts/configure-vso-kubernetes-auth.sh" 0
fi

# 9. setup calls configure-vso-jwt-auth.sh before apply-vso-demo.sh.
jwt_line=$(echo "$setup_recipe" | grep -n 'scripts/configure-vso-jwt-auth.sh' | head -1 | cut -d: -f1)
apply_line=$(echo "$setup_recipe" | grep -n 'scripts/apply-vso-demo.sh' | head -1 | cut -d: -f1)
if [ -n "$jwt_line" ] && [ -n "$apply_line" ] && [ "$jwt_line" -lt "$apply_line" ]; then
  check "setup runs configure-vso-jwt-auth.sh before apply-vso-demo.sh" 0
else
  check "setup runs configure-vso-jwt-auth.sh before apply-vso-demo.sh" 1
fi

# 10. No target's recipe reachable from the default 'setup' sequence
#     (create-clusters, setup-vault-cluster, setup-vso-cluster,
#     configure-vso-jwt-auth, apply-vso-demo) calls
#     scripts/configure-vso-kubernetes-auth.sh. (configure-vso-kubernetes-auth.sh
#     itself is not invoked by any of these recipes -- verified directly
#     against the setup recipe body in check 8; this check additionally
#     confirms no other setup-reachable script wraps it.)
invocation_hits=$(grep -nE 'configure-vso-kubernetes-auth\.sh' \
     "${REPO_ROOT}/scripts/create-clusters.sh" \
     "${REPO_ROOT}/scripts/setup-vault-cluster.sh" \
     "${REPO_ROOT}/scripts/setup-vso-cluster.sh" \
     "${REPO_ROOT}/scripts/configure-vso-jwt-auth.sh" \
     "${REPO_ROOT}/scripts/apply-vso-demo.sh" 2>/dev/null \
   | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -n "$invocation_hits" ]; then
  check "no setup-reachable script invokes scripts/configure-vso-kubernetes-auth.sh" 1
else
  check "no setup-reachable script invokes scripts/configure-vso-kubernetes-auth.sh" 0
fi

# 11. `make help` output lists configure-vso-jwt-auth with a JWT/OIDC
#     description.
if command -v make >/dev/null 2>&1; then
  help_out=$(cd "$REPO_ROOT" && make help 2>&1)
  echo "$help_out" | grep -qE 'configure-vso-jwt-auth.*(JWT|OIDC)'
  check "make help lists configure-vso-jwt-auth with a JWT/OIDC description" $?

  # 12. `make help` still lists configure-vso-auth as a compatibility entry point.
  echo "$help_out" | grep -q 'configure-vso-auth'
  check "make help still lists configure-vso-auth" $?

  # 13. `make -n setup` (dry run) shows configure-vso-jwt-auth.sh, not
  #     configure-vso-kubernetes-auth.sh.
  dryrun_out=$(cd "$REPO_ROOT" && make -n setup 2>&1)
  echo "$dryrun_out" | grep -q 'scripts/configure-vso-jwt-auth.sh'
  check "make -n setup shows scripts/configure-vso-jwt-auth.sh" $?

  if echo "$dryrun_out" | grep -q 'scripts/configure-vso-kubernetes-auth.sh'; then
    check "make -n setup does not show scripts/configure-vso-kubernetes-auth.sh" 1
  else
    check "make -n setup does not show scripts/configure-vso-kubernetes-auth.sh" 0
  fi
else
  echo "SKIP: make not found on PATH -- skipping live 'make help'/'make -n setup' checks"
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
