--!strict

local recorder = require('../Helpers/Recorder')

local HighPriority = {
	Priority = 2,
}

function HighPriority.Init ()
	recorder.record('HighPriority.Init')
end

function HighPriority.Start ()
	recorder.record('HighPriority.Start')
end

return HighPriority
