# Chief

[![CI](https://github.com/ryancundiff/chief/actions/workflows/ci.yml/badge.svg)](https://github.com/ryancundiff/chief/actions/workflows/ci.yml)

A strictly and fully typed, tested Luau module framework for Roblox, inspired by [Sleitnick's Knit](https://github.com/Sleitnick/Knit). Modules are much like Knit's services and controllers: each has an `Init` and `Start` lifecycle, and more lifecycles can be added with the Lifecycles extension.

The core is intentionally small — it loads modules, runs the Init/Start boot barrier, and fires hooks. Everything else (Roblox event lifecycles, dependency injection, etc.) lives in extensions that attach to those hooks. The core has no knowledge of RunService events, players, or dependency graphs.

## Packages

| Package | Description |
| --- | --- |
| [`chief/core`](packages/core) | The framework core: loads modules, runs the Init/Start barrier, and fires hooks for extensions. |
| [`chief/lifecycles`](packages/lifecycles) | Binds events (`PlayerAdded`, `Heartbeat`, custom) to module methods. |
| [`chief/dependencies`](packages/dependencies) | Dependency injection with transitive loading and topological `Init` ordering. |
| [`chief/traits`](packages/traits) | Binds per-instance behavior to CollectionService tags, with typed attribute and child contracts. |

## Installation

Install with [pesde](https://pesde.dev):

```sh
pesde add chief/core
pesde add chief/lifecycles   # optional
pesde add chief/dependencies # optional
pesde add chief/traits       # optional
```

## Quick start

A bootstrap script creates a Chief instance, adds modules and extensions, then starts:

```luau
--!strict

local Chief = require('./roblox_packages/core')
local Dependencies = require('./roblox_packages/dependencies')
local Lifecycles = require('./roblox_packages/lifecycles')

Chief.new()
	:AddModules(script.Modules:GetChildren())
	:AddExtensions({
		Dependencies.new(),
		Lifecycles.new({
			Lifecycles.PlayerAdded,
			Lifecycles.Heartbeat,
		}),
	})
	:Start()
```

A module is a plain table with optional `Init` and `Start` methods:

```luau
--!strict

local DataModule = {}

function DataModule.Init (self: Self)
	-- Runs synchronously, in order, before any module's Start. Yielding here errors.
end

function DataModule.Start (self: Self)
	-- Spawned concurrently after every module's Init has completed.
end

type Self = typeof(DataModule)

return DataModule
```

## Boot sequence

`Chief:Start()` runs the following phases in order:

```
PreLoad → Load → PostLoad → PreInit → Init → PostInit → PreStart → Start → PostStart
```

- Every module's `Init` runs **synchronously and in order** (the "init barrier" — yielding during `Init` errors).
- Every module's `Start` is **spawned concurrently** afterward.
- Modules are sorted by `Priority` (higher first); ties break by insertion order.

## Extensions

Extensions attach behavior through two hooks:

- `onPhase(chief, phase, entries)` — fired at each boot phase with every entry loaded so far.
- `onModule(chief, event, entry)` — fired per module as it is `Loaded`, `Initialized`, and `Started`.

During `PostLoad`, extensions may call `chief:LoadModule` to pull in additional modules; loading closes after `PostLoad`. Extensions may reorder `entries` in place during `PostLoad` or `PreInit` — after `PreInit` the order is final.

See the [core README](packages/core) for the full extension contract.

## Development

This repository is a pesde workspace (`workspace_members = ["packages/*"]`).

- **Format**: [StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua.toml`)
- **Lint**: [selene](https://github.com/Kampfkarren/selene) (`selene.toml`, `std = "roblox+testez"`)
- **Test**: [TestEZ](https://github.com/Roblox/testez) specs under `tests/`, executed in real Roblox by CI via the [Open Cloud Luau Execution API](https://create.roblox.com/docs/cloud/reference/LuauExecutionSessionTask)
- `roblox_packages/` and `pesde.lock` are generated and gitignored — never edit them.

## License

MIT
