--!strict

local Dependencies = require('../../packages/dependencies/src')
local recorder = require('../Helpers/Recorder')

-- Injection replaces `Leaf` in place, and Luau caches module tables, so a second
-- boot would see the real module instead of a marker. `reset` puts the marker back.
local marker = Dependencies.use(script.Parent.DepLeaf)

local DepMiddle = {
	Name = 'DepMiddle',
	Leaf = marker,
}

function DepMiddle.reset ()
	DepMiddle.Leaf = marker
end

function DepMiddle.Init ()
	-- Records the injected module's name, proving the marker was replaced before Init.
	recorder.record(`DepMiddle.Init:{DepMiddle.Leaf.Name}`)
end

return DepMiddle
