--!strict

-- Roblox services.
local RunService = game:GetService('RunService')

--[=[
	The Chief class.

	Chief's core is intentionally small: it loads modules, runs the Init/Start barrier, and fires hooks. Everything else (Roblox event lifecycles, dependency injection, etc.) lives in extensions that attach to those hooks. This keeps the core decoupled -- it has no knowledge of RunService events, players, or dependency graphs.

	How to set up Chief:
	```
	Chief.new()
		:AddModules(script.Modules:GetChildren())
		:AddExtensions({
			Dependencies.new(),
			Lifecycles.new({
				Lifecycles.PlayerAdded,
				Lifecycles.PlayerRemoving
				-- There's more out-of-the-box lifecycles:
				-- PreRender
				-- PreSimulation
				-- Heartbeat
			})
		})
	```

]=]
local Chief = {}
local mt = { __index = Chief }

--[[ HELPERS ]]

--[=[
	Runs `callback` and errors if it yields. Used to enforce the synchronous init contract. A module that yields during init would silently break the init/start barrier for every module after it.

	@param callback (A...) -> R...
	@param ... A...
]=]
local function noYield <A..., R...>(callback: (A...) -> R..., ...: A...)
	local thread = coroutine.create(callback)

	local ok, message = coroutine.resume(thread, ...)

	-- Traceback must be captured before close: closing wipes the thread's stack, and forces a suspended (yielded) thread's status to 'dead'.
	if not ok then
		local traceback = debug.traceback(thread, message)
		coroutine.close(thread)

		error(traceback, 3)
	end

	if coroutine.status(thread) ~= 'dead' then
		local traceback =
			debug.traceback(thread, 'NoYield: Attempted to yield inside a synchronous Chief step (eg. Init)')
		coroutine.close(thread)

		error(traceback, 3)
	end
end

--[=[
	Errors if `value` is not a ModuleScript.

	@param value unknown
	@param argumentNumber number
	@param methodName string
]=]
local function assertModuleScript (value: unknown, argumentNumber: number, methodName: string)
	assert(
		typeof(value) == 'Instance' and value:IsA('ModuleScript'),
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (expected ModuleScript, got {typeof(value)})`
	)
end

--[=[
	Errors if `value` is not an `Extension`.

	@param value unknown
	@param argumentNumber number
	@param methodName string
]=]
local function assertExtension (value: unknown, argumentNumber: number, methodName: string)
	assert(
		typeof(value) == 'table',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (expected table, got {typeof(value)})`
	)

	assert(
		typeof((value :: any).Name) == 'string',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (Name: expected string, got {typeof(
			(value :: any).Name
		)})`
	)

	assert(
		(value :: any).onPhase == nil or typeof(value.onPhase) == 'function',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (onPhase: expected function or nil, got {typeof(
			(value :: any).onPhase
		)})`
	)

	assert(
		(value :: any).onModule == nil or typeof(value.onModule) == 'function',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (onModule: expected function or nil, got {typeof(
			(value :: any).onModule
		)})`
	)
end

--[[ METHODS ]]

--[=[
	Create a new Chief instance.

	@param options Options? -- Optional settings. `Verbose` (default true) controls the boot summary print.
	@return Chief -- New Chief instance.

	@error BadArgument -- Thrown when `options` is not an `Options` or nil.
]=]
function Chief.new (options: Options?): Self
	if options ~= nil then
		assert(
			typeof(options) == 'table',
			`BadArgument: Bad argument #1 for new (expected Options or nil, got {typeof(options)})`
		)

		assert(
			options.Verbose == nil or typeof(options.Verbose) == 'boolean',
			`BadArgument: Bad argument #1 for new (Verbose: expected boolean or nil, got {typeof(options.Verbose)})`
		)
	end

	local isVerbose = true

	if options ~= nil and options.Verbose ~= nil then
		isVerbose = options.Verbose
	end

	local self = setmetatable({
		_ModuleScripts = {},
		_ModuleScriptSet = {},
		_Entries = {},
		_EntryByScript = {},
		_Extensions = {},
		_Phase = nil,
		_IsStarted = false,
		_IsVerbose = isVerbose,
	}, mt) :: Self

	return self
end

--[=[
	Add a module. Chainable. Adding the same ModuleScript twice is a no-op.

	@param moduleScript ModuleScript

	@error BadCall -- Thrown when attempt is made to add a module after Chief has started.
	@error BadArgument -- Thrown when `moduleScript` is not a ModuleScript.
]=]
function Chief.AddModule (self: Self, moduleScript: ModuleScript): Self
	assert(not self._IsStarted, 'BadCall: Bad call for AddModule (attempted to add module after Chief has started)')
	assertModuleScript(moduleScript, 1, 'AddModule')

	if not self._ModuleScriptSet[moduleScript] then
		self._ModuleScriptSet[moduleScript] = true
		table.insert(self._ModuleScripts, moduleScript)
	end

	return self
end

