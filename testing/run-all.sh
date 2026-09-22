#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Master test runner for the installer repo.
#
# This repo ships executable shell that runs as root on a fresh VM, pastes an
# owner-issued GitHub token into a cluster Secret, and clones the platform. It
# had NO automated gate until this file existed: every check was a human
# remembering to run one, which the Testing Standard § "Why local-only
# enforcement does not satisfy this" calls a convention rather than a control.
#
# Two controls, both over EVERY shell file discovered in the tree:
#   - `bash -n`    — the file parses. A syntax error in a bootstrap script is
#                    discovered by the operator, on the VM, halfway through.
#   - `shellcheck` — the defect classes a parse cannot see: unquoted expansions,
#                    masked exit statuses (SC2155), unreachable conditions.
#
# DISCOVERY IS THE WHOLE TREE and the trigger must not be narrower (Testing
# Standard § "A gate's trigger MUST NOT be narrower than its runner's
# discovery") — the CI workflow that invokes this carries no `paths:` filter.
#
# An empty discovery FAILS. A runner that finds nothing exits 0 and is
# indistinguishable from one that checked everything and found it clean, which
# is the "gate that skips a tier MUST fail loudly" clause.
#
# Exit 0 = every discovered file passed both controls; 1 = at least one failed,
# or the tree/toolchain was not in a state where the controls could run.
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# The toolchain is a precondition, not an optional extra. A missing shellcheck
# must stop the run: skipping it would report green having run half the gate.
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "FATAL: shellcheck is not installed — half of this gate cannot run."
    echo "       Install it (apt-get install shellcheck) and re-run; do NOT"
    echo "       skip it, a partial gate reports green on what it never read."
    exit 1
fi

# `.git` holds no source; `.claude/worktrees` holds CHECKOUTS OF OTHER BRANCHES
# that workflow dispatches leave behind — linting those would judge this branch
# by code that is not on it.
mapfile -t SCRIPTS < <(
    find . -type f -name '*.sh' \
        -not -path './.git/*' \
        -not -path './.claude/*' \
    | sort
)

# The assertion is on the BOOTSTRAP SCRIPTS, not on a non-zero total. A total
# can never reach zero — this runner is itself a `*.sh` inside the tree it
# searches, so `${#SCRIPTS[@]} -eq 0` is a branch that cannot execute, and a
# guard that cannot fire reads exactly like one that is passing. What can
# genuinely break is discovery silently stopping at the runner: a renamed
# directory, a `find` predicate that stops matching, a repo checked out flat.
# Then the gate reports "all 1 file(s) passed" over an installer it never read.
bootstraps=0
for s in "${SCRIPTS[@]}"; do
    [[ "${s}" == */bootstrap.sh ]] && bootstraps=$((bootstraps + 1))
done
if [[ ${bootstraps} -eq 0 ]]; then
    echo "FATAL: discovered ${#SCRIPTS[@]} shell file(s) and NOT ONE bootstrap.sh."
    echo "       This repo exists to ship installer bootstrap scripts. Finding"
    echo "       none of them means discovery is broken, not that the tree is"
    echo "       clean. Refusing to report green over an unread installer."
    exit 1
fi

echo "installer test run — ${#SCRIPTS[@]} shell file(s) discovered"
echo "-----------------------------------------------------------------"

FAILED=0
for script in "${SCRIPTS[@]}"; do
    rel="${script#./}"
    # Each control is measured on its own, so a report names WHICH one failed.
    # Neither is placed upstream of a pipe: a pipeline exits with its LAST
    # command's status, which would turn every failure here into a pass.
    syntax_log="$(mktemp)"
    lint_log="$(mktemp)"
    syntax_rc=0
    lint_rc=0
    bash -n "${script}" >"${syntax_log}" 2>&1 || syntax_rc=$?
    shellcheck "${script}" >"${lint_log}" 2>&1 || lint_rc=$?

    if [[ ${syntax_rc} -eq 0 && ${lint_rc} -eq 0 ]]; then
        echo "PASS ${rel}"
    else
        [[ ${syntax_rc} -ne 0 ]] && { echo "FAIL ${rel}: bash -n (exit ${syntax_rc})"; sed 's/^/       /' "${syntax_log}"; }
        [[ ${lint_rc} -ne 0 ]] && { echo "FAIL ${rel}: shellcheck (exit ${lint_rc})"; sed 's/^/       /' "${lint_log}"; }
        FAILED=$((FAILED + 1))
    fi
    rm -f "${syntax_log}" "${lint_log}"
done

echo "-----------------------------------------------------------------"
if [[ ${FAILED} -eq 0 ]]; then
    echo "OK: all ${#SCRIPTS[@]} shell file(s) passed bash -n and shellcheck"
    exit 0
fi
echo "FAILED: ${FAILED} of ${#SCRIPTS[@]} shell file(s)"
exit 1
