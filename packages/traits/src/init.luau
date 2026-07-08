--!strict

-- Roblox services.
local CollectionService = game:GetService('CollectionService')

local Chief = require('./roblox_packages/core')

--[=[
	The Traits extension: binds behavior to Roblox instances through CollectionService tags.

	A trait is a module carrying an `Info` contract created with `Traits.info`, registered through `Traits.new` -- never through `AddModules`. A trait's `Init`/`Start` receive a per-instance bound object, not the module itself, so Chief's boot loop (which calls `Init`/`Start` on every added module) must never see trait modules.

	When an instance gains the trait's tag (and satisfies the declared instance class, attributes, and children), the extension constructs a bound object and runs its lifecycle: `Init` (synchronous), then `Start` (spawned, cancelled automatically on unbind). `Destroy` runs when the tag is removed or the instance is destroyed, after which the bound object's `Bin` is emptied automatically.

	Watching begins at `PostStart` -- after the whole boot barrier -- so every module is initialized before the first trait binds, and trait bodies can safely require and use any Chief module.

	How to set up Traits:
	```
	Chief.new()
		:AddModules(script.Modules:GetChildren())
		:AddExtension(Traits.new(script.Traits:GetChildren()))
		:Start()
	```

	How to declare a trait:
	```
	local Door = {}

	Door.Info = Traits.info({
		Tag = 'Door',
		InstanceIs = 'BasePart',
		Attributes = {
			OpenAngle = Traits.attribute('number', 90),
			Locked = Traits.attribute('boolean'),
		},
		Children = {
			Prompt = Traits.child('ProximityPrompt', { Wait = 5 }),
		},
	})

	function Door.Init (self: Self)
		self.Bin:Add(self.Prompt.Triggered:Connect(function ()
			print(`{self.Instance.Name} toggled (angle {self.Attributes.OpenAngle})`)
		end))
	end

	type Self = typeof(Door) & Traits.Bound & { Prompt: ProximityPrompt }

	return Door
	```
]=]
local Traits = {}

--[[ HELPERS ]]

-- Unique, private marker keys. A local table can never collide with a key in user data, unlike a magic string field.
local INFO_MARKER = {}
local ATTRIBUTE_MARKER = {}
local CHILD_MARKER = {}

-- typeof() names for every attribute type Roblox supports.
local ATTRIBUTE_KINDS: { [string]: boolean } = {
	string = true,
	number = true,
	boolean = true,
	UDim = true,
	UDim2 = true,
	BrickColor = true,
	Color3 = true,
	Vector2 = true,
	Vector3 = true,
	CFrame = true,
	NumberSequence = true,
	ColorSequence = true,
	NumberRange = true,
	Rect = true,
	Font = true,
}

-- Field names the extension sets on bound objects, or that name trait lifecycle methods; children may not claim them.
local RESERVED_FIELDS: { [string]: boolean } = {
	Instance = true,
	Attributes = true,
	Bin = true,
	Info = true,
	Init = true,
	Start = true,
	Destroy = true,
	AttributeChanged = true,
}

-- Every bound object per trait, keyed by instance. Module-level so `Traits.get`/`Traits.getAll` work from anywhere, and so wiring the same trait twice can be detected.
local boundByTrait: { [Trait]: { [Instance]: Bound } } = {}

--[=[
	Calls `callback` protected: returns false plus a traceback when the callback errors or yields, true otherwise. Used to run trait lifecycle methods -- they must stay synchronous (a yielding `Init` would let `Destroy` race a half-initialized bound object; a yielding `Destroy` would race its own Bin cleanup), and one erroring instance must not break the watcher for others.

	@param stepName string -- The lifecycle step being called, for the NoYield message.
	@param callback (...any) -> ()
	@param ... any
	@return (boolean, string?)
]=]
local function callProtected (stepName: string, callback: (...any) -> (), ...: any): (boolean, string?)
	local thread = coroutine.create(callback)

	local ok, message = coroutine.resume(thread, ...)

	-- Traceback must be captured before close: closing wipes the thread's stack, and forces a suspended (yielded) thread's status to 'dead'.
	if not ok then
		local traceback = debug.traceback(thread, message)
		coroutine.close(thread)

		return false, traceback
	end

	if coroutine.status(thread) ~= 'dead' then
		local traceback =
			debug.traceback(thread, `NoYield: Attempted to yield inside a synchronous Traits step (eg. {stepName})`)
		coroutine.close(thread)

		return false, traceback
	end

	return true, nil