--[=[
	Add multiple modules. Chainable.

	@param moduleScripts { ModuleScript } -- Array of modules.

	@error BadCall -- Thrown when attempt is made to add a module after Chief has started.
	@error BadArgument -- Thrown when `moduleScripts` is not an array of ModuleScripts.
]=]
function Chief.AddModules (self: Self, moduleScripts: { ModuleScript }): Self
	assert(not self._IsStarted, 'BadCall: Bad call for AddModules (attempted to add module after Chief has started)')

	assert(
		typeof(moduleScripts) == 'table',
		`BadArgument: Bad argument #1 for AddModules (expected table, got {typeof(moduleScripts)})`
	)

	for index, moduleScript in moduleScripts do
		assert(
			typeof(index) == 'number',
			`BadArgument: Bad argument #1 for AddModules (expected array, got key of type {typeof(index)})`
		)

		self:AddModule(moduleScript)
	end

	return self
end

--[=[
	Register an extension. Chainable.

	Extensions attach behavior to Chief's boot process through two hooks:
	- `onPhase(chief, phase, entries)` -- fired at each boot phase with every entry loaded so far.
	- `onModule(chief, event, entry)` -- fired per module as it is loaded, initialized, and started.

	During `PostLoad` an extension may call `chief:LoadModule` to pull in
	additional modules -- loading closes once `PostLoad` finishes. During
	`PostLoad` or `PreInit` an extension may reorder `entries` in place to
	control Init order (eg. the Dependencies extension sorts at `PreInit`,
	after all loading is done); once `PreInit` finishes the order is final.

	@param extension Extension

	@error BadCall -- Thrown when attempt is made to add an extension after Chief has started.
	@error BadArgument -- Thrown when extension is not an `Extension`.
]=]
function Chief.AddExtension (self: Self, extension: Extension): Self
	assert(
		not self._IsStarted,
		'BadCall: Bad call for AddExtension (attempted to add extension after Chief has started)'
	)

	assertExtension(extension, 1, 'AddExtension')
	table.insert(self._Extensions, extension)

	return self
end

--[=[
	Register multiple extensions. Chainable.

	@param extensions { Extension } -- Array of extensions.

	@error BadCall -- Thrown when attempt is made to add an extension after Chief has started.
	@error BadArgument -- Thrown when `extensions` is not an array of `Extension`.
]=]
function Chief.AddExtensions (self: Self, extensions: { Extension }): Self
	assert(
		not self._IsStarted,
		'BadCall: Bad call for AddExtensions (attempted to add extension after Chief has started)'
	)

	assert(
		typeof(extensions) == 'table',
		`BadArgument: Bad argument #1 for AddExtensions (expected table, got {typeof(extensions)})`
	)

	for index, extension in extensions do
		assert(
			typeof(index) == 'number',
			`BadArgument: Bad argument #1 for AddExtensions (expected array, got key of type {typeof(index)})`
		)

		self:AddExtension(extension)
	end

	return self
end

--[=[
	Load a single module immediately and fire its `Loaded` event. Returns the
	existing entry if the ModuleScript was already loaded.

	Primarily for extension authors (eg. the Dependencies extension uses this
	to pull in transitive dependencies during `PostLoad`). Only callable during
	the load window -- once initialization begins the entry list is frozen.

	Entries are Priority-sorted before `PostLoad` fires, so an entry loaded
	during `PostLoad` is appended in load order -- its `Priority` is not
	re-applied. Reorder `entries` in your `onPhase` hook (as the Dependencies
	extension does) when ordering matters.

	@param moduleScript ModuleScript
	@return Entry

	@error BadCall -- Thrown when called outside the Load/PostLoad window.
	@error BadArgument -- Thrown when moduleScript is not a `ModuleScript`.
]=]
function Chief.LoadModule (self: Self, moduleScript: ModuleScript): Entry
	assert(
		self._Phase == 'Load' or self._Phase == 'PostLoad',
		'BadCall: Bad call for LoadModule (only callable during the Load/PostLoad window of Start)'
	)

	assertModuleScript(moduleScript, 1, 'LoadModule')

	local existing = self._EntryByScript[moduleScript]

	if existing then
		return existing
	end

	local module = require(moduleScript) :: Module?

	assert(
		typeof(module) == 'table',
		`BadModule: Bad module returned from {moduleScript:GetFullName()} (expected table, got {typeof(module)})`
	)

	local entry: Entry = {
		Name = moduleScript.Name,
		ModuleScript = moduleScript,
		Module = require(moduleScript) :: Module,
	}

	self._EntryByScript[moduleScript] = entry
	table.insert(self._Entries, entry)
	self:_FireModuleEvent('Loaded', entry)

	return entry
end

--[=[
	Fire a phase hook on every extension. Used internally by Chief.

	@private
]=]
function Chief._FirePhase (self: Self, phase: Phase)
	self._Phase = phase

	for _, extension in self._Extensions do
		local onPhase = extension.onPhase

		if typeof(onPhase) == 'function' then
			onPhase(self, phase, self._Entries)
		end
	end
end

--[=[
	Fire a module event hook on every extension. Used internally by Chief.

	@private
]=]
function Chief._FireModuleEvent (self: Self, event: ModuleEvent, entry: Entry)
	for _, extension in self._Extensions do
		local onModule = extension.onModule

		if typeof(onModule) == 'function' then
			onModule(self, event, entry)
		end
	end
