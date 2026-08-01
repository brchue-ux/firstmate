# Home resolution verification

Audience: maintainer verification.

This record supports the current guarantee that an ambiently inherited `FM_HOME` cannot route a command into a home it was not chosen for.
The rule itself is owned by `bin/fm-home-anchor-lib.sh`, and the operator-facing description lives in [`docs/configuration.md`](../configuration.md) under "FM_HOME".
Executable coverage of the rule is `tests/fm-home-anchor.test.sh`; this record holds only the axes a test cannot assert - which integration surfaces were inspected, and what the hooks do when resolution refuses.

## Primary harnesses

Checked on 2026-07-31 against every verified adapter.

Resolution is a shell-level concern, so `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `kimi` share one path through `bin/fm-home-anchor-lib.sh` whenever they invoke a `bin/fm-*.sh`.
The harness-specific surfaces that carry a home of their own are these:

- `bin/fm-turnend-guard.sh` is the shared Stop guard for every harness; `bin/fm-turnend-guard-grok.sh` delegates to it and reads no home itself, and `bin/fm-kimi-turnend-hook.sh` reads no `FM_*` variable at all.
- `bin/fm-claude-stop-autoarm.sh`, `bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, and `bin/fm-subagent-pretool-check.sh` are the Claude-registered hooks. `fm-cd-pretool-check.sh` never reads `FM_HOME` and is not applicable.
- `.pi/extensions/fm-primary-pi-watch.ts` and `.opencode/plugins/fm-primary-watch-arm.js` compute their own `FM_HOME` candidate in TypeScript and JavaScript. They remain candidates, not resolutions: each hands the value to `bin/fm-watch-arm.sh`, which resolves through the shared owner. Both set `FM_ROOT_OVERRIDE` and derive `FM_CONFIG_OVERRIDE` from that candidate, which is why a partial override set does not declare a home - see the contract in the owner's header.

## Runtime backends

Checked on 2026-07-31 against every spawn backend.

`bin/backends/herdr.sh`, `bin/backends/zellij.sh`, and `bin/backends/cmux.sh` each carried their own copy of the resolution line for direct unit sourcing and now defer to the shared owner.
`bin/backends/tmux.sh` and `bin/backends/orca.sh` read no `FM_HOME` and are not applicable.
`codex-app` is not a selectable spawn backend and is not applicable.

## Hook behavior when resolution refuses

Reproduced with two synthetic home roots, the second carrying a `.fm-secondmate-home` marker, running each hook from the first with `FM_HOME` naming the second.
Every hook declined without writing into the other home, and the count of files under the other home's `state/` was 0 before and 0 after:

```
fm-turnend-guard.sh            exit=0   (silent decline)
fm-claude-stop-autoarm.sh      exit=0   (silent decline)
fm-subagent-pretool-check.sh   exit=0   (inert, never blocks a call it cannot confirm)
fm-cd-pretool-check.sh         exit=0   (does not read FM_HOME)
fm-arm-pretool-check.sh        exit=2   (a broad watcher kill is still denied)
fm-watch.sh --status           exit=1   error: FM_HOME names a different firstmate home ...
```

The same sweep with `FM_HOME` naming the home it stands in is the control: `fm-watch.sh` proceeds and writes that home's own watcher state, so the refusal above is the anchoring decision rather than an inert environment.

`bin/fm-arm-pretool-check.sh` is the one hook that must stay protective under refusal, because declining to act would allow the dangerous command it exists to deny.
It anchors on its own checkout when resolution cannot say which home the session belongs to, which can only widen the deny.

## Suite behavior from a home root

The captain's primary home is both the code root and a live firstmate home, so the suite runs from a directory that is itself a home root while each test selects a fixture home.
`bin/fm-test-run.sh` and `tests/lib.sh` therefore export the process-tree form of the declaration described in the owner's header.
Without it, roughly a third of the suite refuses in that configuration; `tests/fm-secondmate-lifecycle-e2e.test.sh` pins that `bin/fm-spawn.sh` blanks the declaration on every launch line, so it cannot follow an agent out of the suite.