end

--[=[
	Returns whether `value` is an info contract produced by `Traits.info`.

	@param value unknown
	@return boolean
]=]
local function isInfo (value: unknown): boolean
	return typeof(value) == 'table' and (value :: any)[INFO_MARKER] == true
end

--[=[
	Returns whether `value` is an attribute marker produced by `Traits.attribute`.

	@param value unknown
	@return boolean
]=]
local function isAttribute (value: unknown): boolean
	return typeof(value) == 'table' and (value :: any)[ATTRIBUTE_MARKER] == true
end

--[=[
	Returns whether `value` is a child marker produced by `Traits.child`.

	@param value unknown
	@return boolean
]=]
local function isChild (value: unknown): boolean
	return typeof(value) == 'table' and (value :: any)[CHILD_MARKER] == true
end

--[=[
	Warns that an instance failed the trait's contract and will not be bound. Loud on purpose: a tagged instance silently doing nothing is much harder to debug than a warning naming the exact requirement that failed.

	@param traitName string
	@param instance Instance
	@param reason string
]=]
local function warnBindFailure (traitName: string, instance: Instance, reason: string)
	warn(`BadInstance: Cannot bind trait '{traitName}' to {instance:GetFullName()} ({reason})`)
end

--[[ BIN ]]

--[=[
	A small cleanup container attached to every bound object as `self.Bin`. Whatever is added is cleaned up automatically when the trait unbinds (connections disconnected, instances destroyed, threads cancelled functions called), in reverse insertion order.
]=]
local Bin = {}
local binMt = { __index = Bin }

--[=[
	Create an empty Bin.

	@return Bin
]=]
function Bin.new (): Bin
	return setmetatable({
		_Items = {},
	}, binMt) :: Bin
end

--[=[
	Add an item to clean up when the Bin is emptied. Returns the item so adds can wrap assignments.

	@param item BinItem -- A connection, instance, thread, or function.
	@return BinItem

	@error BadArgument -- Thrown when `item` is not a BinItem.
]=]
function Bin.Add (self: Bin, item: BinItem): BinItem
	local itemType = typeof(item)

	assert(
		itemType == 'RBXScriptConnection' or itemType == 'Instance' or itemType == 'thread' or itemType == 'function',
		`BadArgument: Bad argument #1 for Add (expected RBXScriptConnection, Instance, thread, or function, got {itemType})`
	)

	table.insert(self._Items, item)

	return item
end

--[=[
	Clean up every item and empty the Bin, in reverse insertion order. The Bin remains usable afterward. Called automatically when the trait unbinds.
]=]
function Bin.Empty (self: Bin)
	for index = #self._Items, 1, -1 do
		local item = self._Items[index]
		local itemType = typeof(item)

		if itemType == 'RBXScriptConnection' then
			(item :: RBXScriptConnection):Disconnect()
		elseif itemType == 'Instance' then
			(item :: Instance):Destroy()
		elseif itemType == 'thread' then
			task.cancel(item :: thread)
		else
			(item :: () -> ())()
		end
	end

	table.clear(self._Items)
end

--[[ BINDING ]]

