--!strict

local recorder = require('../Helpers/Recorder')

local LifePingA = {}

-- Lifecycles dispatches as `module[method](module, ...)`, so the first argument is the module itself.
function LifePingA.Ping (self: any, value: string)
	recorder.record(`A.Ping:{value}:{self == LifePingA}`)
end

-- Spawn (default): a yielding handler must not delay the others.
function LifePingA.Slow (_self: any)
	task.wait(0.05)

	recorder.record('A.Slow')
end

-- Inline: handlers run on the event's thread, so a yield blocks the dispatch.
function LifePingA.SlowShared (_self: any)
	task.wait(0.05)

	recorder.record('A.SlowShared')
end

-- Await: fire must not return until this yield completes.
function LifePingA.AwaitSlow (_self: any)
	task.wait(0.05)

	recorder.record('A.AwaitSlow')
end

-- Await: an erroring handler must not stop the others, or hang the dispatch.
function LifePingA.AwaitError (_self: any)
	error('AwaitBoom')
end

-- Await: fully synchronous handlers exercise the no-suspend path.
function LifePingA.AwaitFast (_self: any)
	recorder.record('A.AwaitFast')
end

-- Lifecycle connections live for the session, so an every() loop or frame signal wired by one
-- test keeps firing through every later test. The flags let a test opt into recording and out
-- again, so the permanent connections stay silent everywhere else.
LifePingA.TickEnabled = false
LifePingA.FrameEnabled = false

function LifePingA.Tick (self: any, deltaTime: number)
	if self.TickEnabled then
		recorder.record(`A.Tick:{typeof(deltaTime)}`)
	end
end

function LifePingA.Heartbeat (self: any, _deltaTime: number)
	if self.FrameEnabled then
		recorder.record('A.Heartbeat')
	end
end

-- Never fires in the Open Cloud harness (no players, and the place only closes after the run);
-- these exist so wiring the built-ins is exercised end to end.
function LifePingA.CharacterAdded (_self: any, player: Player, character: Model)
	recorder.record(`A.CharacterAdded:{player.Name}:{character.Name}`)
end

function LifePingA.CharacterRemoving (_self: any, player: Player, character: Model)
	recorder.record(`A.CharacterRemoving:{player.Name}:{character.Name}`)
end

function LifePingA.Closing (_self: any) end

function LifePingA.Bindable (_self: any, value: string)
	recorder.record(`A.Bindable:{value}`)
end

return LifePingA
