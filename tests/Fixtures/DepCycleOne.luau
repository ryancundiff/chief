--!strict

local Dependencies = require('../../packages/dependencies/src')

local DepCycleOne = {
	Other = Dependencies.use(script.Parent.DepCycleTwo),
}

return DepCycleOne
