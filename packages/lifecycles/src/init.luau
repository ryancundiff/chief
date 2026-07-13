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
		Lifecycles.CharacterAdded,
		Lifecycles.Heartbeat,
		Lifecycles.Closing,
		Lifecycles.every(5, 'Autosave'),
		{
			Method = 'BossDefeated',
			Connect = bossDefeated.Event,
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

	local dispatch = (value :: any).Dispatch

	assert(
		dispatch == nil or dispatch == 'Spawn' or dispatch == 'Inline' or dispatch == 'Await',
		`BadArgument: Bad argument #{argumentNumber} for {methodName} (Dispatch: expected 'Spawn', 'Inline', or 'Await', got {if typeof(
				dispatch
			) == 'string'
			then dispatch
			else typeof(dispatch)})`
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

	local mode: Dispatch = lifecycle.Dispatch or 'Spawn'

	local function dispatch (...)
		if mode == 'Spawn' then
			for _, module in listeners do
				task.spawn(module[method], module, ...)
			end
		elseif mode == 'Inline' then
			for _, module in listeners do
				module[method](module, ...)
			end
		else
			-- Await: run handlers concurrently, then suspend the event's thread until the last
			-- one finishes. The pcall is load-bearing twice: an erroring handler must not stop
			-- the others, and must still decrement the counter -- an uncaught error would kill
			-- its thread before the decrement and leave the dispatch suspended forever.
			local remaining = #listeners
			local caller = coroutine.running()
			local yielded = false

			for _, module in listeners do
				task.spawn(function (...)
					local ok, message = pcall(module[method], module, ...)

					if not ok then
						warn(`LifecycleError: {method} handler failed\n{message}`)
					end

					remaining -= 1

					if remaining == 0 and yielded then
						task.spawn(caller)
					end
				end, ...)
			end

			-- task.spawn runs each handler up to its first yield before returning, so fully
			-- synchronous handlers have already finished here; only suspend when some are
			-- genuinely still running, and flag it so the last one knows to resume us.
			if remaining > 0 then
				yielded = true
				coroutine.yield()
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

--[=[
	Create a lifecycle that fires `method(deltaTime)` roughly every `seconds`, where `deltaTime` is the actual time elapsed since the previous tick. Each call returns a fresh lifecycle, so different intervals can drive different methods.

	Ticks do not catch up: a lag spike produces one late tick (with the real elapsed time), not a burst.

	```
	Lifecycles.new({
		Lifecycles.every(5, 'Autosave'),
		Lifecycles.every(1, 'Regenerate'),
	})
	```

	@param seconds number -- Seconds between ticks. Must be positive.
	@param method string -- The method name modules implement.
	@return Lifecycle

	@error BadArgument -- Thrown when `seconds` is not a positive number or `method` is not a non-empty string.
]=]
function Lifecycles.every (seconds: number, method: string): Lifecycle
	assert(
		typeof(seconds) == 'number' and seconds > 0,
		`BadArgument: Bad argument #1 for every (expected positive number, got {if typeof(seconds) == 'number'
			then seconds
			else typeof(seconds)})`
	)

	assert(
		typeof(method) == 'string' and #method > 0,
		`BadArgument: Bad argument #2 for every (expected non-empty string, got {typeof(method)})`
	)

	return {
		Method = method,
		Connect = function (fire)
			-- A plain loop rather than Heartbeat accumulation: task.wait already rides Heartbeat
			-- and returns the real elapsed time. The thread is never cancelled -- lifecycle
			-- connections live for the session (see new).
			task.spawn(function ()
				while true do
					fire(task.wait(seconds))
				end
			end)

			return nil
		end,
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
	Fires `CharacterAdded(player, character)` whenever any player's character spawns -- including characters already spawned when the extension wires up, and players who join later.
]=]
Lifecycles.CharacterAdded = {
	Method = 'CharacterAdded',
	Connect = function (fire)
		local function watch (player: Player)
			if player.Character ~= nil then
				task.spawn(fire, player, player.Character)
			end

			player.CharacterAdded:Connect(function (character)
				fire(player, character)
			end)
		end

		for _, player in Players:GetPlayers() do
			watch(player)
		end

		return Players.PlayerAdded:Connect(watch)
	end,
} :: Lifecycle

--[=[
	Fires `CharacterRemoving(player, character)` whenever any player's character is about to be removed, for present and future players alike.
]=]
Lifecycles.CharacterRemoving = {
	Method = 'CharacterRemoving',
	Connect = function (fire)
		local function watch (player: Player)
			player.CharacterRemoving:Connect(function (character)
				fire(player, character)
			end)
		end

		for _, player in Players:GetPlayers() do
			watch(player)
		end

		return Players.PlayerAdded:Connect(watch)
	end,
} :: Lifecycle

--[=[
  Local lifecycles for client-side events.
]=]
Lifecycles.Local = {}

setmetatable(Lifecycles.Local, {
	__index = function (lifecycles, key)
		assert(RunService:IsClient(), 'Local lifecycles are client-only')
		return lifecycles[key]
	end,
})

--[=[
  Fires `LocalCharacterRemoving(player, character)` whenever the local player's character is about to be removed. Client only.
]=]
Lifecycles.Local.CharacterAdded = {
	Method = 'LocalCharacterAdded',
	Connect = function (fire)
		assert(RunService:IsClient(), 'LocalCharacterAdded lifecycle is client-only')

		local player = Players.LocalPlayer
		player.CharacterAdded:Connect(function (character)
			fire(player, character)
		end)
	end,
} :: Lifecycle

--[=[
  Fires `LocalCharacterRemoving(player, character)` whenever the local player's character is about to be removed.
]=]
Lifecycles.Local.CharacterRemoving = {
	Method = 'LocalCharacterRemoving',
	Connect = function (fire)
		assert(RunService:IsClient(), 'LocalCharacterRemoving lifecycle is client-only')

		local player = Players.LocalPlayer
		player.CharacterRemoving:Connect(function (character)
			fire(player, character)
		end)
	end,
} :: Lifecycle

--[=[
  Fires `LocalAppearanceLoaded(player, character)` whenever the local player's character has finished loading its appearance.
]=]
Lifecycles.Local.AppearanceLoaded = {
	Method = 'LocalAppearanceLoaded',
	Connect = function (fire)
		assert(RunService:IsClient(), 'AppearanceLoaded lifecycle is client-only')

		local player = Players.LocalPlayer
		player.CharacterAppearanceLoaded:Connect(function (character)
			fire(player, character)
		end)
	end,
} :: Lifecycle

--[=[
  Fires `LocalHumanoidDied(player, character, humanoid)` whenever the local player's character's humanoid dies.
]=]
Lifecycles.Local.HumanoidDied = {
	Method = 'LocalHumanoidDied',
	Connect = function (fire)
		assert(RunService:IsClient(), 'LocalHumanoidDied lifecycle is client-only')

		local player = Players.LocalPlayer
		player.CharacterAdded:Connect(function (character)
			local humanoid = character:WaitForChild('Humanoid', 10) :: Humanoid?
			if not humanoid then
				return
			end

			humanoid.Died:Connect(function ()
				fire(player, character, humanoid)
			end)
		end)
	end,
} :: Lifecycle

--[=[
  Fires `AppearanceLoaded(player, character)` whenever any player's character has finished loading its appearance, for present and future players alike.
]=]
Lifecycles.AppearanceLoaded = {
	Method = 'AppearanceLoaded',
	Connect = function (fire)
		local function watch (player: Player)
			player.CharacterAppearanceLoaded:Connect(function (character)
				fire(player, character)
			end)
		end

		for _, player in Players:GetPlayers() do
			watch(player)
		end

		return Players.PlayerAdded:Connect(watch)
	end,
} :: Lifecycle

--[=[
  Fires `PlayerDied(player, character, humanoid)` whenever any player's character's humanoid dies, for present and future players alike.
]=]
Lifecycles.PlayerDied = {
	Method = 'PlayerDied',
	Connect = function (fire)
		local function watch (player: Player)
			player.CharacterAdded:Connect(function (character)
				local humanoid = character:WaitForChild('Humanoid', 10) :: Humanoid?
				if not humanoid then
					return
				end

				humanoid.Died:Connect(function ()
					fire(player, character, humanoid)
				end)
			end)
		end

		for _, player in Players:GetPlayers() do
			watch(player)
		end

		return Players.PlayerAdded:Connect(watch)
	end,
} :: Lifecycle

--[=[
	Fires `Closing()` when the server begins shutting down, and holds the shutdown until every handler has finished (within Roblox's `BindToClose` budget of roughly 30 seconds). Handlers run concurrently, and one erroring handler cannot stop the others -- this is the lifecycle for saving player data. Server only.
]=]
Lifecycles.Closing = {
	Method = 'Closing',
	Connect = function (fire)
		game:BindToClose(function ()
			fire()
		end)

		return nil
	end,
	Dispatch = 'Await',
} :: Lifecycle

--[=[
	Fires `PreRender(deltaTime)` each frame before rendering. Runs inline since it fires every frame. Client only.
]=]
Lifecycles.PreRender = {
	Method = 'PreRender',
	Connect = RunService.PreRender,
	Dispatch = 'Inline',
} :: Lifecycle

--[=[
	Fires `PreAnimation(deltaTime)` each frame before animations advance. Runs inline since it fires every frame.
]=]
Lifecycles.PreAnimation = {
	Method = 'PreAnimation',
	Connect = RunService.PreAnimation,
	Dispatch = 'Inline',
} :: Lifecycle

--[=[
	Fires `PreSimulation(deltaTime)` each frame before physics simulation. Runs inline since it fires every frame.
]=]
Lifecycles.PreSimulation = {
	Method = 'PreSimulation',
	Connect = RunService.PreSimulation,
	Dispatch = 'Inline',
} :: Lifecycle

--[=[
	Fires `PostSimulation(deltaTime)` each frame after physics simulation. Runs inline since it fires every frame.

	`PostSimulation` and `Heartbeat` are the same moment in the frame (Heartbeat is the legacy name); modules should implement one or the other, not both.
]=]
Lifecycles.PostSimulation = {
	Method = 'PostSimulation',
	Connect = RunService.PostSimulation,
	Dispatch = 'Inline',
} :: Lifecycle

--[=[
	Fires `Heartbeat(deltaTime)` each frame after physics simulation. Runs inline since it fires every frame.

	`Heartbeat` is the legacy name for `PostSimulation`; modules should implement one or the other, not both.
]=]
Lifecycles.Heartbeat = {
	Method = 'Heartbeat',
	Connect = RunService.Heartbeat,
	Dispatch = 'Inline',
} :: Lifecycle

--[[ TYPES ]]

--[=[
	How `fire` delivers an event to the modules implementing the method.

	- `Spawn` (default) -- Each handler runs on its own thread; `fire` returns immediately. One slow or erroring handler cannot affect the others or the event source.
	- `Inline` -- Handlers run sequentially on the event's thread; `fire` returns when they all have. No thread spawned per module per event, so high-frequency lifecycles (eg. Heartbeat) use this -- but a slow handler delays the rest, and an erroring handler stops the dispatch.
	- `Await` -- Handlers run concurrently and `fire` blocks until every one has finished; each is error-isolated. For event sources that must wait for handlers, eg. `BindToClose`.
]=]
export type Dispatch = 'Spawn' | 'Inline' | 'Await'

--[=[
	A lifecycle binds an event to a method name.

	**Properties**
	- `Method` -- The method name that modules implement (eg. PlayerAdded).
	- `Connect` -- Receives a `fire` dispatcher and returns a connection (or nil for lifecycles with no ongoing connection). Call `fire(...)` to dispatch the event's arguments to every module that implements the method.
	- `Dispatch` -- How `fire` delivers the event: `'Spawn'` (default), `'Inline'`, or `'Await'`.
]=]
export type Lifecycle = {
	Method: string,
	Connect: RBXScriptSignal | ((fire: (...any) -> ()) -> RBXScriptConnection?),
	Dispatch: Dispatch?,
}

return Lifecycles