--[=[
	Wires one trait: watches its tag, binds every present and future tagged instance that fulfills the contract, and unbinds on tag removal. Called once per trait at `PostStart`.

	@param traitName string
	@param trait Trait
]=]
local function wireTrait (traitName: string, trait: Trait)
	if boundByTrait[trait] ~= nil then
		warn(
			`DuplicateTrait: Trait '{traitName}' is already wired (was the same trait module passed to more than one Traits.new?)`
		)
		return
	end

	local info = trait.Info
	local boundOf: { [Instance]: Bound } = {}
	local pendingOf: { [Instance]: thread } = {}
	local mt = { __index = trait }

	boundByTrait[trait] = boundOf

	local function bind (instance: Instance)
		if not instance:IsA(info.InstanceIs) then
			pendingOf[instance] = nil
			warnBindFailure(traitName, instance, `expected {info.InstanceIs}, got {instance.ClassName}`)

			return
		end

		-- Resolve children first: they are the only step allowed to yield (via Wait), and everything after must run without interruption.
		local children: { [string]: Instance } = {}

		for childName, child in info.Children do
			local found = instance:FindFirstChild(childName)

			if found == nil and child.Wait ~= nil then
				found = instance:WaitForChild(childName, child.Wait)
			end

			if found == nil then
				pendingOf[instance] = nil
				warnBindFailure(traitName, instance, `missing child '{childName}' (expected {child.ClassName})`)

				return
			end

			if not found:IsA(child.ClassName) then
				pendingOf[instance] = nil
				warnBindFailure(
					traitName,
					instance,
					`child '{childName}' expected {child.ClassName}, got {found.ClassName}`
				)

				return
			end

			children[childName] = found
		end

		-- Validate attributes; write defaults back so they show in Studio.
		local attributes: { [string]: any } = {}

		for attributeName, attribute in info.Attributes do
			local value = instance:GetAttribute(attributeName)

			if value == nil and attribute.Default ~= nil then
				instance:SetAttribute(attributeName, attribute.Default)
				value = attribute.Default
			end

			if value == nil then
				pendingOf[instance] = nil
				warnBindFailure(
					traitName,
					instance,
					`missing required attribute '{attributeName}' (expected {attribute.Kind})`
				)

				return
			end

			if typeof(value) ~= attribute.Kind then
				pendingOf[instance] = nil
				warnBindFailure(
					traitName,
					instance,
					`attribute '{attributeName}' expected {attribute.Kind}, got {typeof(value)}`
				)

				return
			end

			attributes[attributeName] = value
		end

		local bin = Bin.new()

		local bound = setmetatable({
			Instance = instance,
			Attributes = attributes,
			Bin = bin,
		}, mt) :: any

		for childName, child in children do
			bound[childName] = child
		end

		local init = trait.Init

		if typeof(init) == 'function' then
			local ok, message = callProtected('Init', init, bound)

			-- A failed Init must not kill the watcher or leak the Bin; clean up, then re-raise so the failure is loud.
			if not ok then
				bin:Empty()
				pendingOf[instance] = nil

				error(`TraitError: Init of trait '{traitName}' failed for {instance:GetFullName()}\n{message}`, 0)
			end
		end

		-- Keep Attributes in sync and dispatch the optional AttributeChanged method. Wired after Init so handlers never see a half-bound object.
		bin:Add(instance.AttributeChanged:Connect(function (attributeName: string)
			local attribute = info.Attributes[attributeName]

			if attribute == nil then
				return
			end

			local value = instance:GetAttribute(attributeName)

			if value ~= nil and typeof(value) ~= attribute.Kind then
				warn(
					`BadAttribute: Ignoring change to attribute '{attributeName}' on {instance:GetFullName()} (expected {attribute.Kind}, got {typeof(
						value
					)})`
				)

				return
			end

			bound.Attributes[attributeName] = value

			local attributeChanged = trait.AttributeChanged

			if typeof(attributeChanged) == 'function' then
				attributeChanged(bound, attributeName, value)
			end
		end))

		boundOf[instance] = bound
		pendingOf[instance] = nil

		local start = trait.Start

		-- The Start thread goes in the Bin so a looping Start is cancelled on unbind (cancelling an already-dead thread is a no-op).
		if typeof(start) == 'function' then
			bin:Add(task.spawn(start, bound))
		end
	end

	local function tryBind (instance: Instance)
		if boundOf[instance] ~= nil or pendingOf[instance] ~= nil then
			return
		end

		local thread = task.spawn(bind, instance)

		-- Still suspended means bind is waiting on a child; remember the thread so unbind can cancel the wait if the tag is removed first.
		if coroutine.status(thread) == 'suspended' then
			pendingOf[instance] = thread
		end
	end

	local function unbind (instance: Instance)
		local pending = pendingOf[instance]

		if pending ~= nil then
			pendingOf[instance] = nil
			task.cancel(pending)
		end

		local bound = boundOf[instance]

		if bound == nil then
			return
		end

		boundOf[instance] = nil

		local destroy = trait.Destroy

		if typeof(destroy) == 'function' then
			local ok, message = callProtected('Destroy', destroy, bound)

			-- Destroy failing must not skip the Bin cleanup below.
			if not ok then
				warn(`TraitError: Destroy of trait '{traitName}' failed for {instance:GetFullName()}\n{message}`)
			end
		end

		bound.Bin:Empty()
	end

	-- Chief has no teardown hook and is a boot-time singleton, so these connections live for the session.
	CollectionService:GetInstanceAddedSignal(info.Tag):Connect(tryBind)
	CollectionService:GetInstanceRemovedSignal(info.Tag):Connect(unbind)

	for _, instance in CollectionService:GetTagged(info.Tag) do
		tryBind(instance)
	end
