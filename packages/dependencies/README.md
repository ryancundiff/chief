# chief/dependencies

The Dependencies extension for [Chief](https://github.com/ryancundiff/Chief): topological dependency injection.

Modules declare dependencies with `Dependencies.use(moduleScript)` markers assigned to fields on their module table. During boot the extension:

1. **Transitively loads** any dependency that wasn't explicitly added to Chief (during `PostLoad`).
2. **Topologically sorts** the dependency graph (Kahn's algorithm) at `PreInit`, so every module's `Init` runs *after* the `Init` of everything it depends on. `Priority` breaks ties between modules with no ordering constraint between them.
3. **Errors with the full cycle path** if a dependency cycle exists, instead of silently producing a broken order.
4. **Injects** the real, required module into every marker field — by the time `Init` runs, `self.Data` is the actual module, not a proxy.

## Installation

```sh
pesde add chief/dependencies
```

## Usage

Register the extension:

```luau
--!strict

local Chief = require('path/to/core')
local Dependencies = require('path/to/dependencies')

Chief.new()
	:AddModules(script.Modules:GetChildren())
	:AddExtension(Dependencies.new())
	:Start()
```

Declare dependencies as fields on the module table. Cast with `typeof(require(...))` for full types — Luau evaluates that at type level only, so it does not cause a runtime circular require:

```luau
--!strict

local Dependencies = require('path/to/dependencies')

local ShopModule = {}

ShopModule.Data = Dependencies.use(script.Parent.DataModule) :: typeof(require(script.Parent.DataModule))

function ShopModule.Init (self: Self)
	-- self.Data is the real DataModule, and its Init has already run.
	self.Data:Get('coins')
end

type Self = typeof(ShopModule)

return ShopModule
```

## API

### `Dependencies.use(moduleScript: ModuleScript): any`

Declares a dependency on another module. Returns a marker table; assign it to a field on your module table and the extension replaces the field with the real module during boot, before any `Init` runs.

### `Dependencies.new(): Extension`

Creates the Dependencies extension. Add it to Chief with `AddExtension`. Each instance tracks the state of a single boot — create one per Chief instance rather than sharing an instance between them.

Registration order relative to other module-loading extensions does not matter: ordering and injection run at `PreInit`, after every extension's `PostLoad` loading has finished.

## Rules

- **Markers must be assigned to fields on the module table, never to locals.** The extension injects by replacing fields; a local holding a marker can't be reached.
- **Circular requires can't happen** — `use` takes the ModuleScript, not a require, so module bodies never require each other. Circular *dependencies* are still impossible to order and are reported as an error (`CyclicDependency`) with the offending path, e.g. `Shop -> Data -> Shop`.
- **Do not `table.freeze` a module that declares dependencies** — injection writes to its fields (`FrozenModule` error otherwise).

## Errors

- `BadArgument:` — `use` received something other than a ModuleScript.
- `MissingDependency:` — a module declares a dependency that was never loaded (possible when a later-registered extension loads modules after this extension's `PostLoad` walk). Add the dependency to Chief directly.
- `CyclicDependency:` — the dependency graph contains a cycle; the message includes the cycle path. Break it by moving the cross-calls out of `Init`, or invert one of the dependencies.
- `FrozenModule:` — injection target module table is frozen.

## License

MIT
