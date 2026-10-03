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

# `apt_get` is copied word for word into both installers, because each is
# fetched alone by curl and neither can source the other. A copy nothing
# compares drifts: a fix to the lock-matching lands in one script and the other
# keeps the old behaviour. Extraction is from the APT_LOCK_TIMEOUT line to the
# function's closing brace; an empty extraction FAILS, since two empty blocks
# compare equal.
extract_apt_block() {
    awk '/^APT_LOCK_TIMEOUT=/ {on=1} on {print} on && /^}/ {exit}' "$1"
}
sc_block="$(extract_apt_block skyy-command/bootstrap.sh)"
im_block="$(extract_apt_block image-manager/bootstrap.sh)"
if [[ -z "${sc_block}" || -z "${im_block}" ]]; then
    echo "FAIL apt_get drift check: could not extract the apt_get block from both bootstrap.sh files"
    FAILED=$((FAILED + 1))
elif [[ "${sc_block}" != "${im_block}" ]]; then
    echo "FAIL apt_get drift check: the copies in skyy-command/ and image-manager/ bootstrap.sh differ"
    diff <(echo "${sc_block}") <(echo "${im_block}") | sed 's/^/       /' || true
    FAILED=$((FAILED + 1))
else
    echo "PASS apt_get copies identical (skyy-command, image-manager)"
fi

# Every apt_get call must CHECK the status it returns. `set -e` is no substitute:
# it is off for the whole body of a function called as an `if` condition, which
# is how skyy-command's main calls its tasks, so an unchecked `apt_get update`
# that gave up on the lock ran straight into a second full wait. A call is
# checked when its statement is an `if`/`while`/`until` condition, or when it is
# a `&&` chain of apt_get calls (optionally `{ …; }`-grouped) ending in
# `|| return`, `|| exit` or `|| {` — `|| true` swallows the status and fails. An
# `if` whose apt_get sits in the `then` body, not the condition, fails too.
# Backslash continuations are joined first, so a multi-line install counts as
# one statement. Zero calls found FAILS — a guard over nothing passes forever.
apt_calls=0
apt_unchecked=0
for f in skyy-command/bootstrap.sh image-manager/bootstrap.sh; do
    report="$(awk '
        { line = held $0; held = "" }
        /\\$/ { held = substr(line, 1, length(line) - 1) " "; next }
        {
            s = line; sub(/^[ \t]+/, "", s)
            if (s ~ /^#/ || s !~ /(^|[^_a-zA-Z])apt_get[ \t]/) next
            gsub(/[0-9]*>&[0-9]+/, "", s)
            print "CALL"
            if (s ~ /^(if|elif|while|until)[ \t]/ && s !~ /;[ \t]*(then|do)[ \t].*apt_get[ \t]/) next
            if (s ~ /^(\{[ \t]+)?apt_get[ \t][^;&|]*([ \t]*&&[ \t]*apt_get[ \t][^;&|]*)*(;[ \t]*\})?[ \t]*\|\|[ \t]*(return|exit|\{)/ && s !~ /\|\|.*apt_get[ \t]/) next
            print "UNCHECKED " FILENAME ":" NR ": " s
        }' "${f}")"
    apt_calls=$((apt_calls + $(grep -c '^CALL' <<<"${report}" || true)))
    while IFS= read -r u; do
        [[ -n "${u}" ]] || continue
        echo "FAIL apt_get status unchecked: ${u#UNCHECKED }"
        apt_unchecked=$((apt_unchecked + 1))
    done < <(grep '^UNCHECKED' <<<"${report}" || true)
done
# Nothing but the wrapper may call apt directly: a raw apt-get skips the lock
# wait and this guard alike. The wrapper's own call is the one allowed line.
raw_apt="$(grep -nE '(^|[;&|({]|=[^ ]*)[[:space:]]*(sudo[[:space:]]+)?apt(-get)?[[:space:]]' skyy-command/bootstrap.sh image-manager/bootstrap.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get' || true)"
if [[ -n "${raw_apt}" ]]; then
    echo "FAIL raw apt call outside apt_get:"
    echo "       ${raw_apt//$'\n'/$'\n       '}"
    FAILED=$((FAILED + 1))
fi
if [[ ${apt_calls} -eq 0 ]]; then
    echo "FAIL apt_get status check: found no apt_get call statements — the guard is reading nothing"
    FAILED=$((FAILED + 1))
elif [[ ${apt_unchecked} -gt 0 ]]; then
    FAILED=$((FAILED + 1))
else
    echo "PASS apt_get status checked at every call (${apt_calls} statement(s))"
fi
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
