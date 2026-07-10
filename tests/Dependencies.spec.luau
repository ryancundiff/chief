--!strict

local tests = script.Parent

local Chief = require('../packages/core/src')
local Dependencies = require('../packages/dependencies/src')
local Runner = require('./Runner')
local recorder = require('./Helpers/Recorder')

local beforeEach = Runner.beforeEach
local describe = Runner.describe
local expect = Runner.expect
local it = Runner.it

local fixtures = tests.Fixtures
local depCycleOne = fixtures.DepCycleOne
local depFrozen = fixtures.DepFrozen
local depLeaf = fixtures.DepLeaf
local depMiddle = fixtures.DepMiddle
local depTop = fixtures.DepTop

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

-- Injection replaces marker fields in place, and Luau caches module tables, so each boot must
-- start from restored markers or it would see the previous boot's injected modules.
local middleModule = require(depMiddle) :: any
local topModule = require(depTop) :: any

beforeEach(function ()
	recorder.reset()
	middleModule.reset()
	topModule.reset()
end)

describe('use', function ()
	it('errors when given something other than a ModuleScript', function ()
		expect(function ()
			Dependencies.use(5 :: any)
		end).toThrow('BadArgument')
	end)

	it('returns a marker table carrying the ModuleScript', function ()
		local marker = Dependencies.use(depLeaf)

		expect(typeof(marker)).toBe('table')
		expect(marker.ModuleScript).toBe(depLeaf)
	end)
end)

describe('ordering', function ()
	it('inits a dependency before the module that depends on it', function ()
		Chief.new({ Verbose = false }):AddModules({ depMiddle, depLeaf }):AddExtension(Dependencies.new()):Start()

		expect(eventString()).toBe('DepLeaf.Init, DepMiddle.Init:DepLeaf')
	end)

	it('orders a whole chain, deepest first', function ()
		Chief.new({ Verbose = false })
			:AddModules({ depTop, depMiddle, depLeaf })
			:AddExtension(Dependencies.new())
			:Start()

		expect(eventString()).toBe('DepLeaf.Init, DepMiddle.Init:DepLeaf, DepTop.Init:DepMiddle')
	end)

	it('errors on a dependency cycle, naming the path', function ()
		local chief = Chief.new({ Verbose = false }):AddModule(depCycleOne):AddExtension(Dependencies.new())

		expect(function ()
			chief:Start()
		end).toThrow('CyclicDependency')
	end)
end)

describe('loading', function ()
	it('transitively loads a dependency that was never added', function ()
		-- Only DepTop is added; DepMiddle and DepLeaf must be pulled in.
		Chief.new({ Verbose = false }):AddModule(depTop):AddExtension(Dependencies.new()):Start()

		expect(eventString()).toBe('DepLeaf.Init, DepMiddle.Init:DepLeaf, DepTop.Init:DepMiddle')
	end)
end)

describe('injection', function ()
	it('replaces the marker field with the real module', function ()
		Chief.new({ Verbose = false }):AddModules({ depMiddle, depLeaf }):AddExtension(Dependencies.new()):Start()

		local leaf = require(depLeaf) :: any

		expect(middleModule.Leaf).toBe(leaf)
	end)

	it('errors when the module table is frozen', function ()
		local chief = Chief.new({ Verbose = false }):AddModule(depFrozen):AddExtension(Dependencies.new())

		expect(function ()
			chief:Start()
		end).toThrow('FrozenModule')
	end)
end)

return {}
