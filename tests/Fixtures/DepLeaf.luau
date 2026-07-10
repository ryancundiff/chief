--!strict

local recorder = require('../Helpers/Recorder')

local DepLeaf = {
	Name = 'DepLeaf',
}

function DepLeaf.Init ()
	recorder.record('DepLeaf.Init')
end

return DepLeaf
