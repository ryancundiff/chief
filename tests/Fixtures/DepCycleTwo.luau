--!strict

local Dependencies = require('../../packages/dependencies/src')

local DepCycleTwo = {
	Other = Dependencies.use(script.Parent.DepCycleOne),
}

return DepCycleTwo
