--!strict

local tests = script.Parent

local Chief = require('../packages/core/src')
local Lifecycles = require('../packages/lifecycles/src')
local Runner = require('./Runner')
local recorder = require('./Helpers/Recorder')

local beforeEach = Runner.beforeEach
local describe = Runner.describe
local expect = Runner.expect
local it = Runner.it

local fixtures = tests.Fixtures
local lifePingA = fixtures.LifePingA
local lifePingB = fixtures.LifePingB
local lifeSilent = fixtures.LifeSilent

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

--[=[
	Boot Chief with one lifecycle whose `Connect` captures the dispatcher, so a test can fire the
	event directly instead of waiting on a real Roblox signal.

	@param method string
	@param isolate boolean?
	@return (fire, connectCalled)
]=]
local function bootCapturing (method: string, isolate: boolean?): ((...any) -> (), () -> boolean)
	local captured: ((...any) -> ())? = nil

	local lifecycle: Lifecycles.Lifecycle = {
		Method = method,
		Isolate = isolate,
		Connect = function (dispatch)
			captured = dispatch

			return nil
		end,
	}

	Chief.new({ Verbose = false })
		:AddModules({ lifePingA, lifePingB, lifeSilent })
		:AddExtension(Lifecycles.new({ lifecycle }))
		:Start()

	local function fire (...: any)
		assert(captured, 'lifecycle was never connected')

		captured(...)
	end

	return fire, function ()
		return captured ~= nil
	end
end

beforeEach(function ()
	recorder.reset()
end)

describe('new', function ()
	it('errors when given something other than a table', function ()
		expect(function ()
			Lifecycles.new(5 :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when given a map instead of an array', function ()
		expect(function ()
			Lifecycles.new({ first = { Method = 'X', Connect = function () end } } :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when Method is not a string', function ()
		expect(function ()
			Lifecycles.new({ { Method = 5, Connect = function () end } } :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when Connect is neither a signal nor a function', function ()
		expect(function ()
			Lifecycles.new({ { Method = 'X', Connect = 5 } } :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when Isolate is not a boolean', function ()
		expect(function ()
			Lifecycles.new({ { Method = 'X', Connect = function () end, Isolate = 'yes' } } :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when the same lifecycle is passed twice', function ()
		local lifecycle: Lifecycles.Lifecycle = {
			Method = 'X',
			Connect = function ()
				return nil
			end,
		}

		expect(function ()
			Lifecycles.new({ lifecycle, lifecycle })
		end).toThrow('BadArgument')
	end)
end)

describe('dispatch', function ()
	it('calls every module implementing the method, with the module as self', function ()
		local fire = bootCapturing('Ping')

		fire('hi')

		expect(eventString()).toBe('A.Ping:hi:true, B.Ping:hi:true')
	end)

	it('never connects a lifecycle no module implements', function ()
		local _, connectCalled = bootCapturing('Nobody')

		expect(connectCalled()).toBe(false)
	end)

	it('wires at PostInit, so nothing dispatches before Start finishes', function ()
		local captured = nil

		local lifecycle: Lifecycles.Lifecycle = {
			Method = 'Ping',
			Connect = function (dispatch)
				captured = dispatch

				return nil
			end,
		}

		local chief = Chief.new({ Verbose = false }):AddModule(lifePingA):AddExtension(Lifecycles.new({ lifecycle }))

		expect(captured).toBeNil()

		chief:Start()

		expect(captured).toBeTruthy()
	end)

	it('connects an RBXScriptSignal directly', function ()
		local bindable = Instance.new('BindableEvent')

		local lifecycle: Lifecycles.Lifecycle = {
			Method = 'Bindable',
			Connect = bindable.Event,
		}

		Chief.new({ Verbose = false })
			:AddModules({ lifePingA, lifePingB })
			:AddExtension(Lifecycles.new({ lifecycle }))
			:Start()

		bindable:Fire('go')
		task.wait()

		expect(eventString()).toContain('A.Bindable:go')
		expect(eventString()).toContain('B.Bindable:go')

		bindable:Destroy()
	end)
end)

describe('isolation', function ()
	it('isolates handlers by default, so a slow one does not delay the others', function ()
		local fire = bootCapturing('Slow')

		fire()

		-- A yields; B has already run and fire() returned without waiting for A.
		expect(eventString()).toBe('B.Slow')

		task.wait(0.1)

		expect(eventString()).toBe('B.Slow, A.Slow')
	end)

	it('runs handlers inline when Isolate is false, so a yield blocks the dispatch', function ()
		local fire = bootCapturing('SlowShared', false)

		fire()

		-- fire() yielded through A's handler, so both have run in module order by the time it returns.
		expect(eventString()).toBe('A.SlowShared, B.SlowShared')
	end)
end)

return {}
