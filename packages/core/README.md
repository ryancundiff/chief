# chief/core

The core of [Chief](https://github.com/ryancundiff/Chief), a strictly and fully typed Luau module framework for Roblox. It loads modules, runs the Init/Start boot barrier, and fires hooks for extensions — nothing else. Roblox event lifecycles, dependency injection, and everything domain-specific live in extensions.

## Installation

```sh
pesde add chief/core
```

## Usage

```luau
--!strict

local Chief = require('path/to/core')

Chief.new()
	:AddModules(script.Modules:GetChildren())
	:Start()
```

A module is a plain table. `Init`, `Start`, and `Priority` are all optional:

```luau
--!strict

local DataModule = {}

DataModule.Priority = 10 -- Higher initializes first (default 0).

function DataModule.Init (self: Self)
	-- Runs synchronously, in order, before any module's Start.
	-- Yielding here errors (NoYield) -- it would break the barrier for every module after.
end

function DataModule.Start (self: Self)
	-- Spawned concurrently after every module's Init has completed.
	-- Safe to yield here.
end

type Self = typeof(DataModule)

return DataModule
```

## Boot sequence

`Chief:Start()` runs the following, in order:

1. `PreLoad` phase
2. Every added ModuleScript is required (`Loaded` fires per module)
3. Entries are stably sorted by `Priority` (higher first; ties break by insertion order)
4. `PostLoad` phase — extensions may load extra modules here; loading closes afterward
5. `PreInit` phase — extensions may reorder entries here
6. Every module's `Init` runs synchronously, in order (`Initialized` fires per module)
7. `PostInit` phase
8. `PreStart` phase
9. Every module's `Start` is spawned concurrently (`Started` fires per module)
10. `PostStart` phase

## API

### `Chief.new(options: Options?): Chief`

Creates a new Chief instance. `options.Verbose` (default `true`) controls the boot summary print, e.g. `Chief (Server) started 12 modules in 3ms`.

### `Chief:AddModule(moduleScript: ModuleScript): Chief`

Adds a module. Chainable. Adding the same ModuleScript twice is a no-op. Errors (`BadCall`) after `Start`.

### `Chief:AddModules(moduleScripts: { ModuleScript }): Chief`

Adds an array of modules. Chainable.

### `Chief:AddExtension(extension: Extension): Chief`

Registers an extension. Chainable. Errors (`BadCall`) after `Start`.

### `Chief:AddExtensions(extensions: { Extension }): Chief`

Registers an array of extensions. Chainable.

### `Chief:LoadModule(moduleScript: ModuleScript): Entry`

Loads a single module immediately and fires its `Loaded` event; returns the existing entry if already loaded. Primarily for extension authors — only callable during the Load/PostLoad window. An entry loaded during `PostLoad` is appended in load order (its `Priority` is not re-applied); reorder `entries` in an `onPhase` hook when ordering matters.

### `Chief:Start(): Chief`

Runs the boot sequence. Calling twice errors (`BadCall`) rather than double-initializing. Chainable.

## Writing an extension

An extension is a table with a `Name` and up to two hooks:

```luau
export type Extension = {
	Name: string,
	onPhase: ((chief: Chief.Self, phase: Phase, entries: { Entry }) -> ())?,
	onModule: ((chief: Chief.Self, event: ModuleEvent, entry: Entry) -> ())?,
}
```

- `onPhase(chief, phase, entries)` — fired at each boot phase (`PreLoad`, `PostLoad`, `PreInit`, `PostInit`, `PreStart`, `PostStart`) with every entry loaded so far.
- `onModule(chief, event, entry)` — fired per module as it is `Loaded`, `Initialized`, and `Started`.

Rules of the road:

- During `PostLoad`, an extension may call `chief:LoadModule` to pull in additional modules. Loading closes once `PostLoad` finishes.
- During `PostLoad` or `PreInit`, an extension may reorder `entries` **in place** to control `Init` order. Once `PreInit` finishes, the order is final.

```luau
local function makeLoggerExtension (): Chief.Extension
	return {
		Name = 'Logger',
		onModule = function (_chief, event, entry)
			if event == 'Initialized' then
				print(`{entry.Name} initialized`)
			end
		end,
	}
end
```

See [chief/lifecycles](https://github.com/ryancundiff/Chief/tree/main/packages/lifecycles) and [chief/dependencies](https://github.com/ryancundiff/Chief/tree/main/packages/dependencies) for full extension examples.

## Types

| Type | Description |
| --- | --- |
| `Module` | `{ Init: ((Module) -> ())?, Start: ((Module) -> ())?, Priority: number?, [any]: any }` |
| `Entry` | `{ Name: string, ModuleScript: ModuleScript, Module: Module }` |
| `Phase` | `'PreLoad' \| 'PostLoad' \| 'PreInit' \| 'PostInit' \| 'PreStart' \| 'PostStart'` |
| `ModuleEvent` | `'Loaded' \| 'Initialized' \| 'Started'` |
| `Extension` | `{ Name: string, onPhase: (...)?, onModule: (...)? }` |
| `Options` | `{ Verbose: boolean? }` |

## Errors

All thrown errors are prefixed with a category tag:

- `BadArgument:` — a method received a value of the wrong type or shape.
- `BadCall:` — a method was called at the wrong time (e.g. `AddModule` after `Start`, `LoadModule` outside the load window).
- `NoYield:` — a module yielded inside a synchronous step such as `Init`.

## License

MIT