end

--[[ METHODS ]]

--[=[
	Create a trait's info contract: the requirements an instance must fulfill before the trait binds to it. Assign the result to the `Info` field of a trait module; `Traits.new` requires every registered module to carry one.

	Validation happens here, when the trait module is required, so a malformed contract fails at load with a precise error instead of surfacing later as an inert trait.

	**Properties**
	- `Tag` -- The CollectionService tag to watch.
	- `InstanceIs` -- Class (or superclass) the tagged instance must be. Defaults to 'Instance'.
	- `Attributes` -- Map of attribute name to `Traits.attribute` marker.
	- `Children` -- Map of child name to `Traits.child` marker. The bound object gains a field of the same name holding the resolved child.

	@param properties InfoProperties
	@return Info

	@error BadArgument -- Thrown when `properties` is not a valid `InfoProperties`.
]=]
function Traits.info (properties: InfoProperties): Info
	assert(
		typeof(properties) == 'table',
		`BadArgument: Bad argument #1 for info (expected table, got {typeof(properties)})`
	)

	assert(
		typeof(properties.Tag) == 'string' and #properties.Tag > 0,
		`BadArgument: Bad argument #1 for info (Tag: expected non-empty string, got {typeof(properties.Tag)})`
	)

	assert(
		properties.InstanceIs == nil or typeof(properties.InstanceIs) == 'string',
		`BadArgument: Bad argument #1 for info (InstanceIs: expected string or nil, got {typeof(properties.InstanceIs)})`
	)

	local attributes: { [string]: Attribute } = {}

	if properties.Attributes ~= nil then
		assert(
			typeof(properties.Attributes) == 'table',
			`BadArgument: Bad argument #1 for info (Attributes: expected table or nil, got {typeof(
				properties.Attributes
			)})`
		)

		for name, attribute in properties.Attributes do
			assert(
				typeof(name) == 'string',
				`BadArgument: Bad argument #1 for info (Attributes: expected string keys, got {typeof(name)})`
			)

			assert(
				isAttribute(attribute),
				`BadArgument: Bad argument #1 for info (Attributes.{name}: expected Traits.attribute marker, got {typeof(
					attribute
				)})`
			)

			attributes[name] = attribute
		end
	end

	local children: { [string]: Child } = {}

	if properties.Children ~= nil then
		assert(
			typeof(properties.Children) == 'table',
			`BadArgument: Bad argument #1 for info (Children: expected table or nil, got {typeof(properties.Children)})`
		)

		for name, child in properties.Children do
			assert(
				typeof(name) == 'string',
				`BadArgument: Bad argument #1 for info (Children: expected string keys, got {typeof(name)})`
			)

			assert(
				not RESERVED_FIELDS[name],
				`BadArgument: Bad argument #1 for info (Children.{name}: name is reserved on bound objects)`
			)

			assert(
				isChild(child),
				`BadArgument: Bad argument #1 for info (Children.{name}: expected Traits.child marker, got {typeof(
					child
				)})`
			)

			children[name] = child
		end
	end

	local info = {
		Tag = properties.Tag,
		InstanceIs = properties.InstanceIs or 'Instance',
		Attributes = attributes,
		Children = children,
	} :: any

	info[INFO_MARKER] = true

	return table.freeze(info) :: Info
end

