# chief/lifecycles

The Lifecycles extension for [Chief](https://github.com/ryancundiff/Chief): binds events to module methods.

A lifecycle binds an event (`PlayerAdded`, `Heartbeat`, or anything custom) to a method name. Modules opt in by implementing the method; modules that don't implement it are never connected. Wiring happens at `PostInit` — after every module's `Init`, before any `Start` — so handlers can safely assume all modules are initialized.

## Installation

```sh
pesde add chief/lifecycles
```

## Usage

Register the extension with the lifecycles you want available:

```luau
--!strict

local Chief = require('path/to/core')
local Lifecycles = require('path/to/lifecycles')

Chief.new()
	:AddModules(script.Modules:GetChildren())
	:AddExtension(Lifecycles.new({
		Lifecycles.PlayerAdded,
		Lifecycles.CharacterAdded,
		Lifecycles.Heartbeat,
		Lifecycles.Closing,
		Lifecycles.every(30, 'Autosave'),
	}))
	:Start()
```

Modules opt in by implementing the method:

```luau
--!strict

local GreeterModule = {}

function GreeterModule.PlayerAdded (self: Self, player: Player)
	print(`Welcome, {player.Name}!`)
end

function GreeterModule.Autosave (self: Self, deltaTime: number)
	-- Runs every 30 seconds; deltaTime is the real time since the previous tick.
end

function GreeterModule.Closing (self: Self)
	-- The server waits for this to finish (concurrently with other modules' Closing).
end

type Self = typeof(GreeterModule)

return GreeterModule
```

## Built-in lifecycles

| Lifecycle | Method signature | Notes |
| --- | --- | --- |
| `Lifecycles.PlayerAdded` | `PlayerAdded(self, player)` | Also fires once for each player already present when the extension wires up. |
| `Lifecycles.PlayerRemoving` | `PlayerRemoving(self, player)` | |
| `Lifecycles.CharacterAdded` | `CharacterAdded(self, player, character)` | Fires for characters already spawned at wire-up, and for players who join later. |
| `Lifecycles.CharacterRemoving` | `CharacterRemoving(self, player, character)` | |
| `Lifecycles.Closing` | `Closing(self)` | `game:BindToClose`; holds shutdown until every handler finishes (`Await`). Save player data here. Server only. |
| `Lifecycles.PreRender` | `PreRender(self, deltaTime)` | Each frame before rendering. Inline. Client only. |
| `Lifecycles.PreAnimation` | `PreAnimation(self, deltaTime)` | Each frame before animations advance. Inline. |
| `Lifecycles.PreSimulation` | `PreSimulation(self, deltaTime)` | Each frame before physics simulation. Inline. |
| `Lifecycles.PostSimulation` | `PostSimulation(self, deltaTime)` | Each frame after physics simulation. Inline. |
| `Lifecycles.Heartbeat` | `Heartbeat(self, deltaTime)` | Legacy name for the same frame moment as `PostSimulation`; implement one or the other. Inline. |

`Lifecycles.every(seconds, method)` builds interval lifecycles: `method(self, deltaTime)` fires roughly every `seconds`, with the real elapsed time. Ticks don't catch up after a lag spike. Each call returns a fresh lifecycle, so different intervals can drive different methods.

## Custom lifecycles

A lifecycle is a table:

```luau
export type Lifecycle = {
	Method: string,
	Connect: RBXScriptSignal | ((fire: (...any) -> ()) -> RBXScriptConnection?),
	Dispatch: ('Spawn' | 'Inline' | 'Await')?,
}
```

- `Method` — the method name modules implement.
- `Connect` — either a signal to connect to directly, or a function that receives a `fire` dispatcher and returns a connection (or nil when there is no ongoing connection). Call `fire(...)` to dispatch the event's arguments to every module that implements the method.
- `Dispatch` — how `fire` delivers the event to handlers:
	- `'Spawn'` (default) — each handler runs on its own thread and `fire` returns immediately. One slow or erroring handler can't affect the others or the event source.
	- `'Inline'` — handlers run sequentially on the event's thread; `fire` returns when they all have. No thread per module per event, so the per-frame built-ins use this — but a slow handler delays the rest, and an erroring handler stops the dispatch.
	- `'Await'` — handlers run concurrently and `fire` blocks until every one finishes, each error-isolated. For event sources that must wait for handlers, e.g. `BindToClose`.

```luau
local Players = game:GetService('Players')

Lifecycles.new({
	-- Direct signal form:
	{
		Method = 'ChildAddedToWorkspace',
		Connect = workspace.ChildAdded,
	},

	-- Function form, for composed events:
	{
		Method = 'PlayerChatted',
		Connect = function (fire)
			return Players.PlayerAdded:Connect(function (player)
				player.Chatted:Connect(function (message)
					fire(player, message)
				end)
			end)
		end,
	},
})
```

Distinct lifecycles may share a `Method` (binding one method to multiple event sources is intentional), but passing the *same* lifecycle table twice errors — each occurrence would wire its own connection and fire every handler twice per event.

## License

MIT
