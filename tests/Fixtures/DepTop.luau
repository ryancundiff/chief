--!strict

local Dependencies = require('../../packages/dependencies/src')
local recorder = require('../Helpers/Recorder')

local marker = Dependencies.use(script.Parent.DepMiddle)

local DepTop = {
	Middle = marker,
}

function DepTop.reset ()
	DepTop.Middle = marker
end

function DepTop.Init ()
	recorder.record(`DepTop.Init:{DepTop.Middle.Name}`)
end

return DepTop
