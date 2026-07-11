# chief/traits

The Traits extension for [Chief](https://github.com/ryancundiff/Chief): binds behavior to Roblox instances through CollectionService tags.

A trait is a regular Chief module carrying an `Info` contract. When an instance gains the trait's tag — and satisfies the declared instance class, attributes, and children — the extension constructs a bound object and runs its lifecycle. When the tag is removed or the instance is destroyed, the trait unbinds and cleans up after itself.

## Installation

```sh
pesde add chief/traits
```

## Usage

Register trait modules through `Traits.new` — **not** through `AddModules`. A trait's `Init`/`Start` receive a per-instance bound object, not the module itself, so Chief's boot loop (which calls `Init`/`Start` on every added module) must never see them:

```luau
--!strict

local Chief = require('path/to/chief')
local Traits = require('path/to/traits')

Chief.new()
	:AddModules(script.Modules:GetChildren())
	:AddExtension(Traits.new(script.Traits:GetChildren()))
	:Start()
```

A trait module declares its contract with `Traits.info` and implements per-instance lifecycle methods:

```luau
--!strict

local Traits = require('path/to/traits')

local Door = {}

Door.Info = Traits.info({
	Tag = 'Door',
	InstanceIs = 'BasePart',
	Attributes = {
		OpenAngle = Traits.attribute('number', 90), -- Has a default -> optional
		Locked = Traits.attribute('boolean'),       -- No default -> required
	},
	Children = {
		Prompt = Traits.child('ProximityPrompt', { Wait = 5 }),
	},
})

function Door.Init (self: Self)
	-- Synchronous, runs once per bound instance. Yielding here errors.
	self.Bin:Add(self.Prompt.Triggered:Connect(function ()
		self:Toggle()
	end))
end

function Door.Start (self: Self)
	-- Spawned after Init. Safe to yield or loop here; the thread is cancelled automatically when the trait unbinds.
end

function Door.Toggle (self: Self)
	if self.Attributes.Locked then
		return
	end

	print(`{self.Instance.Name} toggled by {self.Attributes.OpenAngle} degrees`)
end

function Door.AttributeChanged (self: Self, name: string, value: any)
	-- Optional: called when a declared attribute changes (self.Attributes is already updated).
end

function Door.Destroy (self: Self)
	-- Optional: runs on unbind, before the Bin empties itself. Yielding here errors.
end

type Self = typeof(Door) & Traits.BoundOf<typeof(Door.Info)>

return Door
```

`Traits.BoundOf` derives the whole bound object's type from the `Info` contract — at the type level, through [Luau type functions](https://luau.org/typecheck#type-functions) (requires the new type solver). In the example above, `Self` carries `Instance: BasePart`, `Attributes: { OpenAngle: number, Locked: boolean }`, `Bin` (a [`chief/bin`](../bin) Bin), and `Prompt: ProximityPrompt`, with no manual annotations. A malformed contract — a typo'd key, a bad attribute kind, a default that doesn't match its kind, a reserved child name — is a type error at the `Traits.info` call itself.

## Lifecycle

1. **Watching begins at `PostStart`** — after Chief's entire boot barrier. Every module is initialized before the first trait binds, so trait bodies can safely require and use any Chief module (traits don't need dependency injection: a plain `require` works).
2. **Bind** — when an instance has the tag and fulfills the contract: children are resolved (waiting up to `Wait` seconds if given), attributes are validated (defaults written back to the instance, so they show in Studio), then `Init` runs synchronously and `Start` is spawned.
3. **Unbind** — when the tag is removed or the instance is destroyed: `Destroy` runs, then the `Bin` empties — which also cancels a still-running `Start` thread. A bind still waiting on a child is simply cancelled.

An instance that fails the contract is **not** bound, and a warning names the exact requirement that failed — a tagged instance silently doing nothing is much harder to debug.

One erroring instance never breaks the others: lifecycle failures are contained per instance, reported with a full traceback.

## API

### `Traits.info(properties): Info`

Creates the trait's contract; assign it to the module's `Info` field (`Traits.new` requires every registered module to carry one). Validated eagerly — a malformed contract errors at require time.

