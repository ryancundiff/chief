--!strict

local TestEZ = require('../RobloxPackages/testez')

--[=[
	Run every spec ModuleScript (`*.spec`) under `tests` and error if any fail,
	so the Open Cloud Luau execution task ends in the FAILED state and CI goes red.
]=]
return function ()
	local results = TestEZ.TestBootstrap:run({ script.Parent })

	if results.failureCount > 0 then
		error(`TestsFailed: {results.failureCount} failing test(s)`)
	end
end
