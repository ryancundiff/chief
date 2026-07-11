--!strict

local recorder = require('../Helpers/Recorder')

local LifePingB = {}

-- Lifecycles dispatches as `module[method](module, ...)`, so the first argument is the module itself.
function LifePingB.Ping (self: any, value: string)
	recorder.record(`B.Ping:{value}:{self == LifePingB}`)
end

-- Spawn (default): B is the fast sibling that must not be delayed by A's yield.
function LifePingB.Slow (_self: any)
	recorder.record('B.Slow')
end

-- Inline: B runs after A on the event's thread.
function LifePingB.SlowShared (_self: any)
	recorder.record('B.SlowShared')
end

-- Await: B finishes immediately while A is still yielding.
function LifePingB.AwaitSlow (_self: any)
	recorder.record('B.AwaitSlow')
end

-- Await: must still run (and the dispatch still return) when A's handler errors.
function LifePingB.AwaitError (_self: any)
	recorder.record('B.AwaitError')
end

-- Await: fully synchronous handlers exercise the no-suspend path.
function LifePingB.AwaitFast (_self: any)
	recorder.record('B.AwaitFast')
end

function LifePingB.Bindable (_self: any, value: string)
	recorder.record(`B.Bindable:{value}`)
end

return LifePingB