--[=[
	Declare a required attribute inside `Traits.info`. With a `default`, the attribute is optional and the default is written back to instances that lack it (so it shows in Studio); without one, instances missing the attribute fail the contract.

	@param kind AttributeKind -- The typeof() name the attribute must have, eg. 'number'.
	@param default any? -- Optional default value; must match `kind`.
	@return Attribute

	@error BadArgument -- Thrown when `kind` is not an `AttributeKind`, or `default` does not match it.
]=]
function Traits.attribute (kind: AttributeKind, default: any?): Attribute
	assert(
		typeof(kind) == 'string' and ATTRIBUTE_KINDS[kind] == true,
		`BadArgument: Bad argument #1 for attribute (expected AttributeKind, got {if typeof(kind) == 'string'
			then kind
			else typeof(kind)})`
	)

	assert(
		default == nil or typeof(default) == kind,
		`BadArgument: Bad argument #2 for attribute (expected {kind} or nil, got {typeof(default)})`
	)

	local attribute = {
		Kind = kind,
		Default = default,
	} :: any

	attribute[ATTRIBUTE_MARKER] = true

	return table.freeze(attribute) :: Attribute
end

--[=[
	Declare a required child inside `Traits.info`. The key it is assigned to in `Children` is both the child's expected `Name` and the field the resolved child is injected under on the bound object.

	@param className string -- Class (or superclass) the child must be.
	@param options ChildOptions? -- `Wait` (seconds) waits for the child to appear (eg. under StreamingEnabled) instead of failing immediately.
	@return Child

	@error BadArgument -- Thrown when `className` is not a non-empty string, or `options` is not a `ChildOptions` or nil.
]=]
function Traits.child (className: string, options: ChildOptions?): Child
	assert(
		typeof(className) == 'string' and #className > 0,
		`BadArgument: Bad argument #1 for child (expected non-empty string, got {typeof(className)})`
	)

	if options ~= nil then
		assert(
			typeof(options) == 'table',
			`BadArgument: Bad argument #2 for child (expected ChildOptions or nil, got {typeof(options)})`
		)

		assert(
			options.Wait == nil or (typeof(options.Wait) == 'number' and options.Wait > 0),
			`BadArgument: Bad argument #2 for child (Wait: expected positive number or nil, got {typeof(options.Wait)})`
		)
	end

	local child = {
		ClassName = className,
		Wait = if options ~= nil then options.Wait else nil,
	} :: any

	child[CHILD_MARKER] = true

	return table.freeze(child) :: Child
end

--[=[
	Create the Traits extension, wiring the given trait modules. Add it to Chief with `AddExtension`.

	Trait modules are required and validated here, eagerly, so a malformed trait fails at composition instead of surfacing later as an inert tag. Do not also add them to Chief with `AddModules`: a trait's `Init`/`Start` receive the bound object, not the module, so Chief's boot loop must never call them.

	Tag watching itself waits for `PostStart`. Binding therefore never races the boot barrier: by the time any trait binds, every module's `Init` has run and `Start` has been spawned.

	@param moduleScripts { ModuleScript } -- Array of trait modules.
	@return Extension

	@error BadArgument -- Thrown when `moduleScripts` is not an array of ModuleScripts, or a module lacks an `Info` contract.
]=]
function Traits.new (moduleScripts: { ModuleScript }): Chief.Extension
	assert(
		typeof(moduleScripts) == 'table',
		`BadArgument: Bad argument #1 for new (expected table, got {typeof(moduleScripts)})`
	)

	local traits: { { Name: string, Trait: Trait } } = {}

	for index, moduleScript in moduleScripts do
		assert(
			typeof(index) == 'number',
			`BadArgument: Bad argument #1 for new (expected array, got key of type {typeof(index)})`
		)

		assert(
			typeof(moduleScript) == 'Instance' and moduleScript:IsA('ModuleScript'),
			`BadArgument: Bad argument #1 for new (expected ModuleScript at index {index}, got {typeof(moduleScript)})`
		)

		local trait = require(moduleScript) :: any

		assert(
			typeof(trait) == 'table',
			`BadArgument: Bad argument #1 for new ({moduleScript.Name}: expected module to return a table, got {typeof(
				trait
			)})`
		)

		assert(
			isInfo(trait.Info),
			`BadArgument: Bad argument #1 for new ({moduleScript.Name}: expected an Info contract made with Traits.info, got {typeof(
				trait.Info
			)})`
		)

		table.insert(traits, { Name = moduleScript.Name, Trait = trait :: Trait })
	end

	local function onPhase (_chief: Chief.Self, phase: Chief.Phase, _entries: { Chief.Entry })
		if phase ~= 'PostStart' then
			return
		end

		for _, registered in traits do
			wireTrait(registered.Name, registered.Trait)
		end
	end

	return {
		Name = 'Traits',
		onPhase = onPhase,
	}
