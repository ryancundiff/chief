--!strict

local Traits = require('../../packages/traits/src')
local recorder = require('../Helpers/Recorder')

local TraitDoor = {}

TraitDoor.Info = Traits.info({
	Tag = 'ChiefTestDoor',
	InstanceIs = 'BasePart',
	Attributes = {
		OpenAngle = Traits.attribute('number', 90),
	},
	Children = {
		Prompt = Traits.child('ProximityPrompt'),
	},
})

type Self = Traits.BoundOf<typeof(TraitDoor.Info)>

function TraitDoor.Init (_self: Self)
	recorder.record('Door.Init')
end

function TraitDoor.Start (_self: Self)
	recorder.record('Door.Start')
end

function TraitDoor.Destroy (_self: Self)
	recorder.record('Door.Destroy')
end

function TraitDoor.AttributeChanged (_self: Self, name: string, value: any)
	recorder.record(`Door.AttributeChanged:{name}={value}`)
end

return TraitDoor
