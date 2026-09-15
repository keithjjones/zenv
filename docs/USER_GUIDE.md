# zenv user guide

The [README](../README.md) gets you a second Zeek install and gets out of the way. This
document is everything that needed a paragraph: why the design is shaped the way it is, what
each command actually does, and what to do when something looks wrong.

- [Concepts](#concepts)
- [Choosing ZENV_ROOT](#choosing-zenv_root)
- [Building an environment by hand](#building-an-environment-by-hand)
- [`zenv autoconfig`](#zenv-autoconfig)
- [How a running zkg finds its config](#how-a-running-zkg-finds-its-config)
- [Activation](#activation)
- [Adopting an install that already exists](#adopting-an-install-that-already-exists)
- [`zenv link`: a system default](#zenv-link-a-system-default)
- [Source trees and zeek_dist](#source-trees-and-zeek_dist)
- [Packages that ship an executable](#packages-that-ship-an-executable)
- [`zenv doctor`](#zenv-doctor)
- [Uninstalling completely](#uninstalling-completely)
- [Troubleshooting](#troubleshooting)
- [Reference](#reference)

## Concepts

An **environment** is one directory under `$ZENV_ROOT` holding four things:

```
~/zenv/dev/
├── env         metadata: name, prefix, zkg_dir, src, src_commit, adopted, created
├── activate    a source-able stub, the analogue of a venv's bin/activate
├── zeek/       the install prefix — you install Zeek here yourself
└── zkg/        this environment's private zkg config and state
```

Because the prefix, the zkg state and the metadata live together, an environment is one thing
to create, inspect, back up or delete: `rm -rf ~/zenv/dev` is a complete manual removal, and
`~/zenv` is the only path to relocate or back up. There is no `ZENV_HOME` and no dotfile
elsewhere — one variable, one directory.

`env` and `config` are parsed with a `while IFS='=' read` loop, never `source`, so a stray
value in them cannot execute code. Environment names must match
`[A-Za-z0-9][A-Za-z0-9._-]*`, and `config` is reserved, because a name is a direct child of
the root alongside that file.

**Activation is shell-local.** It sets variables in the calling shell and touches no symlinks,
so two terminals can hold two different Zeeks at the same instant. The `~/zeek` and `~/.zkg`
symlinks are a separate, optional feature ([`zenv link`](#zenv-link-a-system-default)) for
shells that never activate anything.

### Why each environment needs its own prefix

Zeek bakes absolute paths into the install at configure time. `DEFAULT_ZEEKPATH` and
`ZEEK_PLUGIN_INSTALL_PATH` are compile-time constants
([CMakeLists.txt](https://github.com/zeek/zeek/blob/master/CMakeLists.txt), read in
[src/util.cc](https://github.com/zeek/zeek/blob/master/src/util.cc)), and `bin/zeek` carries an
absolute rpath. So:

- An environment must be installed to its own real directory — `$(zenv prefix dev)`. Two
  environments sharing one prefix report identical script and plugin paths, and their zkg
  states then fight over the same directories.
- Installing *through* the `~/zeek` symlink bakes the symlink's path, not the environment's,
  which is the exact input that triggers the deletion hazard described under
  [`zenv autoconfig`](#the-safety-gate).

The good news, verified against a real install: **reaching a real-path install through a
symlink is fine.** `~/zeek -> zenv/default/zeek` works — `zeek-config --prefix` reports the
baked real path, scripts load, plugins load. Nothing derives script or plugin paths from the
invocation path. That is what makes `zenv adopt --move` and `zenv link` safe, and it is why
moving `~/zenv` and leaving a symlink behind is a supported fix rather than a hack.

One thing not to do: re-installing an existing build tree into a second prefix — the
install-to-a-different-prefix escape hatch your build system offers after the fact — is **not**
a way to make a second environment, and it damages the first one. Zeek's own install rules use
absolute destinations and ignore the new prefix, while the bundled subprojects (broker, binpac,
spicy, hilti, paraglob) use relative ones and honour it — so their headers and libraries
*leave* the original prefix. The result runs `zeek --version` fine and fails to build any
native package with `fatal error: 'broker/expected.hh' file not found`. Re-installing to the
original prefix restores it, and `zenv doctor` checks for exactly this
([subproject headers](#zenv-doctor)).

## Choosing ZENV_ROOT

The parent directory is resolved by one function, first hit wins:

| # | Source | Scope | `zenv root --source` says |
|---|---|---|---|
| 1 | `$ZENV_ROOT` | this shell or this command only | `environment` |
| 2 | the default baked into the installed script by `./install.sh --root DIR` | this machine, every shell | `installed default` |
| 3 | `$HOME/zenv` | the built-in fallback | `built-in default` |

`zenv root` prints the path on stdout and its source on stderr, so `cd "$(zenv root)"` works
and a surprising root is one command to diagnose. An empty or relative `ZENV_ROOT` is an error,
not a silent fallback. The directory is created by the first `zenv new` or `zenv adopt`, never
at install time.

Level 2 is one assignment near the top of the installed script. That is deliberate: a pointer
file cannot live inside the root it points at, so it would have to be a new dotfile outside it
— precisely the stray artifact `zenv uninstall` exists not to leave. Baking it into the script
means removing the script removes the setting, and the script running `zenv uninstall` is by
construction the one that knows which root it created. A reinstall without `--root` preserves
the baked value; a reinstall with `--root` replaces it.

**Choose the root before you build anything.** Each environment's prefix is baked into its Zeek
binaries, so moving `~/zenv` to `/data/zenv` afterwards leaves every baked prefix pointing at a
path that no longer exists. There is no `zenv root --move`, because the only honest options are:

1. Move the tree and leave `~/zenv -> /data/zenv` behind. Safe, per the symlink finding above,
   and what `zenv doctor` recommends when it finds a baked prefix outside the current root.
2. Reinstall each environment with its new prefix. zenv cannot do that for you.

## Building an environment by hand

zenv creates the directories and tells you the prefix; the build is yours, and zenv neither
runs nor inspects it. The sequence is:

```sh
zenv new dev                                # zenv
./configure --prefix="$(zenv prefix dev)"   # you, with your own flags
                                            # ... your build and install ...
zenv autoconfig dev                         # zenv
zenv activate dev                           # zenv
```

`$(zenv prefix dev)` is the whole answer to "which prefix". Everything else on the configure
line is yours; zenv has no opinion about it, and no knowledge of build flags or dependencies.

### Two environments from one source tree

This works, with two mechanical notes.

- **One tree is configured for one prefix at a time.** `./configure` bakes the prefix into the
  tree's build directory, so reconfiguring for `dev` means a later install from that same build
  directory goes to `~/zenv/dev/zeek`. To keep two environments buildable from one checkout,
  give each its own build directory: `./configure --builddir=build-dev --prefix="$(zenv prefix
  dev)"`.
- **A custom `--builddir` bypasses the tree's convenience wrapper**, which hardcodes the name
  `build` and stops with "No build/ directory found". Point your build and install commands at
  the directory you named instead of relying on the wrapper.

  It also changes what `zenv doctor` can check: `zeek-config` exposes no build-directory value,
  so with a custom one, doctor reports `source tree: unbuilt` and compares `VERSION` only,
  rather than warning falsely. That is informational, not a problem.

Sharing a checkout is safe because packages build against the *install*, not the tree — see
[Source trees and zeek_dist](#source-trees-and-zeek_dist).

## `zenv autoconfig`

After you install into `$(zenv prefix dev)`, that install has no zkg wiring. The bundled
`<prefix>/bin/zkg` has `<prefix>/etc/zkg` and `<prefix>/var/lib/zkg` baked into it, and nothing
points at `~/zenv/dev/zkg`. `zenv autoconfig` is the one command that creates and validates
`~/zenv/dev/zkg/config`, so every later `zkg` call in that environment reads and writes only
that environment's state.

Keeping zkg state *outside* the prefix is also what makes it survive reinstalls: `make install`
rewrites `<prefix>/etc/zkg/config` every time, and never touches `~/zenv/dev/zkg`.

What it does, in order:

1. Requires `<prefix>/bin/zeek-config`. Without it: "nothing installed at `<prefix>` yet".
   zenv does not offer to build it.
2. **The safety gate** — see below. No zkg process starts until this passes.
3. `mkdir -p <zkg_dir>`, empty, never a copy of another environment's state. This must happen
   *before* any zkg runs, because `ZEEK_ZKG_CONFIG_DIR` and `ZEEK_ZKG_STATE_DIR` are ignored
   unless the directory already exists — pass them a path that does not exist yet and zkg
   silently operates on your real `~/.zkg` instead.
4. If `<zkg_dir>/manifest.json` exists, compares its `script_dir`/`plugin_dir`/`bin_dir`
   against what step 2 resolved, by real path. On a mismatch it aborts naming `--fix-paths`;
   with `--fix-paths` it rewrites the manifest *now*, before zkg is invoked.
5. Picks `<prefix>/bin/zkg` if present, else `zkg` from `PATH`.
6. Runs `zkg autoconfig --force` with `ZKG_CONFIG_FILE` unset, the two `ZEEK_ZKG_*` variables
   pointing at the environment's zkg directory, and `<prefix>/bin` first on `PATH`. On first
   use there is deliberately no config file yet, because zkg only injects its default package
   source and template when it is *creating* one. Pre-seeding a config by hand yields an empty
   `[sources]` and `zkg list all` returns nothing.
7. Asserts `state_dir` in the written config is the environment's zkg directory, and rewrites
   that one key if it drifted. `zkg autoconfig` never writes `state_dir` itself, so on a re-run
   it keeps whatever was there.
8. Verifies or blanks `zeek_dist` — see [Source trees and
   zeek_dist](#source-trees-and-zeek_dist).
9. Prints the resulting config and re-checks step 4's agreement, which is the invariant that
   keeps the *next* zkg call safe.

`zenv activate` runs autoconfig for you when the config is missing; `--no-autoconfig` skips
that. Rewriting one key preserves `[sources]`, `[templates]`, key order and comments;
`manifest.json` is edited through `python3`'s `json` module, never `sed`.

### The safety gate

This is the check worth understanding, because it guards against silent data loss.

Merely constructing zkg's `Manager` object — which happens for *every* zkg subcommand,
including read-only ones like `zkg list` — compares the config's `script_dir`/`plugin_dir`
against the ones recorded in `manifest.json`. If they disagree, zkg treats it as a relocation:
it deletes the destination and moves the previous tree onto it
([zeekpkg/manager.py](https://github.com/zeek/package-manager/blob/master/zeekpkg/manager.py)).
It then rewrites `packages.zeek` from the manifest it just loaded, so a state directory with an
empty manifest blanks the autoloader of whatever prefix its config names.

So one `zkg list` in a misconfigured environment can delete another environment's installed
packages. The trigger is exactly what a wrongly-prefixed install manufactures: a tree
configured with another environment's `--prefix` reports *that* prefix's `site` and `plugins`
directories, `zkg autoconfig` writes them into this environment's config, and this
environment's zkg then adopts them by deleting.

`zenv autoconfig` therefore checks, entirely by itself and before any zkg runs, that the real
paths of `zeek-config --site_dir` and `--plugin_dir` both fall under the environment's own
prefix, and that no *other* registered environment already claims those directories. On
failure it names the offending path and the environment it belongs to, and exits non-zero
having run nothing.

Two mitigating facts, both verified. The comparison is on real paths, so an install reached
through a symlink is not seen as a relocation — which is why `zenv adopt --move` is safe. And a
zkg state directory with *no* config cannot trigger it at all, because zkg's fallback
`script_dir` and `plugin_dir` live inside the state directory rather than in any prefix. The
hazard is exclusively an autoconfig'd config, since that is what writes a prefix's paths into
`[paths]`.

`zenv doctor`, `zenv uninstall`, `zenv restore` and `zenv status` never run zkg at all, for the
same reason: they read the config and manifest files directly.

## How a running zkg finds its config

Resolution order, from zkg's `find_configfile()` and `default_config_dir()`
([zkg](https://github.com/zeek/package-manager/blob/master/zkg)):

| # | Source | Caveat |
|---|---|---|
| 1 | `--configfile FILE` | wins outright; hard error if the file does not exist |
| 2 | `--user` | jumps straight to `~/.zkg/config`, ignoring everything below |
| 3 | `$ZKG_CONFIG_FILE` | honoured **only if the file exists and is non-empty** |
| 4 | `$ZEEK_ZKG_CONFIG_DIR/config` | the variable is honoured **only if it is an existing directory**, else the value baked in at build time (`<prefix>/etc/zkg`, same test), else `~/.zkg` |
| 5 | nothing found | in-memory config: `state_dir` from `$ZEEK_ZKG_STATE_DIR` (if an existing directory), else the baked `<prefix>/var/lib/zkg`, else `~/.zkg`; with `script_dir` and `plugin_dir` *inside* `state_dir` |

Activation exports `ZKG_CONFIG_FILE`, `ZEEK_ZKG_CONFIG_DIR` and `ZEEK_ZKG_STATE_DIR`, all
naming the environment's zkg directory, so rows 3, 4 and 5 all land on that environment's own
state no matter which `zkg` wins on `PATH`. That matters when a pip-installed `zkg` is ahead of
the bundled one: it carries unsubstituted `@ZEEK_ZKG_CONFIG_DIR@` placeholders, which are never
directories, so without these variables it falls back to `~/.zkg` — the shared state the whole
design exists to get away from.

Two consequences worth knowing:

- A *missing* environment config does not fail loudly. Row 3's non-empty test drops through to
  row 4 and then row 5, which is self-contained inside the environment — an acceptable landing
  spot, but not the autoconfig'd one. That is why `zenv activate` runs autoconfig when the
  config is absent.
- **`zkg --user` overrides all of it** and silently uses `~/.zkg`. zenv cannot prevent that;
  `zenv status` names it so the behaviour is not a surprise.

## Activation

`eval "$(zenv init sh)"` installs a shell function that intercepts `activate` and `deactivate`
and evals what `zenv shell …` prints. All human-readable output goes to stderr and only shell
code to stdout, so autoconfig chatter cannot corrupt the eval. `zenv init` also accepts `bash`
and `zsh`, and emits the same POSIX function for all three — bash and zsh both run it, so there
is nothing per-shell to drift.

`zenv init fish` refuses, rather than emitting code fish cannot eval. From fish, use
`zenv exec <name> -- <command>` for one-offs, or run a POSIX shell when you want an activated
session.

`. ~/zenv/dev/activate` does the same thing with no rc changes at all — the direct analogue of
a venv's `bin/activate`.

Two naming decisions, both about not leaving debris in a live shell:

- **The restore code is emitted inline**, as a `_zenv_deactivate` function defined by the
  activation code itself, the way a venv's `activate` defines its own `deactivate`. So an
  activated shell can always restore itself with no `zenv` on disk — which is what makes
  `zenv uninstall` safe to run from an activated shell. `zenv shell deactivate` survives only
  as the fallback for a shell that lost the function (`exec zsh`), where the shell-local saved
  values are gone anyway and the best it can do is strip the prefix from the paths.
- **zenv never defines a bare `deactivate`.** Python's venv owns that name; taking it would
  break the venv, and `unset -f deactivate` on the way out would remove *theirs*. A test
  asserts a `deactivate` function defined before `zenv activate` is byte-identical afterwards.

### What activation sets

| Variable | Value |
|---|---|
| `ZENV` | the environment's name |
| `ZENV_PREFIX` | its install prefix |
| `ZENV_ZKG_DIR` | its zkg directory |
| `PATH` | `<prefix>/bin` prepended |
| `PYTHONPATH` | `<prefix>/lib/zeek/python` prepended — needed to import `broker`, `zeekctl`, `zeekpkg` |
| `MANPATH` | `<prefix>/share/man` prepended |
| `ZEEKPATH` | `zeek-config --zeekpath` plus zkg's `script_dir`, deduped |
| `ZEEK_PLUGIN_PATH` | `zeek-config --plugin_dir` plus zkg's `plugin_dir`, deduped |
| `ZKG_CONFIG_FILE`, `ZEEK_ZKG_CONFIG_DIR`, `ZEEK_ZKG_STATE_DIR` | the environment's zkg directory |
| `PS1` | prefixed `(zenv:<name>) `, unless `ZENV_DISABLE_PROMPT` is set |

`ZEEK_DIST` and `ZEEK_BUILD_DIR` are **deliberately not set**, and an existing value of either
is left exactly as it is — activation neither reads nor overwrites them. The reasoning is under
[Source trees and zeek_dist](#source-trees-and-zeek_dist).

The three path variables get surgery, not blind prepending: zenv walks `$ZENV_ROOT/*/env` and
removes each *registered* environment's component before adding its own. So activating `dev`
while `default` is active leaves exactly one Zeek bin directory on `PATH`, activating the same
environment twice is a no-op, and a `…/zeek/bin` on your `PATH` that belongs to no environment
is never touched. Empty components (`::`, a leading or trailing `:`) are preserved as-is,
because an empty component means the current directory and silently rewriting it would change
what your shell does.

Before overwriting each of the six variables it can clobber — the two `ZEEK*PATH`s, the three
zkg variables and `PS1` — the emitted code saves a *had it / old value* pair, shell-local and
not exported. That is what lets `deactivate` tell **unset** from **empty** and put a variable
back to unset rather than to empty.

### `zenv exec`, for one-offs

```sh
zenv exec dev -- zeek -N
zenv exec dev zeek -N        # the -- is optional
```

Applies the same environment to one command in a child process and execs it, so the command's
exit code is yours. The prompt rewrite is suppressed, since the child is not a shell.

## Adopting an install that already exists

`zenv adopt` registers Zeek you already built, so you do not start over. Two modes:

```sh
zenv adopt default                            # --move (the default for ~/zeek): relocate
zenv adopt other --from /opt/zeek --link      # --link: point at it where it is
```

**`--move`** moves `~/zeek` to `~/zenv/default/zeek` and `~/.zkg` to `~/zenv/default/zkg`,
rewrites `state_dir` in the moved zkg config, and creates `~/zeek` and `~/.zkg` as relative
symlinks back to them. The moved install's baked prefix is still `~/zeek`, so **the symlinks
are required for that environment, not cosmetic** — it resolves through them — until you
reinstall Zeek with the new prefix. `zenv adopt` prints that caveat, and `zenv doctor` reports
the baked prefix as a warning it explains rather than as an error.

Only `state_dir` needs rewriting: the config's `script_dir`, `plugin_dir` and `bin_dir` and
`manifest.json` all still name `~/zeek/…`, which is what the symlink resolves to, so the
[safety gate](#the-safety-gate)'s comparison sees no relocation.

**`--link`** leaves the install where it is and makes `~/zenv/other/zeek` a symlink to it.
Nothing is moved and nothing outside the root is modified. `--zkg DIR` does the same for the
zkg state directory.

`env` records which of the two happened, as `adopted=moved` or `adopted=linked`. That is what
makes [`zenv restore`](#uninstalling-completely) the exact inverse of `adopt --move` and of
nothing else — guessing from the symlinks alone would let uninstall relocate an install you
built yourself, just because `zenv link` happened to point at it.

`zenv remove <name>` deletes an environment outright. It refuses while the environment is
linked or active unless `--force`, `--keep-zkg` spares the zkg state, and it requires that
`$ZENV_ROOT/<name>` is a real directory and a direct child of the root — never a symlink — so
removal cannot follow a link out of the root.

## `zenv link`: a system default

```sh
zenv link default
zenv unlink
```

This is the *optional* half of the design: it points `~/zeek` and `~/.zkg` at one environment
as a persistent, machine-wide default, for shells that never activate anything and for scripts
that hardcode those paths. Activation does not need it and does not touch it, so a linked
default and a differently-activated terminal coexist happily; `zenv doctor` and `zenv status`
say when they disagree, because that is worth *seeing* even though it is harmless.

Both symlinks are relative (`zenv/default/zeek` from `$HOME`) and swapped atomically — `ln -s`
to a temporary name, then `mv -f` — so the path is never momentarily missing. `zenv link`
refuses when either path exists as a real directory and names `zenv adopt` instead, which is
the command that knows how to deal with real content there.

Which paths get linked is recorded as `zeek_link` and `zkg_link` in `$ZENV_ROOT/config`. That
file records *where the two symlinks belong* — a location setting — not a claim that they
currently exist.

## Source trees and zeek_dist

Short version: **zenv never exports `ZEEK_DIST`**, and writes the zkg config's `zeek_dist` key
only when it can verify the tree. Both decisions come from tracing every consumer of the name.

`ZEEK_DIST` is a CMake *variable*, read only by the plugin helper Zeek installs under your
prefix ([Zeek's plugin helper](https://github.com/zeek/zeek/blob/master/cmake/ZeekPlugin.cmake)).
When it is set, a package builds against `<tree>/build` and **returns early — the installed
Zeek is never consulted.** When it is unset, `ZeekPluginBootstrap` from the install tree takes
over, and its baked values are already per-environment correct.

Nothing imports `ZEEK_DIST` from the environment: CMake does not turn environment variables
into variables, and there is no `$ENV{ZEEK_DIST}` anywhere in an install tree. So exporting it
does nothing at all — and because a shared checkout is a moving target, exporting it is *worse*
than nothing: it is a variable a human will paste into `--zeek-dist=$ZEEK_DIST` and get a
silently wrong tree. Package `configure` scripts read `--zeek-dist=DIR` from their arguments
only; several of them say in a comment that it serves no function.

`ZEEK_BUILD_DIR` is the opposite case: that one *is* read from the environment, and it silently
overrides the tree for any package that passes `--zeek-dist`. zenv never sets it, and
`zenv doctor` warns when you have.

Where the name does something real is the zkg config's `zeek_dist`, which zkg interpolates as
`%(zeek_dist)s` into package metadata. Two of roughly 285 index packages use it, and both pass
it straight through to `--zeek-dist=`. So `zenv autoconfig` takes the value `zeek-config`
reports (or the environment's `src` override) and verifies it two ways: `<tree>/VERSION` must
equal `zeek-config --version`, and `<tree>/build/zeek-version.h` must name the matching
`ZEEK_VERSION_FUNCTION`. Verified, it is written through unchanged. Not verified, it is
**written empty**, with the failed check named.

Empty is the right failure mode. It is irrelevant to all but those two packages, and it fails
them immediately and loudly (`--zeek-dist=` with no argument does not work) instead of building
a plugin against the wrong sources. That version guard is worth seeing, because it is why a
wrong tree is not a cosmetic problem:

```
include/zeek/zeek-version.h:  #define ZEEK_VERSION_FUNCTION zeek_version_9_1_0_dev_75_plugin_7
nm bin/zeek:                  T _zeek_version_9_1_0_dev_75_plugin_7
```

The symbol name encodes the version *and* the plugin API version
([src/plugin/Plugin.h](https://github.com/zeek/zeek/blob/master/src/plugin/Plugin.h)). A plugin
built against a different tree references a symbol the running Zeek does not export, and
refuses to load at `dlopen`. Loud — but only after you have built it.

`zenv dist [name]` prints the tree **only if it verifies**, so `--zeek-dist=$(zenv dist)` is
empty rather than wrong. `zenv status` shows the value with its state.

### One checkout, several environments: the build commit

Sharing one checkout between environments is the normal way to work, and it is the one hazard
zenv cannot fix for you: **activating an environment does not check its tree back out.** Switch
to `dev` while the tree is on the commit `default` was built from, build a package that passes
`--zeek-dist`, and it compiles against sources this install was never built from.

Verification above catches that the tree no longer fits — but "unverified" does not tell you
*which* commit to go back to. So `zenv autoconfig` records it, at the one moment it can honestly
be known: the tree matched the install right then. Two keys go into the environment's `env` file,
`src_commit` and the `src_version` it was recorded against, and nothing later clears them —
drift is exactly when they are needed.

Activation reads them back, and says so when they disagree:

```
$ zenv activate default
zenv: 'default' was built from /Users/you/Source/zeek at 4f21ac09b8d3
      that tree is now on 91be7742cc10 (v9.1.0-dev.96)
      git -C /Users/you/Source/zeek checkout 4f21ac09b8d3
      puts it back. Only a package build that passes --zeek-dist reads that
      tree; nothing else in this shell does.
```

That last sentence is the whole scope of it. Nothing in the activated shell reads the tree, the
installed Zeek does not, and 283 of the 285 index packages do not. The reminder exists because
the two that do are the ones that fail after a long build rather than before it. Set
`ZENV_DISABLE_REMINDER` to anything to silence it.

`zenv doctor` reports the same comparison, and counts a tree checked out elsewhere against its
exit code only once the install has already drifted from it — a shared checkout moving between
commits of the *same* version leaves a working install, so it is information, not a warning. Two
other states it names rather than guesses at: a recorded commit the tree no longer has (a
re-clone, or rewritten history — fetch it, or rebuild and re-run `zenv autoconfig`), and a commit
recorded for a different installed version, which a reinstall produces and which says nothing
about what is installed now.

A tree that is not a git checkout at all — a release tarball — records no commit and is reported
as nothing unusual. The version check is all zenv has there, and all it claims.

If you would rather not think about any of this, the alternative is one checkout per environment:
`git worktree add ../zeek-dev` costs a directory and removes the shared state entirely.

## Packages that ship an executable

Short version: **an executable a package installs is already per-environment, and needs no PATH
work from you.** The chain is worth tracing anyway, because the one link zenv has no say in — the
run path baked into the binary — is the link that fails silently when it is wrong.

A package declares them in its `zkg.meta`:

```
executables = build/shm-lb/shm_lb
```

zkg builds the package inside its own clone, under that environment's `state_dir`, and then symlinks
each declared path from the clone into `bin_dir`
([zkg's manager](https://github.com/zeek/package-manager/blob/master/zeekpkg/manager.py), in
`_refresh_bin_dir`). `zenv autoconfig` set `bin_dir` to `<prefix>/bin`, and activation puts that
directory first on PATH while stripping every other environment's, so the executable arrives and
leaves with the environment:

```
$ zenv activate bleeding && command -v shm_lb
/Users/you/zenv/bleeding/zeek/bin/shm_lb
$ zenv activate v8.0.9 && command -v shm_lb
/Users/you/zenv/v8.0.9/zeek/bin/shm_lb
```

Two builds of one package, one per environment, each from its own clone. Nothing is shared, so
nothing has to be swapped. A package README that says an executable has no install target and that
you must fix PATH by hand is describing the build, not the `executables` key.

### The run path is a baked prefix too

An executable that links a shared library out of the prefix records where to find it **at link
time**, as an absolute path:

```
$ otool -l bleeding/zeek/bin/shm_lb | grep -A2 LC_RPATH    # readelf -d, on Linux
         path /Users/you/zenv/bleeding/zeek/lib
```

That has to be the environment's own real directory, for the same reason
[an install does](#why-each-environment-needs-its-own-prefix). Recorded through `~/zeek` it does not
merely go stale, it **floats**: the binary then loads whichever environment `zenv link` names *now*,
which is a different Zeek's library than the headers it compiled against. Nothing announces that.
The version guard above catches a mismatched *plugin* at `dlopen`, loudly; a mismatched library
behind a path that still resolves is a crash much later, or no symptom at all.

The rule that follows is one line: **activate the environment before building anything.** In a shell
with nothing active, `zeek-config` is found through `~/zeek/bin` and reports the linked environment
— which is how a floating run path gets made in the first place. `zenv prefix <name>` prints the
real directory and never the symlink, and `zenv exec <name> --` is enough for a one-off build.

### Why not to carry a build directory between environments

A library lookup is normally cached on first success and never repeated. So a build directory reused
across a switch can hold a library path belonging to the *previous* environment while every other
value in it has been updated, and re-running the package's `configure` will not correct it, because
nothing re-searches. The result builds and installs cleanly and is wrong.

A per-environment zkg clone starts from an empty build directory every time, which is why the
question never arises on that path. Building by hand, delete the build directory when you switch.

## `zenv doctor`

```sh
zenv doctor            # every environment
zenv doctor dev        # one
```

Exit codes: **0** all checks passed, **1** warnings only (nothing broken), **2** errors found.
Every other zenv command exits 0 on success and 1 on any refusal or error.

Doctor never runs zkg — see [the safety gate](#the-safety-gate) — so it is always safe to run
first when something looks wrong. It reads the config and manifest files directly.

Per root:

- the resolved root and which of the three sources it came from
- `ZEEK_BUILD_DIR` set in your environment — **warning**, because it silently overrides the
  tree for any package that passes `--zeek-dist`
- `ZEEK_DIST` set in your environment — informational; nothing reads it
- whether `$ZENV` names an environment that exists
- the state of `~/zeek` and `~/.zkg`: which environment each names, or that it is a real
  directory zenv did not create, or dangling
- **no two environments' configs may resolve to the same `script_dir` or `plugin_dir`** —
  **error**, since that is the collision the safety gate exists to prevent

Per environment:

- the prefix and zkg directories exist, and whether anything is installed
- `zeek-config --prefix` equals the environment's own directory. A **warning** when it is the
  symlink (normal for an adopted-and-moved install, and doctor says so); an **error** when it
  is some other environment's directory
- **subproject headers**: `zeek-config --broker_root`'s `include/broker` must exist. This is
  the check that catches the silently-broken install described in
  [Concepts](#why-each-environment-needs-its-own-prefix) — `zeek --version` succeeding is not
  evidence that an install can build packages
- `<prefix>/bin/zeek --version` actually runs, i.e. the baked rpath still resolves
- source-tree state: `verified`, `drifted`, `unbuilt`, `gone`, or `none`. Only **drifted** is a
  warning, because that is the one state where a stale tree could be built against
- zkg's `state_dir` is the environment's zkg directory (**error** otherwise), and
  `script_dir`/`plugin_dir`/`bin_dir` all resolve under its prefix (**error** otherwise)
- `manifest.json` agrees with the config on all three path keys — **error** on a mismatch,
  pointing at `--fix-paths`, because the next zkg invocation would otherwise delete and move
- which `zkg` resolves first, whether it is the environment's own, and whether its interpreter
  can import `git` and `semantic_version` (the bundled `zkg` hard-fails without them)

## Uninstalling completely

```sh
make uninstall ARGS=--dry-run     # the whole inventory, changes nothing
make uninstall ARGS=--yes
```

`make uninstall`, `./uninstall.sh` and `zenv uninstall` are one code path with the same flags
(`--dry-run`, `--purge`, `--yes`). The logic lives in the installed script, not in
`uninstall.sh`, for two reasons: after installing, the repo checkout may be deleted, moved or on
another branch, and the installed script is the only thing guaranteed to still exist *and* to
know the layout it created; and everything uninstall needs already exists in it.

`--dry-run` names every path the real run then touches, and the test suite asserts that
correspondence in both directions, so the inventory below cannot drift from the code.

Running it when zenv is not installed is a no-op that exits **0**, before the confirmation
prompt: it says what it looked for and stops. That makes it safe to rerun, and safe to call
unconditionally from a script — the state it was asked to produce is the state the machine is
already in. "Not installed" is a question about all of the artifacts in the table below, not
just the script, so a `~/.local/bin/zenv` you deleted by hand still leaves an rc block to find
and remove. The one case that *is* an error is `./uninstall.sh` beside a `bin/zenv` that exists
but is not executable: a broken checkout is something to fix, not a clean machine.

| Artifact | Created by | Removed |
|---|---|---|
| `~/.local/bin/zenv`, including the baked root line | `./install.sh [--root DIR]` | yes — no separate file holds the root |
| the two completion files | `./install.sh` | yes |
| the `# >>> zenv >>>` … `# <<< zenv <<<` rc block | `./install.sh` | yes — exactly that block, nothing else in the file |
| `$ZENV_ROOT/config`, `$ZENV_ROOT/<name>/{env,activate}` | `zenv new`, `zenv adopt` | yes |
| `~/zeek` and `~/.zkg` symlinks | `zenv link`, `zenv adopt` | yes, and a moved tree is put back first |
| `state_dir` in an adopted zkg config | `zenv adopt --move` | yes, reverted |
| `$ZENV_ROOT/<name>/zeek` for an environment **you** built | your install | **no** — kept and named, unless `--purge` |

What it does, in order:

1. With `--dry-run`, print the inventory with resolved paths — starting with the root and its
   source, since a custom root changes what "everything" means — and exit without touching
   anything.
2. **Put an adopted install back.** For an environment recorded as `adopted=moved`, this is
   `zenv restore`: remove the symlinks, move both trees back to `~/zeek` and `~/.zkg`, revert
   `state_dir`. This is *more* correct than leaving it, because that install's baked prefix was
   always `~/zeek` — moving it back makes the symlink unnecessary again.
3. **Report, don't delete, the installs you built.** Their prefix is baked into their own
   binaries, so there is nowhere to move them and only you can decide they are finished with.
   They are listed with their sizes and the exact `rm -rf` that removes them. `--purge` does it
   for you. zenv's own `env` and `activate` beside them go either way — an `env` file describing
   an environment whose zenv is gone is exactly the stray artifact this command exists not to
   leave. An environment holding nothing but the empty directories zenv created goes entirely.
4. Remove the rc block, the completions and the script. The rc file is found by searching
   `~/.zprofile`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`, `~/.profile` and
   `~/.config/fish/config.fish` for the start marker, so a block moved to another file is still
   found, and every file containing it is cleaned. (`./install.sh` refuses to *write* a fish
   config, but it will still clean one you wrote by hand.) If the markers were hand-edited so
   that they no longer bracket only zenv's lines, the file is left alone and printed for you to
   fix.
5. Remove `$ZENV_ROOT` if all that is left in it is zenv's own metadata and empty directories;
   otherwise leave it and say which paths kept it alive.
6. Print what is still on the machine, or "nothing left" — and note that an activated shell
   still holds its exported variables until you run `zenv deactivate` (which works with the
   binary gone) or close it.

Uninstall never removes anything it did not create: it refuses to delete `~/zeek` or `~/.zkg`
while they are real directories, refuses to follow a symlink out of the root, and never touches
a build tree, a `~/.zkg/clones` cache or an installed package.

`./install.sh` copies your rc file to `<rcfile>.zenv-pre-install` before its first edit, so
`mv ~/.zprofile.zenv-pre-install ~/.zprofile` restores the pre-zenv file byte-for-byte —
including any lines you removed yourself, which zenv did not write and will not put back.
Uninstall reports that path when it exists, and keeps a backup that differs from the current
file rather than deleting it.

`zenv restore <name>` is available on its own, with `--dry-run` and `--yes`. It refuses on an
environment it did not move.

## Troubleshooting

**The wrong `zkg` is winning.** Check `zenv doctor`'s "zkg:" lines. With an environment active,
`command -v zkg` should be `$ZENV_PREFIX/bin/zkg`. If a pip-installed `zkg` is ahead of it,
your rc file prepends it after zenv's block — move zenv's block later in the file. Even when the
wrong binary wins, the three exported `ZKG_*`/`ZEEK_ZKG_*` variables keep it on the right state
directory; what you lose is the interpreter and version match with the install. `zkg --user`
bypasses all of it by design and uses `~/.zkg`.

**My packages vanished.** Almost always the relocation described under [the safety
gate](#the-safety-gate): some zkg invocation found a config and a `manifest.json` that
disagreed, and moved one tree onto the other. Run `zenv doctor` — it reports the mismatch as an
error and never runs zkg itself, so it cannot make things worse. If the manifest and the git
clones under `~/.zkg/clones` survived, `zkg install --force --version <v> <package>` reinstalls
without re-downloading; the versions are the `current_version` values in the manifest, and zkg
has no `reinstall` subcommand. Then check `packages.zeek` lists every package again, since an
install sequence can leave it holding only the last one.

**A plugin will not load.** If `zeek -N` does not list it and `dlopen` reports an undefined
`zeek_version_…_plugin_…` symbol, it was built against a different Zeek than the one running
it — see [Source trees and zeek_dist](#source-trees-and-zeek_dist). Rebuild it with the
environment active and no `ZEEK_DIST` or `ZEEK_BUILD_DIR` in the environment, so it builds
against the install. If instead it fails to *build* with a missing `broker/` header, the
install itself is incomplete: `zenv doctor`'s subproject-headers check confirms it, and
reinstalling into the same prefix restores it.

**`zeek` is not found after `deactivate`.** Expected: `deactivate` removes the environment's
`bin` from `PATH`, and nothing else put a Zeek there. If you want a Zeek available in
non-activated shells, that is what [`zenv link`](#zenv-link-a-system-default) plus
`~/zeek/bin` on your `PATH` is for.

**A surprising root.** `zenv root --source` says which of the three sources won. A `ZENV_ROOT`
exported in your rc file beats the baked default in every shell, which is usually not what
someone intended.

**`deactivate` says the function is missing** after `exec zsh` or in a shell that lost it.
`zenv deactivate` falls back to static restore code, which strips `$ZENV_PREFIX` from the paths
and unsets zenv's variables; the shell-local saved values are gone, so the six overridable
variables end up unset rather than back to their originals.

## Reference

### `$ZENV_ROOT/config`

`key=value`, one per line, `#` comments allowed. Read with a `while IFS='=' read` loop, never
sourced.

| Key | Meaning |
|---|---|
| `zeek_link` | where the `zeek` symlink belongs (default `$HOME/zeek`) |
| `zkg_link` | where the `zkg` symlink belongs (default `$HOME/.zkg`) |

### `$ZENV_ROOT/<name>/env`

| Key | Meaning |
|---|---|
| `name` | the environment's name |
| `prefix` | its install prefix |
| `zkg_dir` | its zkg config and state directory |
| `src` | an asserted source tree, used only to override `zeek-config --zeek_dist`, and verified before use |
| `src_commit` | the commit that tree was on when it last verified, written by `zenv autoconfig` |
| `src_version` | the installed version `src_commit` was recorded against |
| `adopted` | `moved`, `linked`, or empty for an environment created from nothing |
| `created` | UTC timestamp |

Blank lines, `#` comments, CRLF endings, unknown keys, values containing `=` and spaces around
either side are all tolerated.

### Environment variables

**Read by zenv:**

| Variable | Effect |
|---|---|
| `ZENV_ROOT` | overrides the parent directory for this shell or command |
| `ZENV_DISABLE_PROMPT` | set to anything: activation leaves `PS1` alone |
| `ZENV_DISABLE_REMINDER` | set to anything: activation leaves the source-tree reminder unsaid |
| `ZENV_PYTHON` | the python used to read and write `manifest.json` |

**Set by activation:** `ZENV`, `ZENV_PREFIX`, `ZENV_ZKG_DIR`, `PATH`, `PYTHONPATH`, `MANPATH`,
`ZEEKPATH`, `ZEEK_PLUGIN_PATH`, `ZKG_CONFIG_FILE`, `ZEEK_ZKG_CONFIG_DIR`, `ZEEK_ZKG_STATE_DIR`,
`PS1`. See [What activation sets](#what-activation-sets).

**Never set by zenv, and never modified:** `ZEEK_DIST`, `ZEEK_BUILD_DIR`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success — and for `doctor`, all checks passed |
| 1 | any refusal or error; for `doctor`, warnings only |
| 2 | `doctor` only: errors found |

Otherwise, `zenv exec` propagates the exit code of the command it runs.

### Requirements

POSIX `sh`, `python3` (already a zkg dependency), `git`. macOS and Linux. No Zeek source tree
and no Zeek install are needed to install zenv or to run `make test`.
