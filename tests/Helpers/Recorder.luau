--!strict

--[=[
	Shared event log for test fixtures.

	Fixture modules and specs require this module and receive the same table
	(Luau caches module results per ModuleScript), so fixtures can record
	lifecycle calls for specs to assert on.
]=]
local Recorder = {}

local events: { string } = {}

--[[ METHODS ]]

--[=[
	Append an event name to the log.

	@param eventName string
]=]
function Recorder.record (eventName: string)
	table.insert(events, eventName)
end

--[=[
	Return a copy of the logged events.

	@return { string }
]=]
function Recorder.getEvents (): { string }
	return table.clone(events)
end

--[=[
	Clear the log.
]=]
function Recorder.reset ()
	table.clear(events)
end

return Recorder
