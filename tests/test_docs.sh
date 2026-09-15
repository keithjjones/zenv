#!/bin/sh
# Step H's gate: README.md and docs/USER_GUIDE.md.
#
# The documents are tested the way the code is -- by running them. Every
# copy-pasteable block in the README is executed verbatim in the sandbox, in
# order, so a command that no longer exists, a flag that was renamed, or a step
# missing between two others fails here rather than in a reader's terminal. The
# command table is regenerated from `zenv help` and compared byte for byte,
# because a hand-maintained table drifts the first time a flag is added.
#
# One block cannot be run: the reader's own build. zenv never builds Zeek, so
# there is nothing for the suite to invoke -- it stands in for that step by
# creating an install at exactly the prefix the README names. That is the only
# kind of exemption there is, it is declared in the README itself, and it must
# carry a reason.
#
# Test-local variables are `t_`-prefixed throughout: lib.sh and bin/zenv's own
# helpers use the short `_s`/`_p`/`_d` names internally.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

. "$REPO_ROOT/tests/lib.sh"

README=$REPO_ROOT/README.md
GUIDE=$REPO_ROOT/docs/USER_GUIDE.md

# The interpreter running this file, so the README's blocks are pasted into the
# shell this pass is exercising.
_probe_shell() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        command -v zsh
    elif [ -n "${BASH_VERSION:-}" ]; then
        command -v bash
    else
        printf '/bin/sh\n'
    fi
}
PROBE_SHELL=$(_probe_shell)

# ---------------------------------------------------------------------------
# Reading the documents
# ---------------------------------------------------------------------------

# Both documents, one path per line, so a loop over them needs no word splitting
# and no assumption about the repo path.
each_doc() {
    printf '%s\n%s\n' "$README" "$GUIDE"
}

# Split the README into its fenced blocks: one file per block, plus a `.dir`
# file holding the zenv-test directive that preceded it, empty when there was
# none. One awk pass, because a directive is only a directive when it is the
# line immediately before the fence -- anything else in between and it belongs
# to the prose, not to a block.
#
# A fence that is not ```sh is recorded in `bad` rather than run: the suite can
# only promise to execute what it recognises, so an unrecognised block has to
# fail loudly instead of being skipped in silence.
docs_split() {
    awk -v dir="$1" '
        /^<!-- zenv-test:/ { pend = $0; next }
        /^```/ {
            if (inb) { close(f); inb = 0; next }
            inb = 1
            if ($0 == "```sh") {
                n++
                f = sprintf("%s/%02d.sh", dir, n)
                d = sprintf("%s/%02d.dir", dir, n)
                printf "%s\n", pend > d
                close(d)
                pend = ""
            } else {
                f = dir "/bad"
                printf "unrecognised fence: %s\n", $0 > f
            }
            next
        }
        !inb && /^[^ \t]/ { pend = "" }
        inb { print > f }
    ' "$README"
}

# The `<name>` of a `zenv-test: skip <name> -- <reason>` directive.
docs_directive_name() {
    printf '%s\n' "$1" | sed -n 's/^<!-- zenv-test: *skip  *\([^ ]*\) .*/\1/p'
}

# Every zenv-test directive in the README, one per line.
docs_directives() {
    grep '^<!-- zenv-test:' "$README" || true
}

# Every link target in a document, one per line: the `(...)` of `[text](...)`,
# every one on a line rather than only the last, which is what a greedy `.*`
# would leave.
docs_links() {
    awk '
        {
            s = $0
            while (match(s, /\]\([^)]*\)/)) {
                print substr(s, RSTART + 2, RLENGTH - 3)
                s = substr(s, RSTART + RLENGTH)
            }
        }
    ' "$1"
}

