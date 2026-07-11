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

local moduleA = require(lifePingA) :: any

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

--[=[
	Boot Chief with one lifecycle whose `Connect` captures the dispatcher, so a test can fire the
	event directly instead of waiting on a real Roblox signal.

	@param method string
	@param dispatch Lifecycles.Dispatch?
	@return (fire, connectCalled)
]=]
local function bootCapturing (method: string, dispatch: Lifecycles.Dispatch?): ((...any) -> (), () -> boolean)
	local captured: ((...any) -> ())? = nil

	local lifecycle: Lifecycles.Lifecycle = {
		Method = method,
		Dispatch = dispatch,
		Connect = function (fire)
			captured = fire

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

	it('errors when Dispatch is not a mode', function ()
		expect(function ()
			Lifecycles.new({ { Method = 'X', Connect = function () end, Dispatch = 'Sometimes' } } :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when Dispatch is not a string', function ()
		expect(function ()
			Lifecycles.new({ { Method = 'X', Connect = function () end, Dispatch = 5 } } :: any)
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
			Connect = function (fire)
				captured = fire

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

describe('Spawn mode', function ()
	it('isolates handlers, so a slow one does not delay the others', function ()
		local fire = bootCapturing('Slow')

		fire()

		-- A yields; B has already run and fire() returned without waiting for A.
		expect(eventString()).toBe('B.Slow')

		task.wait(0.1)

		expect(eventString()).toBe('B.Slow, A.Slow')
	end)
end)

describe('Inline mode', function ()
	it('runs handlers on the event thread, so a yield blocks the dispatch', function ()
		local fire = bootCapturing('SlowShared', 'Inline')

		fire()

		-- fire() yielded through A's handler, so both have run in module order by the time it returns.
		expect(eventString()).toBe('A.SlowShared, B.SlowShared')
	end)
end)

describe('Await mode', function ()
	it('blocks fire until every handler has finished, running them concurrently', function ()
		local fire = bootCapturing('AwaitSlow', 'Await')

		fire()

		-- B ran immediately while A was yielding; fire only returned once A finished too.
		expect(eventString()).toBe('B.AwaitSlow, A.AwaitSlow')
	end)

	it('survives an erroring handler: the others run and fire still returns', function ()
		local fire = bootCapturing('AwaitError', 'Await')

		-- A LifecycleError warning for A's handler is expected in the output here.
		fire()

		expect(eventString()).toBe('B.AwaitError')
	end)

	it('returns immediately when every handler is synchronous', function ()
		local fire = bootCapturing('AwaitFast', 'Await')

		fire()

		expect(eventString()).toBe('A.AwaitFast, B.AwaitFast')
	end)
end)

describe('every', function ()
	it('errors when seconds is not positive', function ()
		expect(function ()
			Lifecycles.every(0, 'Tick')
		end).toThrow('BadArgument')
	end)

	it('errors when seconds is not a number', function ()
		expect(function ()
			(Lifecycles.every :: any)('soon', 'Tick')
		end).toThrow('BadArgument')
	end)

	it('errors when method is not a non-empty string', function ()
		expect(function ()
			Lifecycles.every(1, '')
		end).toThrow('BadArgument')
	end)

	it('ticks repeatedly with the elapsed time', function ()
		Chief.new({ Verbose = false })
			:AddModule(lifePingA)
			:AddExtension(Lifecycles.new({ Lifecycles.every(0.05, 'Tick') }))
			:Start()

		-- The loop lives for the session; the flag confines recording to this test.
		moduleA.TickEnabled = true
		task.wait(0.18)
		moduleA.TickEnabled = false

		local events = recorder.getEvents()

		expect(#events >= 2).toBe(true)
		expect(events[1]).toBe('A.Tick:number')
	end)
end)

describe('built-ins', function ()
	it('dispatches Heartbeat with frame delta times', function ()
		-- Heartbeat rather than PostSimulation: the physics-step signals (PreSimulation,
		-- PostSimulation) do not fire in headless Open Cloud tasks, while Heartbeat does.
		Chief.new({ Verbose = false })
			:AddModule(lifePingA)
			:AddExtension(Lifecycles.new({ Lifecycles.Heartbeat }))
			:Start()

		-- The connection lives for the session; the flag confines recording to this test.
		moduleA.FrameEnabled = true
		task.wait()
		task.wait()
		moduleA.FrameEnabled = false

		expect(eventString()).toContain('A.Heartbeat')
	end)

	it('wires the player, character, and closing built-ins without erroring', function ()
		-- No players exist under Open Cloud, and the place closes only after the run, so none of
		-- these fire; this proves each built-in's Connect runs end to end (replay loops included).
		Chief.new({ Verbose = false })
			:AddModule(lifePingA)
			:AddExtension(Lifecycles.new({
				Lifecycles.PlayerAdded,
				Lifecycles.PlayerRemoving,
				Lifecycles.CharacterAdded,
				Lifecycles.CharacterRemoving,
				Lifecycles.Closing,
				-- Not implemented by the module, so these never connect -- including PreRender,
				-- whose client-only signal would error if the opt-in check did not gate it.
				Lifecycles.PreRender,
				Lifecycles.PreAnimation,
				Lifecycles.PreSimulation,
				Lifecycles.PostSimulation,
			}))
			:Start()

		expect(eventString()).toBe('')
	end)
end)

return {}
