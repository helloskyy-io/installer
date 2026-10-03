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
# Two per-file controls, over EVERY shell file discovered in the tree:
#   - `bash -n`    — the file parses. A syntax error in a bootstrap script is
#                    discovered by the operator, on the VM, halfway through.
#   - `shellcheck` — the defect classes a parse cannot see: unquoted expansions,
#                    masked exit statuses (SC2155), unreachable conditions.
#
# Four guard checks on the apt/dpkg lock handling, which is what a fresh VM's
# first boot races (apt-daily / unattended-upgrades hold the lock). The list of
# lock-taking commands is kept in one place, the comment on raw_apt_report:
#   - drift check       — the two verbatim `apt_get` copies are identical.
#   - status guard      — every `apt_get` call checks the status it returns.
#   - raw-lock guard    — nothing but the wrapper takes the lock directly,
#                         because a raw call waits for nothing.
#   - guard self-test   — fixtures the two guards must flag or pass, so a guard
#                         edited into silence fails.
#
# DISCOVERY IS THE WHOLE TREE and the trigger must not be narrower (Testing
# Standard § "A gate's trigger MUST NOT be narrower than its runner's
# discovery") — the CI workflow that invokes this carries no `paths:` filter.
#
# An empty discovery FAILS. A runner that finds nothing exits 0 and is
# indistinguishable from one that checked everything and found it clean, which
# is the "gate that skips a tier MUST fail loudly" clause.
#
# Exit 0 = every discovered file passed both per-file controls AND every guard
# check passed; 1 = at least one of either failed, or the tree/toolchain was not
# in a state where the controls could run. The last line counts guard failures
# and file failures separately, so it says which kind a red run was.
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

GUARD_FAILED=0
FILE_FAILED=0

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
    GUARD_FAILED=$((GUARD_FAILED + 1))
elif [[ "${sc_block}" != "${im_block}" ]]; then
    echo "FAIL apt_get drift check: the copies in skyy-command/ and image-manager/ bootstrap.sh differ"
    diff <(echo "${sc_block}") <(echo "${im_block}") | sed 's/^/       /' || true
    GUARD_FAILED=$((GUARD_FAILED + 1))
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
# The two guards are functions, not inline loops, so the fixture self-test below
# runs the SAME code the real files are judged by. A guard nothing exercises
# can be edited into permanent silence and the suite stays green.
apt_status_report() {
    awk '
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
        }' "$1"
}

