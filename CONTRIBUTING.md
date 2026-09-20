# Contributing

Short version of how this addon is built, checked and shipped. The
[README](./README.md) has the architecture and the module contract.

## Local setup

```powershell
git clone https://github.com/Moose-Ltd/MooseMode.git
cd MooseMode
.\install.ps1          # junction MooseMode/ into the beta AddOns folder (-Path for another install)
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

## Shipping

1. Bump `## Version` in `MooseMode/MooseMode.toc` (keep the `-forever` suffix).
2. Add the release to `CHANGELOG.md`.
3. Commit, then tag and push: `git tag v1.2.0-forever && git push origin main --tags`.
4. [`release.yml`](./.github/workflows/release.yml) checks the tag matches the TOC, builds `MooseMode-<version>.zip` and attaches it to a GitHub Release.
5. Upload that zip to CurseForge under the Forever flavour, game version 1.60.1.

`.\package.ps1` builds the same zip locally into `dist/`.
