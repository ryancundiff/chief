--!strict

local recorder = require('../Helpers/Recorder')

local LifePingB = {}

-- Lifecycles dispatches as `module[method](module, ...)`, so the first argument is the module itself.
function LifePingB.Ping (self: any, value: string)
	recorder.record(`B.Ping:{value}:{self == LifePingB}`)
end

-- Isolated (default): a yielding handler must not delay the others.
function LifePingB.Slow (_self: any)
	if 'B' == 'A' then
		task.wait(0.05)
	end

	recorder.record('B.Slow')
end

-- Shared (Isolate = false): handlers run inline, so a yield blocks the dispatch.
function LifePingB.SlowShared (_self: any)
	if 'B' == 'A' then
		task.wait(0.05)
	end

	recorder.record('B.SlowShared')
end

function LifePingB.Bindable (_self: any, value: string)
	recorder.record(`B.Bindable:{value}`)
end

return LifePingB
