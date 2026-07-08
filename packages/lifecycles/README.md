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
		Lifecycles.PlayerRemoving,
		Lifecycles.Heartbeat,
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

function GreeterModule.Heartbeat (self: Self, deltaTime: number)
	-- Runs every frame. Keep it cheap.
end

type Self = typeof(GreeterModule)

return GreeterModule
```

## Built-in lifecycles

| Lifecycle | Method signature | Notes |
| --- | --- | --- |
| `Lifecycles.PlayerAdded` | `PlayerAdded(self, player)` | Also fires once for each player already present when the extension wires up. |
| `Lifecycles.PlayerRemoving` | `PlayerRemoving(self, player)` | |
| `Lifecycles.PreRender` | `PreRender(self, deltaTime)` | Each frame before rendering. Shared (not isolated). Client only. |
| `Lifecycles.PreSimulation` | `PreSimulation(self, deltaTime)` | Each frame before physics simulation. Shared (not isolated). |
| `Lifecycles.Heartbeat` | `Heartbeat(self, deltaTime)` | Each frame after physics simulation. Shared (not isolated). |

## Custom lifecycles

A lifecycle is a table:

```luau
export type Lifecycle = {
	Method: string,
	Connect: RBXScriptSignal | ((fire: (...any) -> ()) -> RBXScriptConnection?),
	Isolate: boolean?,
}
```

- `Method` — the method name modules implement.
- `Connect` — either a signal to connect to directly, or a function that receives a `fire` dispatcher and returns a connection (or nil when there is no ongoing connection). Call `fire(...)` to dispatch the event's arguments to every module that implements the method.
- `Isolate` — when `true` (default), each module's handler runs in its own thread, so one slow or erroring handler can't block the others or the event. Set `false` for high-frequency lifecycles (e.g. `Heartbeat`) to avoid spawning a thread per module per frame.

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

Distinct lifecycles may share a `Method` (binding one method to multiple event sources is intentional), but passing the *same* lifecycle table twice errors — each occurrence would wire its own connection and fire every handler twice per event.

## License

MIT