end

--[=[
	Get the bound object a trait has attached to an instance, or nil when the trait is not (or not yet) bound to it.

	@param instance Instance
	@param trait Trait -- The trait module table.
	@return Bound?

	@error BadArgument -- Thrown when `instance` is not an Instance or `trait` is not a table.
]=]
function Traits.get (instance: Instance, trait: Trait): Bound?
	assert(
		typeof(instance) == 'Instance',
		`BadArgument: Bad argument #1 for get (expected Instance, got {typeof(instance)})`
	)

	assert(typeof(trait) == 'table', `BadArgument: Bad argument #2 for get (expected table, got {typeof(trait)})`)

	local boundOf = boundByTrait[trait]

	if boundOf == nil then
		return nil
	end

	return boundOf[instance]
end

--[=[
	Get every bound object of a trait, in no particular order.

	@param trait Trait -- The trait module table.
	@return { Bound }

	@error BadArgument -- Thrown when `trait` is not a table.
]=]
function Traits.getAll (trait: Trait): { Bound }
	assert(typeof(trait) == 'table', `BadArgument: Bad argument #1 for getAll (expected table, got {typeof(trait)})`)

	local all: { Bound } = {}
	local boundOf = boundByTrait[trait]

	if boundOf ~= nil then
		for _, bound in boundOf do
			table.insert(all, bound)
		end
	end

	return all
end

--[[ TYPES ]]

--[=[
	The typeof() name of a Roblox attribute type.
]=]
export type AttributeKind =
	'string'
	| 'number'
	| 'boolean'
	| 'UDim'
	| 'UDim2'
	| 'BrickColor'
	| 'Color3'
	| 'Vector2'
	| 'Vector3'
	| 'CFrame'
	| 'NumberSequence'
	| 'ColorSequence'
	| 'NumberRange'
	| 'Rect'
	| 'Font'

--[=[
	An attribute requirement produced by `Traits.attribute`.
]=]
export type Attribute = {
	Kind: AttributeKind,
	Default: any,
}

--[=[
	A child requirement produced by `Traits.child`.
]=]
export type Child = {
	ClassName: string,
	Wait: number?,
}

--[=[
	Options for `Traits.child`.

	**Properties**
	- `Wait` -- Seconds to wait for the child to appear before failing the contract.
]=]
export type ChildOptions = {
	Wait: number?,
}

--[=[
	Properties accepted by `Traits.info`.
]=]
export type InfoProperties = {
	Tag: string,
	InstanceIs: string?,
	Attributes: { [string]: Attribute }?,
	Children: { [string]: Child }?,
}

--[=[
	A trait's validated info contract, produced by `Traits.info`.
]=]
export type Info = {
	Tag: string,
	InstanceIs: string,
	Attributes: { [string]: Attribute },
	Children: { [string]: Child },
}

--[=[
	A trait module: a module table carrying an `Info` contract, registered through `Traits.new`. `Init`, `Start`, `Destroy`, and `AttributeChanged` are all optional per-instance lifecycle methods, each receiving the bound object.
]=]
export type Trait = {
	Info: Info,
	Init: ((any) -> ())?,
	Start: ((any) -> ())?,
	Destroy: ((any) -> ())?,
	AttributeChanged: ((any, string, any) -> ())?,
	[any]: any,
}

--[=[
	An item a Bin can clean up: a connection (disconnected), instance (destroyed), thread (cancelled), or function (called).
]=]
export type BinItem = RBXScriptConnection | Instance | thread | () -> ()

--[=[
	A cleanup container. Every bound object carries one as `self.Bin`; it is emptied automatically when the trait unbinds.
]=]
export type Bin = setmetatable<{
	--[=[
		Items to clean up, in insertion order. Used internally by Bin.

		@private
	]=]
	_Items: { BinItem },
}, typeof(binMt)>

--[=[
	The per-instance object a trait's lifecycle methods receive as `self`. Fields declared in the contract's `Children` are injected under their own names; trait methods and data are reachable through the metatable. Combine with your trait's type for full typing:
	```
	type Self = typeof(Door) & Traits.Bound & { Prompt: ProximityPrompt }
	```
]=]
export type Bound = {
	Instance: Instance,
	Attributes: { [string]: any },
	Bin: Bin,
	[any]: any,
}

return Traits