# The GitHub-style anchor of every heading in a document, one per line: lower
# case, punctuation dropped, spaces hyphenated. Fenced blocks are skipped, so a
# `# a comment` inside one cannot invent an anchor that does not exist.
docs_anchors() {
    awk '
        /^```/ { inb = !inb; next }
        !inb && /^#+[ \t]/ { sub(/^#+[ \t]+/, ""); print }
    ' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

# A document with its link targets and bare URLs removed. The no-build-advice
# rule is about what the prose tells a reader to type; an upstream citation URL
# is not a command anyone can paste, and one of the files worth citing has
# `cmake` in its path. Link *resolution* is asserted separately, on exactly the
# targets this strips.
docs_prose() {
    sed -e 's|](\([^)]*\))|](LINK)|g' -e 's|https\{0,1\}://[^ )]*||g' "$1"
}

# The README's command table, exactly as it stands in the file.
docs_table() {
    awk '
        /^\| Command \| What it does \|$/ { intab = 1; next }
        intab && /^\|---\|---\|$/ { next }
        intab && /^\|/ { print; next }
        intab { exit }
    ' "$README"
}

# The same table, generated from `zenv help`.
#
# The separator between a command and its description is two or more spaces, so
# `new <name> [--src DIR]` and `shell activate <name>` survive intact; a `|` in
# a command (`init [sh|bash|zsh]`) is escaped, or it would end the cell. The
# indented continuation lines carrying a command's flags are deliberately
# dropped -- the table is one line per command, and a separate case asserts
# every flag in the help text is documented somewhere.
docs_table_from_help() {
    zenv help 2>&1 | awk '
        /^(Inspection|Creating|Using|Housekeeping|Undoing)$/ { insec = 1; next }
        /^[A-Z]/ { insec = 0 }
        insec && /^  [a-z]/ {
            line = substr($0, 3)
            n = match(line, /  +/)
            if (n == 0) next
            cmd = substr(line, 1, n - 1)
            desc = substr(line, n + RLENGTH)
            gsub(/\|/, "\\|", cmd)
            printf "| `%s` | %s |\n", cmd, desc
        }'
}

# ---------------------------------------------------------------------------
# Running the README
# ---------------------------------------------------------------------------

# What the rc block does for a new shell, plus the checkout as the working
# directory: exactly the state a reader pasting from the README is in. A skipped
# block ends one chunk and starts another in a new process, so each chunk
# repeats it -- which is no more than opening a second terminal would do.
docs_prologue() {
    printf 'set -e\n'
    printf 'cd %s\n' "$(quote_sh "$REPO_ROOT")"
    printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac\n'
    printf 'export PATH\n'
    printf 'if command -v zenv >/dev/null 2>&1; then eval "$(zenv init sh)"; fi\n'
}

# Run the blocks accumulated so far, if any. `set -e` is in the prologue, so the
# first block that fails ends the chunk with its status.
docs_run_chunk() {
    [ -s "$1" ] || return 0
    t_script=$SANDBOX/readme-chunk.sh
    { docs_prologue; cat "$1"; } >"$t_script"
    if ! capture "$PROBE_SHELL" "$t_script"; then
        fail "a copy-pasteable README block failed"
        fail_detail "block(s): $(cat "$1")"
        fail_detail "stdout: $OUT"
        fail_detail "stderr: $ERR"
        return 1
    fi
    return 0
}

# What the suite does instead of a skipped block. There is exactly one, and
# adding another means adding a case here as well -- an unknown name fails.
docs_substitute() {
    case $1 in
        build)
            # The reader's build, which zenv neither runs nor inspects: an
            # install appearing at the prefix the README told them to use.
            mkprefix "$(zenv prefix dev)"
            ;;
        *)
            fail "unknown zenv-test substitute '$1'"
            return 1
            ;;
    esac
}

# A machine as a reader's is before they start: an rc file with a line of their
# own, a recording zkg stub on PATH, and a second environment.
#
# The second environment is the switching section's *precondition*, not a
# substitute for its block: that section is written for someone who has more
# than one environment, so the suite supplies one and the block still runs
# verbatim. It is created through the repo script, before anything is installed.
docs_setup() {
    SHELL=/bin/sh
    export SHELL
    printf 'export EDITOR=vi\n' >"$HOME/.profile"
    mkzkgstub "$SANDBOX/bin/zkg"
    zenv new default >/dev/null 2>&1 || {
        fail "could not create the environment the switching block needs"
        return 1
    }
    mkprefix "$(zenv prefix default)"
}

# Run the whole README, in order, in the sandbox. Sets T_RAN and T_SKIPPED.
# Both of the cases below need this, and a second copy of it is how the two
# would stop testing the same thing.
docs_run_readme() {
    t_dir=$SANDBOX/readme-blocks
    mkdir -p "$t_dir"
    docs_split "$t_dir"

    if [ -e "$t_dir/bad" ]; then
        fail 'every fenced block in the README must be ```sh, or it goes unrun'
        fail_detail "$(cat "$t_dir/bad")"
        return 1
    fi

    t_chunk=$t_dir/chunk
    : >"$t_chunk"
    T_RAN=0
    T_SKIPPED=0
    for t_b in "$t_dir"/[0-9][0-9].sh; do
        [ -f "$t_b" ] || continue
        t_d=$(cat "${t_b%.sh}.dir")
        case $t_d in
            '')
                cat "$t_b" >>"$t_chunk"
                T_RAN=$((T_RAN + 1))
                ;;
            *'zenv-test: skip '*)
                docs_run_chunk "$t_chunk" || return 1
                : >"$t_chunk"
                docs_substitute "$(docs_directive_name "$t_d")" || return 1
                T_SKIPPED=$((T_SKIPPED + 1))
                ;;
            *)
                fail "unknown zenv-test directive on a README block: $t_d"
                return 1
                ;;
        esac
    done
    docs_run_chunk "$t_chunk" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# The gate: the README runs
