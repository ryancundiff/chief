--!strict

local Traits = require('../../packages/traits/src')
local recorder = require('../Helpers/Recorder')

-- Declares no attributes or children, so only the InstanceIs check can reject an instance.
local TraitModelOnly = {}

TraitModelOnly.Info = Traits.info({
	Tag = 'ChiefTestModelOnly',
	InstanceIs = 'Model',
})

type Self = Traits.BoundOf<typeof(TraitModelOnly.Info)>

function TraitModelOnly.Init (_self: Self)
	recorder.record('ModelOnly.Init')
end

return TraitModelOnly
