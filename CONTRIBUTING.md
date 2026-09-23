# Contributing

Short version of how this addon is built, checked and shipped. The
[README](./README.md) has the architecture and the module contract.

## Local setup

```powershell
git clone https://github.com/Moose-Ltd/MooseMode.git
cd MooseMode
.\install.ps1          # link MooseMode/ into the beta AddOns folder as MooseModeDev (-Path for another install)
```

Edit, then `/reload` in game. Turn on Lua errors while developing:

```
/console scriptErrors 1
```

## Syntax check

The client runs Lua 5.1. Parse every file before committing:

```bash
npm i -g luaparse@0.3.1
node -e "const l=require('luaparse'),fs=require('fs');for(const f of process.argv.slice(1)){l.parse(fs.readFileSync(f,'utf8'),{luaVersion:'5.1'});console.log('ok',f)}" MooseMode/Core.lua MooseMode/Modules/*.lua
```

[`ci.yml`](./.github/workflows/ci.yml) runs the same check on every push.

## Conventions

- One module per file under `Modules/`, registered with `ns:RegisterModule`. Add it to the TOC next to the module it belongs with.
- Forever is the Retail 12.x client. Use `C_*` namespaces only; guard every call for existence and pass values through `ns.IsSecret` before comparing.
- Never call protected functions (pet commands, interact, cast, move). If a feature needs one, it needs a macro or a keybind instead.
- Labels stay short; detail goes in the tooltip. No "Hold Shift" text in tooltips, the dialog footer says it once.
- Read settings at runtime from `ns.db`, never at file load.
- One feature or fix per commit, with a message that says what changed and why.
- Plain prose in docs and chat text: no em dashes, no first-person plural, no filler.

## Reporting a bug

Open an issue with the bug template and include:

- Client build (`/run print(GetBuildInfo())`) and which module.
- Steps, and what happened instead.
- Any red Lua error text (`/console scriptErrors 1`).
- For quests: `/mm questdebug`, repeat the step, paste the chat lines.
- For rewards: `/mm rewarddebug`, repeat the step, paste the chat lines.

## Changelog rule

Every user-visible change adds a line under `## Unreleased` in `CHANGELOG.md`,
in the same commit as the change. CI fails a pull request that touches the
addon folder without touching the changelog. Small changes get small lines;
that is fine.

## Shipping

A release is a tag. Everything after the push is automatic.

1. Rename `## Unreleased` in `CHANGELOG.md` to the new version, for example `## 1.2.0-forever`.
2. Bump `## Version` in `MooseMode/MooseMode.toc` to the same string (keep the `-forever` suffix).
3. Commit as `Version 1.2.0-forever`.
4. Tag and push: `git tag v1.2.0-forever && git push origin main --tags`.

[`release.yml`](./.github/workflows/release.yml) then checks the tag matches
the TOC, builds `MooseMode-<version>.zip`, publishes a GitHub Release with the
zip attached, and uploads the same zip to CurseForge with that changelog
section as the file notes.

Patch releases are encouraged: a one-line fix deserves its own tag rather than
waiting for a batch.

CurseForge upload needs three things, set once:

- `## X-Curse-Project-ID` in the TOC: the project id from the CurseForge project page.
- Repository secret `CF_API_KEY`: a CurseForge API token. Never commit it.
- Optional repository variables: `CF_GAME_VERSION` (for example `1.60.1`; defaults to the newest Forever version) and `CF_RELEASE_TYPE` (`alpha`, `beta` or `release`; defaults to `beta`).

Without the id or the token the workflow skips the upload and says so in the
run summary. `.\package.ps1` builds the same zip locally into `dist/`.
