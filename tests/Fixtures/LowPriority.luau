--!strict

local recorder = require('../Helpers/Recorder')

local LowPriority = {
	Priority = 1,
}

function LowPriority.Init ()
	recorder.record('LowPriority.Init')
end

function LowPriority.Start ()
	recorder.record('LowPriority.Start')
end

return LowPriority
