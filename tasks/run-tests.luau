--!strict

-- Entry script for the Open Cloud Luau execution task. It is sent to the API
-- by scripts/upload_and_run_task.py -- it is not part of the built place.
local ServerStorage = game:GetService('ServerStorage')

local chiefTests = ServerStorage:FindFirstChild('ChiefTests')
assert(chiefTests ~= nil, 'ChiefTests folder not found in ServerStorage (was the place built from test.project.json?)')

local testsFolder = chiefTests:FindFirstChild('tests')
assert(testsFolder ~= nil, 'tests folder not found in ChiefTests')

local runTests = require(testsFolder:FindFirstChild('Run') :: ModuleScript) :: () -> ()

runTests()
