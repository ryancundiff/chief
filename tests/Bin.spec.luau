--!strict

local Bin = require('../packages/bin/src')
local Runner = require('./Runner')

local describe = Runner.describe
local expect = Runner.expect
local it = Runner.it

describe('Add', function ()
	it('returns the item, so adds can wrap assignments', function ()
		local bin = Bin.new()
		local item = function () end

		expect(bin:Add(item)).toBe(item)
	end)

	it('errors on anything that is not a BinItem', function ()
		local bin = Bin.new()

		expect(function ()
			bin:Add(5 :: any)
		end).toThrow('BadArgument')
	end)
end)

describe('Empty', function ()
	it('disconnects connections', function ()
		local bin = Bin.new()
		local bindable = Instance.new('BindableEvent')
		local connection = bin:Add(bindable.Event:Connect(function () end)) :: RBXScriptConnection

		expect(connection.Connected).toBe(true)

		bin:Empty()

		expect(connection.Connected).toBe(false)

		bindable:Destroy()
	end)

	it('destroys instances', function ()
		local bin = Bin.new()
		local folder = bin:Add(Instance.new('Folder')) :: Folder
		folder.Parent = workspace

		bin:Empty()

		expect(folder.Parent).toBeNil()
	end)

	it('cancels threads', function ()
		local bin = Bin.new()
		local thread = bin:Add(task.spawn(function ()
			task.wait(60)
		end)) :: thread

		bin:Empty()

		expect(coroutine.status(thread)).toBe('dead')
	end)

	it('calls functions', function ()
		local bin = Bin.new()
		local called = false

		bin:Add(function ()
			called = true
		end)

		bin:Empty()

		expect(called).toBe(true)
	end)

	it('cleans up in reverse insertion order, so teardown unwinds setup', function ()
		local bin = Bin.new()
		local order: { string } = {}

		bin:Add(function ()
			table.insert(order, 'first added')
		end)
		bin:Add(function ()
			table.insert(order, 'second added')
		end)

		bin:Empty()

		expect(table.concat(order, ', ')).toBe('second added, first added')
	end)

	it('leaves the Bin usable afterward', function ()
		local bin = Bin.new()
		local calls = 0

		local function count ()
			calls += 1
		end

		bin:Add(count)
		bin:Empty()
		bin:Add(count)
		bin:Empty()

		expect(calls).toBe(2)
	end)

	it('does not re-run items on a second Empty', function ()
		local bin = Bin.new()
		local calls = 0

		bin:Add(function ()
			calls += 1
		end)

		bin:Empty()
		bin:Empty()

		expect(calls).toBe(1)
	end)
end)

return {}
