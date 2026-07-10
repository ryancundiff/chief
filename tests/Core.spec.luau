--!strict

local tests = script.Parent

local Chief = require('../packages/core/src')
local Runner = require('./Runner')
local recorder = require('./Helpers/Recorder')

local beforeEach = Runner.beforeEach
local describe = Runner.describe
local expect = Runner.expect
local it = Runner.it

local fixtures = tests.Fixtures
local highPriority = fixtures.HighPriority
local lowPriority = fixtures.LowPriority
local tiedOne = fixtures.TiedOne
local tiedTwo = fixtures.TiedTwo
local yieldsOnInit = fixtures.YieldsOnInit
local loadedLater = fixtures.LoadedLater

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

beforeEach(function ()
	recorder.reset()
end)

describe('boot sequence', function ()
	it('runs Init in priority order, then Start', function ()
		Chief.new({ Verbose = false }):AddModules({ lowPriority, highPriority }):Start()

		expect(eventString()).toBe('HighPriority.Init, LowPriority.Init, HighPriority.Start, LowPriority.Start')
	end)

	it('breaks priority ties by insertion order', function ()
		Chief.new({ Verbose = false }):AddModules({ tiedTwo, tiedOne }):Start()

		expect(eventString()).toBe('TiedTwo.Init, TiedOne.Init')
	end)

	it('ignores duplicate adds of the same ModuleScript', function ()
		Chief.new({ Verbose = false }):AddModule(highPriority):AddModule(highPriority):Start()

		expect(eventString()).toBe('HighPriority.Init, HighPriority.Start')
	end)

	it('errors when a module yields during Init', function ()
		local chief = Chief.new({ Verbose = false }):AddModule(yieldsOnInit)

		expect(function ()
			chief:Start()
		end).toThrow('NoYield')
	end)
end)

describe('guards', function ()
	it('errors when adding a module after start', function ()
		local chief = Chief.new({ Verbose = false }):Start()

		expect(function ()
			chief:AddModule(highPriority)
		end).toThrow('BadCall')
	end)

	it('errors when starting twice', function ()
		local chief = Chief.new({ Verbose = false }):Start()

		expect(function ()
			chief:Start()
		end).toThrow('BadCall')
	end)

	it('errors when adding a non-ModuleScript', function ()
		local chief = Chief.new({ Verbose = false })

		expect(function ()
			chief:AddModule(5 :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when LoadModule is called outside the load window', function ()
		local chief = Chief.new({ Verbose = false })

		expect(function ()
			chief:LoadModule(highPriority)
		end).toThrow('BadCall')
	end)
end)

describe('extensions', function ()
	it('fires phase hooks in order and module events per module', function ()
		local phases = {}
		local moduleEvents = {}

		Chief.new({ Verbose = false })
			:AddExtension({
				Name = 'RecorderExtension',
				onPhase = function (_chief, phase)
					table.insert(phases, phase)
				end,
				onModule = function (_chief, event, entry)
					table.insert(moduleEvents, `{event}:{entry.Name}`)
				end,
			})
			:AddModule(lowPriority)
			:Start()

		expect(table.concat(phases, ', ')).toBe('PreLoad, PostLoad, PreInit, PostInit, PreStart, PostStart')
		expect(table.concat(moduleEvents, ', ')).toBe(
			'Loaded:LowPriority, Initialized:LowPriority, Started:LowPriority'
		)
	end)

	it('lets an extension load additional modules during PostLoad', function ()
		Chief.new({ Verbose = false })
			:AddExtension({
				Name = 'LoaderExtension',
				onPhase = function (chief, phase)
					if phase == 'PostLoad' then
						chief:LoadModule(loadedLater)
					end
				end,
			})
			:AddModule(highPriority)
			:Start()

		expect(eventString()).toBe('HighPriority.Init, LoadedLater.Init, HighPriority.Start')
	end)
end)

return {}
