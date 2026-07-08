--!nocheck
-- TestEZ injects describe/it/expect/beforeEach into the spec's function
-- environment at runtime, which strict mode cannot see.

local Chief = require('../Packages/core/src')
local recorder = require('./Helpers/Recorder')

local fixtures = script.Parent:FindFirstChild('Fixtures')
local highPriority = fixtures:FindFirstChild('HighPriority')
local lowPriority = fixtures:FindFirstChild('LowPriority')
local tiedOne = fixtures:FindFirstChild('TiedOne')
local tiedTwo = fixtures:FindFirstChild('TiedTwo')
local yieldsOnInit = fixtures:FindFirstChild('YieldsOnInit')
local loadedLater = fixtures:FindFirstChild('LoadedLater')

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

return function ()
	beforeEach(function ()
		recorder.reset()
	end)

	describe('boot sequence', function ()
		it('runs Init in priority order, then Start', function ()
			Chief.new({ Verbose = false }):AddModules({ lowPriority, highPriority }):Start()

			expect(eventString()).to.equal('HighPriority.Init, LowPriority.Init, HighPriority.Start, LowPriority.Start')
		end)

		it('breaks priority ties by insertion order', function ()
			Chief.new({ Verbose = false }):AddModules({ tiedTwo, tiedOne }):Start()

			expect(eventString()).to.equal('TiedTwo.Init, TiedOne.Init')
		end)

		it('ignores duplicate adds of the same ModuleScript', function ()
			Chief.new({ Verbose = false }):AddModule(highPriority):AddModule(highPriority):Start()

			expect(eventString()).to.equal('HighPriority.Init, HighPriority.Start')
		end)

		it('errors when a module yields during Init', function ()
			local chief = Chief.new({ Verbose = false }):AddModule(yieldsOnInit)

			local ok, message = pcall(function ()
				chief:Start()
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, 'NoYield', 1, true)).to.be.ok()
		end)
	end)

	describe('guards', function ()
		it('errors when adding a module after start', function ()
			local chief = Chief.new({ Verbose = false }):Start()

			local ok, message = pcall(function ()
				chief:AddModule(highPriority)
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, 'BadCall', 1, true)).to.be.ok()
		end)

		it('errors when starting twice', function ()
			local chief = Chief.new({ Verbose = false }):Start()

			local ok, message = pcall(function ()
				chief:Start()
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, 'BadCall', 1, true)).to.be.ok()
		end)

		it('errors when adding a non-ModuleScript', function ()
			local chief = Chief.new({ Verbose = false })

			local ok, message = pcall(function ()
				chief:AddModule(5)
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, 'BadArgument', 1, true)).to.be.ok()
		end)

		it('errors when LoadModule is called outside the load window', function ()
			local chief = Chief.new({ Verbose = false })

			local ok, message = pcall(function ()
				chief:LoadModule(highPriority)
			end)

			expect(ok).to.equal(false)
			expect(string.find(message, 'BadCall', 1, true)).to.be.ok()
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

			expect(table.concat(phases, ', ')).to.equal('PreLoad, PostLoad, PreInit, PostInit, PreStart, PostStart')
			expect(table.concat(moduleEvents, ', ')).to.equal(
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

			expect(eventString()).to.equal('HighPriority.Init, LoadedLater.Init, HighPriority.Start')
		end)
	end)
end