end

--[=[
	Run the boot sequence. Idempotent-guarded by calling twice errors rather
	than double-initializing. Chainable.

	**Boot order**
	1. `PreLoad` phase
	2. Every added ModuleScript is required (`Loaded` fires per module)
	3. Entries are stably sorted by `Priority` (higher first)
	4. `PostLoad` phase -- extensions may load extra modules here; loading closes afterward
	5. `PreInit` phase -- extensions may reorder entries here (eg. the Dependencies extension sorts and injects)
	6. Every module's `Init` runs synchronously, in order (`Initialized` fires per module)
	7. `PostInit` phase -- eg. the Lifecycles extension wires events here
	8. `PreStart` phase
	9. Every module's `Start` is spawned concurrently (`Started` fires per module)
	10. `PostStart` phase
]=]
function Chief.Start (self: Self): Self
	assert(not self._IsStarted, 'BadCall: Bad call for Start (attempted to start after Chief has started)')

	self._IsStarted = true
	local clockBegin = os.clock()

	self:_FirePhase('PreLoad')

	self._Phase = 'Load'
	for _, moduleScript in self._ModuleScripts do
		self:LoadModule(moduleScript)
	end

	-- Stable Priority sort (table.sort is not stable, so ties are broken by insertion order explicitly). Extensions may override this ordering entirely during PostLoad -- the Dependencies extension does.
	local insertionIndex: { [Entry]: number } = {}
	for index, entry in self._Entries do
		insertionIndex[entry] = index
	end

	table.sort(self._Entries, function (a, b)
		local priorityA = a.Module.Priority or 0
		local priorityB = b.Module.Priority or 0

		if priorityA ~= priorityB then
			return priorityA > priorityB
		end

		return insertionIndex[a] < insertionIndex[b]
	end)

	self:_FirePhase('PostLoad')
	self:_FirePhase('PreInit')

	self._Phase = 'Init'
	for _, entry in self._Entries do
		local init = entry.Module.Init

		if typeof(init) == 'function' then
			noYield(init, entry.Module)
		end

		self:_FireModuleEvent('Initialized', entry)
	end

	self:_FirePhase('PostInit')

	self:_FirePhase('PreStart')

	self._Phase = 'Start'
	for _, entry in self._Entries do
		local start = entry.Module.Start

		if typeof(start) == 'function' then
			task.spawn(start, entry.Module)
		end

		self:_FireModuleEvent('Started', entry)
	end

	self:_FirePhase('PostStart')

	if self._IsVerbose then
		local timeTaken = math.round((os.clock() - clockBegin) * 1000)

		print(
			`Chief ({if RunService:IsServer() then 'Server' else 'Client'}) started {#self._Entries} modules in {timeTaken}ms`
		)
	end

	return self
end

--[[ TYPES ]]

export type Module = {
	Init: ((Module) -> ())?,
	Start: ((Module) -> ())?,
	Priority: number?,
	[any]: any,
}

export type Entry = {
	Name: string,
	ModuleScript: ModuleScript,
	Module: Module,
}

export type InternalPhase = Phase | 'Load' | 'Init' | 'Start'

export type Phase = 'PreLoad' | 'PostLoad' | 'PreInit' | 'PostInit' | 'PreStart' | 'PostStart'

export type ModuleEvent = 'Loaded' | 'Initialized' | 'Started'

export type Extension = {
	Name: string,
	onPhase: ((chief: Self, phase: Phase, entries: { Entry }) -> ())?,
	onModule: ((chief: Self, event: ModuleEvent, entry: Entry) -> ())?,
}

--[=[
	Options for `Chief.new`.

	**Properties**
	- `Verbose` -- When true (default), prints a boot summary after `Start` completes.
]=]
export type Options = {
	Verbose: boolean?,
}

--[=[
	Instance of Chief.
]=]
export type Self = setmetatable<{
	--[=[
		Array of module scripts used internally by Chief.

		@private
	]=]
	_ModuleScripts: { ModuleScript },

	--[=[
		Set of module scripts used internally by Chief to dedupe adds.

		@private
	]=]
	_ModuleScriptSet: { [ModuleScript]: boolean },

	--[=[
		Array of loaded entries used internally by Chief.

		@private
	]=]
	_Entries: { Entry },

	--[=[
		Map of ModuleScript to its loaded entry used internally by Chief.

		@private
	]=]
	_EntryByScript: { [ModuleScript]: Entry },

	--[=[
		Array of extensions used internally by Chief.

		@private
	]=]
	_Extensions: { Extension },

	--[=[
		Current boot phase used internally by Chief.

		@private
	]=]
	_Phase: InternalPhase?,

	--[=[
		If Chief has started. Used internally by Chief.

		@private
	]=]
	_IsStarted: boolean,

	--[=[
		If the boot summary should be printed. Used internally by Chief.

		@private
	]=]
	_IsVerbose: boolean,
}, typeof(mt)>

return Chief