# Nothing but the wrapper may take the apt/dpkg lock directly: a raw call skips
# the lock wait and the status guard alike. THE LIST OF LOCK-TAKERS LIVES HERE
# and nowhere else: `apt`, `apt-get`, `aptitude`, `dpkg-reconfigure` always;
# `add-apt-repository` / `apt-add-repository` unless given `-n`/`--no-update`
# (or if given `-u`/`--update`, which updates anyway); `dpkg` unless its
# arguments contain a read-only action (--print-architecture, -s, -l, -L, -S,
# -p, --get-selections, --compare-versions, --version, --help, --assert-*), so
# `dpkg "$@"`, a bundled `-iE`, or an unlisted mutating action is flagged.
# Limit: a lock-taking command not named here is not flagged. `apt`/`apt-get` is flagged as a command word
# ANYWHERE on a non-comment line — after `if`, `then`, `timeout N`, `command`,
# `sudo`, `$(`, or behind an absolute path — not only at line start. Quoted
# text is dropped ONLY on a log line (`log_*`, `echo`, `printf` — their
# messages say "the apt lock"), and even there a double-quoted string holding
# `$(` or a backtick is kept because it can run a command. Everywhere else
# quotes are kept, so `bash -c '…apt-get…'`, `eval "…"` and `"apt-get" update`
# are flagged. Known limits: escaped quotes inside a log message can produce a
# false flag, and `command -v apt-get` / `cd /etc/apt` are flagged too (an
# argument is not told from a command) — both fail loudly, never pass. The one
# exemption is the wrapper's own invocation, and only inside the apt_get()
# body: the same text anywhere else is still a raw call.
raw_apt_report() {
    awk '
        function strip(s,    out, seg) {
            out = ""
            while (match(s, /"[^"]*"/)) {
                seg = substr(s, RSTART, RLENGTH)
                if (seg !~ /\$\(([^(]|$)|`/) seg = ""
                out = out substr(s, 1, RSTART - 1) seg
                s = substr(s, RSTART + RLENGTH)
            }
            s = out s
            gsub(/\047[^\047]*\047/, "", s)
            sub(/[ \t]#.*/, "", s)
            return s
        }
        # A command that takes the lock only for some arguments. Every use of
        # `cmd` is flagged unless its arguments (up to the next `;`/`&`/`|`)
        # match `safe`, or when they match `bad`. An allowlist, so an argument
        # nobody listed (`"$@"`, a variable, a bundled flag) is flagged rather
        # than passed. Quotes, redirections and a trailing comment are removed
        # from the arguments first, so none of them can hide or fake a token.
        function lock_taker_by_args(t, cmd, safe, bad,    rest, seg) {
            rest = t
            while (match(rest, "(^|[^A-Za-z0-9_.-])(/[^ \t]*/)?(" cmd ")([^A-Za-z0-9_.\\/-]|$)")) {
                rest = substr(rest, RSTART + RLENGTH - 1)
                seg = rest
                gsub(/[0-9]*>&[0-9]+/, "", seg)
                gsub(/&>>?/, ">", seg)
                gsub(/["\047]/, "", seg)
                sub(/[ \t]#.*/, "", seg)
                sub(/[;&|].*/, "", seg)
                if (seg !~ safe || (bad != "" && seg ~ bad)) return 1
            }
            return 0
        }
        BEGIN { dpkg_ro = "(^|[ \t])(--print-architecture|--print-foreign-architectures|-s|--status|-l|--list|-L|--listfiles|-S|--search|-p|--print-avail|--get-selections|--compare-versions|--version|--help|--assert-[a-z-]+)([ \t=)`]|$)" }
        BEGIN { lit = "LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get \"$@\"" }
        # Backslash continuations are joined first, as apt_status_report does, so
        # a flag on the next line is seen as an argument of its command.
        { line = held $0; held = "" }
        /\\$/ { held = substr(line, 1, length(line) - 1) " "; next }
        { $0 = line }
        /^apt_get\(\)[ \t]*\{/ { inwrap = 1 }
        {
            s = $0; sub(/^[ \t]+/, "", s)
            if (s !~ /^#/) {
                if (inwrap && (p = index(s, lit)) > 0) s = substr(s, 1, p - 1) substr(s, p + length(lit))
                t = (s ~ /^(log_[a-z]+|echo|printf)[ \t]/) ? strip(s) : s
                # A trailing comment is not code: drop it so its words cannot
                # hide or fake an argument. Only when no quote precedes the `#`,
                # since `x="a #b"; apt-get` has a `#` that is not a comment.
                if (match(t, /[ \t]#/) && substr(t, 1, RSTART - 1) !~ /["\047]/) t = substr(t, 1, RSTART - 1)
                if (t ~ /(^|[^A-Za-z0-9_.-])(\/[^ \t]*\/)?(apt(-get|itude)?|dpkg-reconfigure)([^A-Za-z0-9_.\/-]|$)/ \
                    || lock_taker_by_args(t, "add-apt-repository|apt-add-repository", "(^|[ \t])(--no-update|-[a-zA-Z]*n[a-zA-Z]*)([ \t]|$)", "(^|[ \t])(--update|-[a-zA-Z]*u[a-zA-Z]*)([ \t]|$)") \
                    || lock_taker_by_args(t, "dpkg", dpkg_ro, ""))
                    print "RAW " FILENAME ":" NR ": " $0
            }
            if ($0 ~ /^}/) inwrap = 0
        }' "$1"
}

# Fixture self-test: each line is `guard|expectation|text` (`\n` = newline in
# the text). `flag` fixtures MUST be reported, `pass` fixtures MUST NOT be. A
# guard edited into silence fails the `flag` rows; one edited into flagging
# everything fails the `pass` rows.
selftest_apt_guards() {
    local fixture guard expect text file out rc=0 fixtures=0
    file="$(mktemp)"
    while IFS= read -r fixture; do
        [[ -n "${fixture}" ]] || continue
        guard="${fixture%%|*}"; fixture="${fixture#*|}"
        expect="${fixture%%|*}"; text="${fixture#*|}"
        printf '%b\n' "${text}" >"${file}"
        if [[ "${guard}" == status ]]; then
            out="$(apt_status_report "${file}" | grep '^UNCHECKED' || true)"
        else
            out="$(raw_apt_report "${file}")"
        fi
        fixtures=$((fixtures + 1))
        if [[ "${expect}" == flag && -z "${out}" ]]; then
            echo "FAIL apt guard self-test: ${guard} guard did NOT flag: ${text}"
            rc=1
        elif [[ "${expect}" == pass && -n "${out}" ]]; then
            echo "FAIL apt guard self-test: ${guard} guard wrongly flagged: ${text}"
            rc=1
        fi
    done <<'FIXTURES'
raw|flag|if apt-get update -qq; then :; fi
raw|flag|if ! apt-get update; then
raw|flag|    then apt-get update
raw|flag|timeout 60 apt-get update
raw|flag|command apt-get update
raw|flag|/usr/bin/apt-get install x
raw|flag|sudo apt install x
raw|flag|x=$(apt-get update)
raw|flag|echo "$(apt-get update)"
raw|flag|LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@" </dev/null
raw|flag|apt_get() {\n    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@" || rc=$?; apt-get update\n}
raw|pass|apt_get() {\n    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@" </dev/null || rc=$?\n}
raw|pass|log_info "waiting for the apt lock (${holder:-another apt/dpkg process})"
raw|pass|# apt-get is raw here
raw|pass|echo done # apt-get note
raw|pass|systemctl is-active apt-daily.timer
raw|flag|bash -c 'apt-get update'
raw|flag|sudo sh -c "apt-get install -y x"
raw|flag|eval "apt-get update"
raw|flag|"/usr/bin/apt-get" update
raw|flag|"apt-get" update
raw|flag|exec apt-get update
raw|flag|env X=1 apt-get update
raw|flag|a && apt-get update
raw|flag|a | apt-get update
raw|flag|(apt-get)
raw|flag|apt-get;
raw|flag|apt-get</dev/null
raw|flag|apt-get\\\n  install -y x
raw|flag|apt_get() {\n    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@" </dev/null\n}\nother() {\n    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@"\n}
raw|pass|install -m 0755 -d /etc/apt/keyrings
raw|pass|curl -fsSL x > /etc/apt/sources.list.d/docker.list
raw|flag|add-apt-repository -y universe
raw|flag|apt-add-repository -y universe
raw|flag|dpkg -i foo.deb
raw|flag|dpkg --configure -a
raw|flag|sudo dpkg --force-all --purge foo
raw|flag|if ! dpkg -r foo; then
raw|flag|dpkg-reconfigure tzdata
raw|flag|aptitude install x
raw|flag|add-apt-repository -y universe && add-apt-repository -n -y x
raw|pass|add-apt-repository -n -y universe
raw|pass|add-apt-repository -yn universe
raw|pass|add-apt-repository --no-update ppa:x/y
raw|pass|dpkg --print-architecture
raw|pass|if dpkg -s qemu-guest-agent >/dev/null 2>&1; then
raw|pass|arch=$(dpkg --print-architecture)
raw|pass|dpkg-query -W git
raw|flag|add-apt-repository -y universe  # -n would skip the update
raw|pass|dpkg -s x  # never dpkg -i
raw|flag|dpkg --force-confold \\\n    -i foo.deb
raw|flag|add-apt-repository -y \\\n    ppa:x/y
raw|pass|add-apt-repository -y \\\n    -n ppa:x/y
raw|flag|dpkg "$@"
raw|flag|dpkg $flags foo.deb
raw|flag|dpkg -iE foo.deb
raw|flag|dpkg --set-selections
raw|flag|dpkg --update-avail x
raw|pass|add-apt-repository 2>&1 -n x
raw|flag|x="a #b"; apt-get update
raw|flag|dpkg "-i" foo.deb
raw|flag|dpkg 2>&1 -i foo.deb
raw|flag|dpkg --unpack foo.deb
raw|flag|dpkg -P foo
raw|flag|dpkg --triggers-only foo
raw|flag|dpkg --add-architecture i386
raw|pass|dpkg -s x 2>&1 | grep -q installed
raw|pass|dpkg --compare-versions 1 lt 2
raw|flag|dpkg -s x && dpkg -i y
raw|flag|sudo add-apt-repository -y universe
raw|flag|apt-add-repository --update x
raw|flag|add-apt-repository -n -u x
raw|pass|apt-add-repository -n x
raw|pass|add-apt-repository "-n" x
raw|flag|add-apt-repository -y universe; foo -n
raw|pass|log_info "dpkg -i is not run here"
raw|pass|test -e /var/lib/dpkg/lock-frontend
raw|pass|apt-cache policy git
raw|pass|log_info "Waiting ($((SECONDS - started))s of ${APT_LOCK_TIMEOUT}s) for the apt lock"
raw|pass|apt_get update || return 1
status|flag|apt_get update
status|flag|apt_get update || true
status|flag|if x; then apt_get update; fi
status|pass|apt_get update || return 1
status|pass|{ apt_get update && apt_get install -y acl; } || { log_error x; return 1; }
status|pass|if ! apt_get update; then
status|pass|apt_get install -y \\\n    acl || return 1
status|pass|while ! apt_get update; do
status|pass|apt_get update || exit 1
status|flag|apt_get install -y \\\n    acl || true
FIXTURES
    rm -f "${file}"
    if [[ ${rc} -eq 0 ]]; then
        echo "PASS apt guard self-test (${fixtures} fixtures)"
    else
        GUARD_FAILED=$((GUARD_FAILED + 1))
    fi
}
selftest_apt_guards

# Both guards run over every shell script the suite lints, except this runner
# itself — it holds the guards' own fixtures, which are apt calls by design. Any
# OTHER script under testing/ is judged like the installers. A
# new installer script that calls apt directly is judged without being listed.
apt_calls=0
apt_unchecked=0
raw_found=0
raw_files=0
for script in "${SCRIPTS[@]}"; do
    f="${script#./}"
    [[ "${f}" == testing/run-all.sh ]] && continue
    raw_files=$((raw_files + 1))
    report="$(apt_status_report "${f}")"
    apt_calls=$((apt_calls + $(grep -c '^CALL' <<<"${report}" || true)))
    while IFS= read -r u; do
        [[ -n "${u}" ]] || continue
        echo "FAIL apt_get status unchecked: ${u#UNCHECKED }"
        apt_unchecked=$((apt_unchecked + 1))
    done < <(grep '^UNCHECKED' <<<"${report}" || true)
    while IFS= read -r r; do
        [[ -n "${r}" ]] || continue
        echo "FAIL raw lock-taking call outside apt_get (list: raw_apt_report; or the wrapper line no longer matches the exemption literal): ${r#RAW }"
        raw_found=$((raw_found + 1))
    done < <(raw_apt_report "${f}")
done
if [[ ${raw_files} -eq 0 ]]; then
    echo "FAIL raw lock-taking check: scanned no files — the guard is reading nothing"
    GUARD_FAILED=$((GUARD_FAILED + 1))
elif [[ ${raw_found} -gt 0 ]]; then
    GUARD_FAILED=$((GUARD_FAILED + 1))
else
    echo "PASS no raw lock-taking apt/dpkg call outside apt_get (${raw_files} file(s) scanned)"
fi
if [[ ${apt_calls} -eq 0 ]]; then
    echo "FAIL apt_get status check: found no apt_get call statements — the guard is reading nothing"
    GUARD_FAILED=$((GUARD_FAILED + 1))
elif [[ ${apt_unchecked} -gt 0 ]]; then
    GUARD_FAILED=$((GUARD_FAILED + 1))
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
        FILE_FAILED=$((FILE_FAILED + 1))
    fi
    rm -f "${syntax_log}" "${lint_log}"
done

echo "-----------------------------------------------------------------"
if [[ ${GUARD_FAILED} -eq 0 && ${FILE_FAILED} -eq 0 ]]; then
    echo "OK: all ${#SCRIPTS[@]} shell file(s) passed bash -n and shellcheck, and every guard check passed"
    exit 0
fi
# Guard failures and file failures are counted apart: a red run caused only by
# a guard must not say a shell file failed lint, or triage starts in the wrong
# place. Each failing check printed its own FAIL line above.
echo "FAILED: ${GUARD_FAILED} guard check(s), ${FILE_FAILED} of ${#SCRIPTS[@]} shell file(s)"
exit 1
