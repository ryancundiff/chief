--!strict

-- Roblox services.
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')

local Chief = require('./roblox_packages/core')

--[=[
	The Lifecycles extension: binds events to module methods.

	A lifecycle binds an event to a method name. Modules opt in by implementing the method; modules that don't implement it are never connected. Wiring happens at `PostInit` -- after every module's `Init`, before any `Start` -- so handlers can safely assume all modules are initialized.

	How to setup Lifecycles:
	```
	Lifecycles.new({
		Lifecycles.PlayerAdded,
		Lifecycles.Heartbeat,
		{
			Method = 'CharacterAdded',
			Connect = function (fire)
				return Players.PlayerAdded:Connect(function (player)
					player.CharacterAdded:Connect(function (character)
						fire(player, character)
					end)
				end)
			end,
		},
	})
	```
]=]
local Lifecycles = {}

--[[ HELPERS ]]

--[=[
	Errors if `value` is not a valid `Lifecycle`.

	@param value unknown
	@param argumentNumber number
	@param methodName string

	@error BadArgument -- Thrown when `value` is not a valid `Lifecycle`.
]=]
local function assertLifecycle (value: unknown, argumentNumber: number, methodName: string)
	assert(
		typeof(value) == 'table',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (expected table, got {typeof(value)})`
	)

	assert(
		typeof((value :: any).Method) == 'string',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (Method: expected string, got {typeof(
			(value :: any).Method
		)})`
	)

	assert(
		typeof((value :: any).Connect) == 'RBXScriptSignal' or typeof((value :: any).Connect) == 'function',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (Connect: expected RBXScriptSignal or function, got {typeof(
			(value :: any).Connect
		)})`
	)

	assert(
		(value :: any).Isolate == nil or typeof((value :: any).Isolate) == 'boolean',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (Isolate: expected boolean or nil, got {typeof(
			(value :: any).Isolate
		)})`
	)
end

--[=[
	Connects one lifecycle to every module implementing its method. Returns the connection, or nil when no module opted in or the connect function produced no ongoing connection.

	@param entries { Chief.Entry } -- Every loaded entry.
	@param lifecycle Lifecycle -- The lifecycle to wire.
	@return RBXScriptConnection?
]=]
local function wireLifecycle (entries: { Chief.Entry }, lifecycle: Lifecycle): RBXScriptConnection?
	local method = lifecycle.Method

	local listeners: { Chief.Module } = {}
	for _, entry in entries do
		if typeof(entry.Module[method]) == 'function' then
			table.insert(listeners, entry.Module)
		end
	end

	if #listeners == 0 then
		return nil
	end

	local isolate = lifecycle.Isolate ~= false

	local function dispatch (...)
		for _, module in listeners do
			if isolate then
				task.spawn(module[method], module, ...)
			else
				module[method](module, ...)
			end
		end
	end

	local connect = lifecycle.Connect

	if typeof(connect) == 'function' then
		return connect(dispatch)
	end

	return connect:Connect(dispatch)
end

--[[ METHODS ]]

--[=[
	Create a Lifecycles extension wiring the given lifecycles. Add it to Chief with `AddExtension`.

	@param lifecycles { Lifecycle } -- Array of lifecycles modules can opt into.
	@return Extension

	@error BadArgument -- Thrown when `lifecycles` is not an array of `Lifecycle`, or contains the same lifecycle twice.
]=]
function Lifecycles.new (lifecycles: { Lifecycle }): Chief.Extension
	assert(
		typeof(lifecycles) == 'table',
		`BadArgument: Bad argument #1 for new (expected table, got {typeof(lifecycles)})`
	)

	-- Each occurrence of a lifecycle wires its own connection, so the same lifecycle appearing twice (eg. from merging shared config arrays) would silently fire every handler twice per event. Only *reference* duplicates are rejected: distinct lifecycles sharing a Method are allowed, since binding one method to multiple event sources is intentional.
	local seen: { [Lifecycle]: boolean } = {}

	for index, lifecycle in lifecycles do
		assert(
			typeof(index) == 'number',
			`BadArgument: Bad argument #1 for new (expected array, got key of type {typeof(index)})`
		)

		assertLifecycle(lifecycle, 1, 'new')

		assert(
			not seen[lifecycle],
			`BadArgument: Bad argument #1 for new (duplicate lifecycle '{lifecycle.Method}' at index {index})`
		)

		seen[lifecycle] = true
	end

	-- Chief has no teardown hook and is a boot-time singleton, so lifecycle connections live for the session; `wireLifecycle` is called for effect.
	local function onPhase (_chief: Chief.Self, phase: Chief.Phase, entries: { Chief.Entry })
		if phase ~= 'PostInit' then
			return
		end

		for _, lifecycle in lifecycles do
			wireLifecycle(entries, lifecycle)
		end
	end

	return {
		Name = 'Lifecycles',
		onPhase = onPhase,
	}
end

--[[ LIFECYCLES ]]

--[=[
	Fires `PlayerAdded(player)` for every player that joins, and once for each player already present when the extension wires up.
]=]
Lifecycles.PlayerAdded = {
	Method = 'PlayerAdded',
	Connect = function (fire)
		for _, player in Players:GetPlayers() do
			task.spawn(fire, player)
		end

		return Players.PlayerAdded:Connect(fire)
	end,
} :: Lifecycle

--[=[
	Fires `PlayerRemoving(player)` for every player leaving the game.
]=]
Lifecycles.PlayerRemoving = {
	Method = 'PlayerRemoving',
	Connect = Players.PlayerRemoving,
} :: Lifecycle

--[=[
	Fires `PreRender(deltaTime)` each frame before rendering. Runs shared (not isolated) since it fires every frame. Client only.
]=]
Lifecycles.PreRender = {
	Method = 'PreRender',
	Connect = RunService.PreRender,
	Isolate = false,
} :: Lifecycle

--[=[
	Fires `PreSimulation(deltaTime)` each frame before physics simulation. Runs shared (not isolated) since it fires every frame.
]=]
Lifecycles.PreSimulation = {
	Method = 'PreSimulation',
	Connect = RunService.PreSimulation,
	Isolate = false,
} :: Lifecycle

--[=[
	Fires `Heartbeat(deltaTime)` each frame after physics simulation. Runs shared (not isolated) since it fires every frame.
]=]
Lifecycles.Heartbeat = {
	Method = 'Heartbeat',
	Connect = RunService.Heartbeat,
	Isolate = false,
} :: Lifecycle

--[[ TYPES ]]

--[=[
	A lifecycle binds an event to a method name.

	**Properties**
	- `Method` -- The method name that modules implement (eg. PlayerAdded).
	- `Connect` -- Receives a `fire` dispatcher and returns a connection (or nil for lifecycles with no ongoing connection). Call `fire(...)` to dispatch the event's arguments to every module that implements the method.
	- `Isolate` -- When true (default), each module's handler runs in its own thread, so one slow or erroring handler can't block the others or the event. Set false for high-frequency lifecycles (eg. Heartbeat) to avoid spawning a thread per module per frame.
]=]
export type Lifecycle = {
	Method: string,
	Connect: RBXScriptSignal | ((fire: (...any) -> ()) -> RBXScriptConnection?),
	Isolate: boolean?,
}

return Lifecycles
