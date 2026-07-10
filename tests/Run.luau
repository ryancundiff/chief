--!strict

local Runner = require('./Runner')

--[=[
	Run every spec ModuleScript (`*.spec`) under `tests` and error if any fail,
	so the Open Cloud Luau execution task ends in the FAILED state and CI goes red.
]=]
return function ()
	local specs: { ModuleScript } = {}

	for _, descendant in script.Parent:GetDescendants() do
		if descendant:IsA('ModuleScript') and string.match(descendant.Name, '%.spec$') ~= nil then
			table.insert(specs, descendant)
		end
	end

	assert(#specs > 0, 'TestsFailed: no *.spec modules found under Tests (was the place built from test.project.json?)')

	-- Deterministic order, so a failure reproduces the same way twice.
	table.sort(specs, function (left: ModuleScript, right: ModuleScript)
		return left.Name < right.Name
	end)

	local results = Runner.run(specs)

	if results.Failed > 0 then
		error(`TestsFailed: {results.Failed} failing test(s) of {results.Passed + results.Failed}`, 0)
	end
end