# ---------------------------------------------------------------------------

test_every_readme_block_runs_verbatim() {
    if ! command -v make >/dev/null 2>&1; then
        note 'make is not installed; the README uninstall blocks cannot run'
        return 0
    fi
    docs_setup || return 1
    docs_run_readme || return 1

    # A README whose blocks all got skipped would satisfy every assertion above
    # while testing nothing, so the counts are asserted too.
    assert_ne 0 "$T_RAN" 'the README must have blocks the suite actually runs'
    assert_eq 1 "$T_SKIPPED" 'only the reader-builds-Zeek block may be skipped'
    note "$T_RAN README blocks run, $T_SKIPPED skipped"
}

# The blocks above end with `make uninstall ARGS=--yes`, so following the README
# start to finish is itself the proof that it leaves nothing behind. Asserted
# here rather than inside the runner, because it is a claim about the document.
test_following_the_readme_end_to_end_removes_zenv_again() {
    if ! command -v make >/dev/null 2>&1; then
        note 'make is not installed; skipping'
        return 0
    fi
    docs_setup || return 1
    docs_run_readme || return 1

    assert_missing "$HOME/.local/bin/zenv" 'the script should be gone'
    assert_missing "$HOME/.local/share/bash-completion/completions/zenv"
    assert_missing "$HOME/.local/share/zsh/site-functions/_zenv"
    assert_not_contains "$(cat "$HOME/.profile")" 'zenv' \
        'and the rc block with it'
    assert_contains "$(cat "$HOME/.profile")" 'EDITOR' \
        'without disturbing the line that was already there'
    # The two environments are installs, so they stay -- that is the one
    # exception the README names out loud.
    assert_dir "$ZENV_ROOT/dev/zeek" "an install you made is kept"
}

# ---------------------------------------------------------------------------
# The command table
# ---------------------------------------------------------------------------

test_the_command_table_matches_zenv_help() {
    t_want=$(docs_table_from_help)
    t_have=$(docs_table)
    assert_ne '' "$t_want" 'the generator must produce a table' || return 1
    if [ "$t_want" != "$t_have" ]; then
        fail "the README's command table no longer matches 'zenv help'"
        # The failure output is the replacement: paste it over the table body.
        fail_detail 'replace the table body in README.md with:'
        fail_detail "$t_want"
        fail_detail 'it currently reads:'
        fail_detail "$t_have"
        return 1
    fi
    note "$(printf '%s\n' "$t_want" | wc -l | tr -d ' ') commands in the table"
}

# The table is one line per command, so the flags live in the help text's
# continuation lines. They still have to be written down somewhere, or the
# documents quietly stop covering the tool.
test_every_flag_in_help_is_documented() {
    t_flags=$(zenv help 2>&1 | tr -c 'A-Za-z0-9-' '\n' | grep '^--' | sort -u)
    assert_ne '' "$t_flags" 'zenv help must mention some flags' || return 1
    split_lines "$t_flags" | while IFS= read -r t_f; do
        [ -n "$t_f" ] || continue
        grep -qF -- "$t_f" "$README" && continue
        grep -qF -- "$t_f" "$GUIDE" && continue
        printf '%s\n' "$t_f"
    done >"$SANDBOX/missing-flags"
    assert_eq '' "$(cat "$SANDBOX/missing-flags")" \
        'every flag in the help text must appear in the README or the guide'
}

# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------

test_every_relative_link_resolves() {
    each_doc | while IFS= read -r t_doc; do
        t_base=$(dirname "$t_doc")
        docs_links "$t_doc" | sort -u | while IFS= read -r t_l; do
            [ -n "$t_l" ] || continue
            case $t_l in
                http://* | https://*) continue ;;
            esac
            # The published checkout has no Zeek source tree in it, so a link
            # into one is dead for every reader but this machine.
            case $t_l in
                zeek/* | */zeek/*)
                    fail "$t_doc links into the untracked zeek tree: $t_l"
                    continue
                    ;;
            esac
            case $t_l in
                '#'*)
                    t_file=$t_doc
                    t_anchor=${t_l#\#}
                    ;;
                *'#'*)
                    t_file=$t_base/${t_l%%#*}
                    t_anchor=${t_l#*#}
                    ;;
                *)
                    t_file=$t_base/$t_l
                    t_anchor=
                    ;;
            esac
            if [ ! -f "$t_file" ]; then
                fail "$t_doc has a dead link: $t_l"
                continue
            fi
            [ -n "$t_anchor" ] || continue
            if ! docs_anchors "$t_file" | grep -qxF -- "$t_anchor"; then
                fail "$t_doc links to a heading that does not exist: $t_l"
                fail_detail "headings there: $(docs_anchors "$t_file" | tr '\n' ' ')"
            fi
        done
    done
}

test_the_two_documents_point_at_each_other() {
    assert_contains "$(cat "$README")" 'docs/USER_GUIDE.md' \
        'the README must send a reader to the guide'
    assert_contains "$(cat "$GUIDE")" '../README.md' \
        'and the guide back to the README'
}

# ---------------------------------------------------------------------------
# The no-build-advice rule
# ---------------------------------------------------------------------------

# zenv never builds Zeek, and neither document tells anyone how to. `zenv new`'s
# own hint does print a build loop -- that is deliberate, it matches the loop a
# human uses, and tests/test_paths.sh asserts it -- but a document is read away
# from the tool, and build advice in one is how zenv would start acquiring build
# logic.
test_neither_document_gives_build_advice() {
    each_doc | while IFS= read -r t_doc; do
        t_prose=$(docs_prose "$t_doc")
        assert_not_contains "$t_prose" 'configure --with' \
            "$t_doc must not give configure advice"
        assert_not_contains "$t_prose" 'cmake' \
            "$t_doc must not name a build tool"
        assert_not_contains "$t_prose" 'make -j' \
            "$t_doc must not give build advice"
    done
}

# The README has to say it, not only the guide: that is the sentence that stops
# a reader hunting for the build command zenv does not have.
test_the_readme_says_zenv_never_builds_zeek() {
    t_r=$(cat "$README")
    assert_contains "$t_r" 'never builds Zeek'
    assert_contains "$t_r" '--prefix="$(zenv prefix dev)"' \
        'and names the prefix the way the tool does'
    # --with-prefix does not exist; a reader who pastes it gets an error.
    assert_not_contains "$t_r" '--with-prefix'
    assert_not_contains "$(cat "$GUIDE")" '--with-prefix'
}

# ---------------------------------------------------------------------------
# The directives themselves
# ---------------------------------------------------------------------------

test_every_zenv_test_directive_says_why() {
    t_ds=$(docs_directives)
    assert_ne '' "$t_ds" 'the README must declare its zenv-test directives' \
        || return 1
    split_lines "$t_ds" | while IFS= read -r t_d; do
        [ -n "$t_d" ] || continue
        case $t_d in
            *'zenv-test: skip '* | *'zenv-test: table '*) ;;
            *)
                fail "unknown zenv-test directive: $t_d"
                continue
                ;;
        esac
        # ` -- <reason>`, with something after it. A skip without a reason is an
        # exemption nobody had to justify, which is how a runnable README stops
        # being runnable one block at a time.
        if [ -z "$(printf '%s\n' "$t_d" | sed -n 's/.* -- *\(.*\) -->$/\1/p')" ]; then
            fail "a zenv-test directive gives no reason: $t_d"
        fi
    done
}

run_cases
