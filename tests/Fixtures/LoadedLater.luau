--!strict

local recorder = require('../Helpers/Recorder')

local LoadedLater = {}

function LoadedLater.Init ()
	recorder.record('LoadedLater.Init')
end

return LoadedLater
