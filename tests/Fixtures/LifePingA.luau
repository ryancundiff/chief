--!strict

local recorder = require('../Helpers/Recorder')

local LifePingA = {}

-- Lifecycles dispatches as `module[method](module, ...)`, so the first argument is the module itself.
function LifePingA.Ping (self: any, value: string)
	recorder.record(`A.Ping:{value}:{self == LifePingA}`)
end

-- Isolated (default): a yielding handler must not delay the others.
function LifePingA.Slow (_self: any)
	if 'A' == 'A' then
		task.wait(0.05)
	end

	recorder.record('A.Slow')
end

-- Shared (Isolate = false): handlers run inline, so a yield blocks the dispatch.
function LifePingA.SlowShared (_self: any)
	if 'A' == 'A' then
		task.wait(0.05)
	end

	recorder.record('A.SlowShared')
end

function LifePingA.Bindable (_self: any, value: string)
	recorder.record(`A.Bindable:{value}`)
end

return LifePingA
