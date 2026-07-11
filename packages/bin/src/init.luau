--!strict

--[=[
	A small cleanup container. Whatever is added is cleaned up when the Bin is emptied -- connections disconnected, instances destroyed, threads cancelled, functions called -- in reverse insertion order, so teardown unwinds setup.

	Extracted from the Traits extension, where every bound object carries one as `self.Bin`; usable anywhere teardown must not depend on someone remembering every disconnect.

	```luau
	local bin = Bin.new()

	bin:Add(part.Touched:Connect(onTouched))
	bin:Add(task.spawn(loop))
	bin:Add(function ()
		print('emptied')
	end)

	bin:Empty()
	```
]=]
local Bin = {}
local mt = { __index = Bin }

--[[ METHODS ]]

--[=[
	Create an empty Bin.

	@return Bin
]=]
function Bin.new (): Bin
	return setmetatable({
		_Items = {},
	}, mt) :: Bin
end

--[=[
	Add an item to clean up when the Bin is emptied. Returns the item so adds can wrap assignments.

	@param item BinItem -- A connection, instance, thread, or function.
	@return BinItem

	@error BadArgument -- Thrown when `item` is not a BinItem.
]=]
function Bin.Add (self: Bin, item: BinItem): BinItem
	local itemType = typeof(item)

	assert(
		itemType == 'RBXScriptConnection' or itemType == 'Instance' or itemType == 'thread' or itemType == 'function',
		`BadArgument: Bad argument #1 for Add (expected RBXScriptConnection, Instance, thread, or function, got {itemType})`
	)

	table.insert(self._Items, item)

	return item
end

--[=[
	Clean up every item and empty the Bin, in reverse insertion order. The Bin remains usable afterward.
]=]
function Bin.Empty (self: Bin)
	for index = #self._Items, 1, -1 do
		local item = self._Items[index]
		local itemType = typeof(item)

		if itemType == 'RBXScriptConnection' then
			(item :: RBXScriptConnection):Disconnect()
		elseif itemType == 'Instance' then
			(item :: Instance):Destroy()
		elseif itemType == 'thread' then
			task.cancel(item :: thread)
		else
			(item :: () -> ())()
		end
	end

	table.clear(self._Items)
end

--[[ TYPES ]]

--[=[
	An item a Bin can clean up: a connection (disconnected), instance (destroyed), thread (cancelled), or function (called).
]=]
export type BinItem = RBXScriptConnection | Instance | thread | () -> ()

--[=[
	A cleanup container created by `Bin.new`.
]=]
export type Bin = setmetatable<{
	--[=[
		Items to clean up, in insertion order. Used internally by Bin.

		@private
	]=]
	_Items: { BinItem },
}, typeof(mt)>

return Bin
