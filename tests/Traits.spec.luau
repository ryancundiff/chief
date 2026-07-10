--!strict

local CollectionService = game:GetService('CollectionService')

local tests = script.Parent

local Chief = require('../packages/core/src')
local Runner = require('./Runner')
local Traits = require('../packages/traits/src')
local recorder = require('./Helpers/Recorder')

local afterEach = Runner.afterEach
local beforeEach = Runner.beforeEach
local describe = Runner.describe
local expect = Runner.expect
local it = Runner.it

local fixtures = tests.Fixtures
local traitDoor = require(fixtures.TraitDoor)
local traitModelOnly = require(fixtures.TraitModelOnly)

local DOOR_TAG = 'ChiefTestDoor'
local MODEL_TAG = 'ChiefTestModelOnly'

-- A trait can only be wired once per module table, and watching starts at PostStart, so boot a
-- single Chief for the whole spec. Tests then tag instances and wait for the CollectionService signal.
Chief.new({ Verbose = false }):AddExtension(Traits.new({ fixtures.TraitDoor, fixtures.TraitModelOnly })):Start()

-- Every instance a test creates, torn down afterwards so tags never leak between tests.
local created: { Instance } = {}

local function track <T>(instance: T & Instance): T
	table.insert(created, instance)

	return instance
end

--[=[
	A tagged BasePart that satisfies the Door contract.

	@return BasePart
]=]
local function makeDoor (): BasePart
	local part = track(Instance.new('Part'))
	local prompt = track(Instance.new('ProximityPrompt'))

	prompt.Name = 'Prompt'
	prompt.Parent = part
	part.Parent = workspace

	CollectionService:AddTag(part, DOOR_TAG)
	task.wait()

	return part
end

local function eventString ()
	return table.concat(recorder.getEvents(), ', ')
end

beforeEach(function ()
	recorder.reset()
end)

afterEach(function ()
	for index = #created, 1, -1 do
		created[index]:Destroy()
		created[index] = nil
	end

	task.wait()
	recorder.reset()
end)

describe('info', function ()
	it('errors without a Tag', function ()
		expect(function ()
			(Traits.info :: any)({})
		end).toThrow('BadArgument')
	end)

	it('errors on an empty Tag', function ()
		expect(function ()
			(Traits.info :: any)({ Tag = '' })
		end).toThrow('BadArgument')
	end)

	it('errors when InstanceIs is not a string', function ()
		expect(function ()
			(Traits.info :: any)({ Tag = 'X', InstanceIs = 5 })
		end).toThrow('BadArgument')
	end)

	it('errors when an attribute is not made with Traits.attribute', function ()
		expect(function ()
			(Traits.info :: any)({ Tag = 'X', Attributes = { Angle = 'nope' } })
		end).toThrow('BadArgument')
	end)

	it('errors when a child claims a reserved field name', function ()
		expect(function ()
			(Traits.info :: any)({ Tag = 'X', Children = { Instance = Traits.child('Part') } })
		end).toThrow('BadArgument')
	end)

	it('defaults InstanceIs to Instance', function ()
		local info = (Traits.info :: any)({ Tag = 'X' })

		expect(info.InstanceIs).toBe('Instance')
	end)
end)

describe('attribute and child', function ()
	it('errors on an unknown attribute kind', function ()
		expect(function ()
			(Traits.attribute :: any)('notakind')
		end).toThrow('BadArgument')
	end)

	it('errors when the default does not match the kind', function ()
		expect(function ()
			(Traits.attribute :: any)('number', 'ninety')
		end).toThrow('BadArgument')
	end)

	it('errors when a child class name is not a string', function ()
		expect(function ()
			(Traits.child :: any)(5)
		end).toThrow('BadArgument')
	end)
end)

describe('new', function ()
	it('errors when given something other than a table', function ()
		expect(function ()
			Traits.new(5 :: any)
		end).toThrow('BadArgument')
	end)

	it('errors when an element is not a ModuleScript', function ()
		expect(function ()
			Traits.new({ 5 :: any })
		end).toThrow('BadArgument')
	end)

	it('errors when a module carries no Info contract', function ()
		expect(function ()
			Traits.new({ tests.Helpers.Recorder :: any })
		end).toThrow('BadArgument')
	end)
end)

describe('binding', function ()
	it('binds a tagged instance, running Init then Start', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		expect(bound.Instance).toBe(part)
		expect(eventString()).toBe('Door.Init, Door.Start')
	end)

	it('injects declared children and writes attribute defaults back to the instance', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		expect(bound.Prompt).toBe(part:FindFirstChild('Prompt'))
		expect(bound.Attributes.OpenAngle).toBe(90)
		expect(part:GetAttribute('OpenAngle')).toBe(90)
	end)

	it('does not bind an instance of the wrong class', function ()
		local part = track(Instance.new('Part'))
		part.Parent = workspace

		CollectionService:AddTag(part, MODEL_TAG)
		task.wait()

		expect(Traits.get(part, traitModelOnly)).toBeNil()
	end)

	it('does not bind when a declared child is missing', function ()
		local part = track(Instance.new('Part'))
		part.Parent = workspace

		CollectionService:AddTag(part, DOOR_TAG)
		task.wait()

		expect(Traits.get(part, traitDoor)).toBeNil()
	end)

	it('exposes every bound object through getAll', function ()
		makeDoor()
		makeDoor()

		expect(#Traits.getAll(traitDoor)).toBe(2)
	end)
end)

describe('attributes proxy', function ()
	it('writes through to the instance and fires AttributeChanged', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		bound.Attributes.OpenAngle = 45

		expect(part:GetAttribute('OpenAngle')).toBe(45)
		expect(bound.Attributes.OpenAngle).toBe(45)

		task.wait()

		expect(eventString()).toContain('Door.AttributeChanged:OpenAngle=45')
	end)

	it('errors on an undeclared attribute', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		expect(function ()
			(bound.Attributes :: any).Bogus = 1
		end).toThrow('BadAttribute')
	end)

	it('errors when the value does not match the declared kind', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		expect(function ()
			(bound.Attributes :: any).OpenAngle = 'wide'
		end).toThrow('BadAttribute')
	end)
end)

describe('unbinding', function ()
	it('runs Destroy and empties the Bin when the tag is removed', function ()
		local part = makeDoor()

		local bound = Traits.get(part, traitDoor)
		assert(bound, 'expected the door to bind')

		local binned = Instance.new('Folder')
		binned.Parent = workspace
		bound.Bin:Add(binned)

		CollectionService:RemoveTag(part, DOOR_TAG)
		task.wait()

		expect(Traits.get(part, traitDoor)).toBeNil()
		expect(eventString()).toContain('Door.Destroy')
		expect(binned.Parent).toBeNil()
	end)
end)

return {}
