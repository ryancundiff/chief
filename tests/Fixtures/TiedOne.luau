--!strict

local recorder = require('../Helpers/Recorder')

local TiedOne = {}

function TiedOne.Init ()
	recorder.record('TiedOne.Init')
end

return TiedOne