- `Tag: string` — the CollectionService tag to watch.
- `InstanceIs: string?` — class (or superclass) the tagged instance must be. Defaults to `'Instance'`.
- `Attributes: { [string]: Attribute }?` — attribute requirements.
- `Children: { [string]: Child }?` — child requirements. Each key is both the child's expected `Name` and the field the resolved child is injected under on `self`.

### `Traits.attribute(kind, default?): Attribute`

Declares an attribute requirement. `kind` is a `typeof()` name (`'string'`, `'number'`, `'boolean'`, `'Vector3'`, `'Color3'`, `'CFrame'`, and every other Roblox attribute type). With a `default` the attribute is optional and the default is written to instances that lack it; without one it's required.

The kind literal is preserved at the type level: the derived bound object types the attribute's value (`'number'` becomes `number`), and `default` is checked against the kind where you write it.

### `Traits.child(className, options?): Child`

Declares a required child. `options.Wait` (seconds) waits for the child to appear — useful under StreamingEnabled — instead of failing immediately.

The class name literal is preserved at the type level: the derived bound object types the injected field (`'ProximityPrompt'` becomes `ProximityPrompt`). Common class names autocomplete; anything else is accepted and derives plain `Instance`.

### `Traits.new(moduleScripts): Extension`

Creates the extension, wiring the given trait ModuleScripts. Add it to Chief with `AddExtension`. Trait modules are required and validated eagerly, so a malformed trait fails at composition instead of surfacing later as an inert tag.

### `Traits.get(instance, trait): (BoundOf<typeof(trait.Info)> & typeof(trait))?`

The bound object a trait has attached to an instance, or nil. Fully typed: the shape is derived from the trait's `Info` contract, and the trait's own methods and fields are reachable on it.

### `Traits.getAll(trait): { BoundOf<typeof(trait.Info)> & typeof(trait) }`

Every bound object of a trait, in no particular order.

### `Traits.BoundOf<typeof(trait.Info)>`

The fully-typed bound object derived from an info contract's type: `Instance` resolved from `InstanceIs`, `Attributes` typed per attribute kind, `Bin`, and one field per declared child. Combine with the trait's own type for `self`: `type Self = typeof(Door) & Traits.BoundOf<typeof(Door.Info)>`.

## The bound object (`self`)

Lifecycle methods receive a per-instance object:

- `self.Instance` — the tagged instance.
- `self.Attributes` — a live, two-way view of the declared attribute values. Reads stay in sync as attributes change; writes validate against the contract and set the real attribute on the instance — `self.Attributes.OpenAngle = 45` behaves exactly like `self.Instance:SetAttribute('OpenAngle', 45)` (including firing `AttributeChanged`). Writing an undeclared name, a `nil`, or a wrong-typed value errors. Iteration works as normal.
- `self.Bin` — a cleanup container. `Bin:Add(item)` accepts a connection (disconnected), instance (destroyed), thread (cancelled), or function (called); everything is cleaned in reverse order automatically on unbind.
- One field per declared child (e.g. `self.Prompt`).
- Everything on the trait module itself, via the metatable.

Type it by intersection: `type Self = typeof(Door) & Traits.BoundOf<typeof(Door.Info)>`. (`Traits.Bound` remains as an untyped fallback for contracts that cannot be declared inline.)

## Errors and warnings

- `BadArgument:` — thrown when `new`, `info`, `attribute`, `child`, `get`, `getAll`, or `Bin:Add` receive the wrong shape (including reserved child names like `Instance`, `Bin`, `Init`, and modules passed to `new` without an `Info` contract).
- `BadInstance:` (warning) — a tagged instance failed the contract; names the failed requirement.
- `BadAttribute:` — thrown when writing to `self.Attributes` with an undeclared name, a `nil`, or a value of the wrong type. Also warned (not thrown) when an attribute changes externally to a wrong-typed value; that change is ignored.
- `TraitError:` — a trait's `Init` or `Destroy` errored (or yielded — both must be synchronous); reported with traceback, cleanup still runs.
- `DuplicateTrait:` (warning) — the same trait module was wired twice (e.g. added to two Chief instances).

## License

MIT