--!strict

local Chief = require('./roblox_packages/core')

--[=[
	The Dependencies extension: topological dependency injection for Chief.

	Modules declare dependencies with `Dependencies.use(moduleScript)` markers
	assigned to fields on their module table. During `PostLoad` the extension
	transitively loads any dependency that wasn't explicitly added to Chief.
	Then, during `PreInit` -- after every extension has finished loading
	modules -- it:
	1. Builds the dependency graph and topologically sorts it (Kahn's algorithm), so every module's `Init` runs *after* the `Init` of everything it depends on. `Priority` breaks ties between modules with no ordering constraint between them.
	2. Errors with the full cycle path if a dependency cycle exists, instead of silently producing a broken order.
	3. Replaces every marker field with the real, required module -- by the time `Init` runs, `self.Data` is the actual module, not a proxy.

	How to use a dependency in a module:
	```
	local ShopModule = {}

	ShopModule.DataModule = Dependencies.use(script.Parent.DataModule) :: typeof(require(script.Parent.DataModule))

	function ShopModule.Start (self: Self)
		self.DataModule:Get('coins') -- Real module. Injected before Init, initialized before this Init would run.
	end

  type Self = typeof(ShopModule)

	return ShopModule
	```

	**Note**
	- Markers must be assigned to *fields on the module table*, never to locals. The extension injects by replacing fields; a local holding a marker can't be reached.
	- Because `use` takes the ModuleScript (not a require), module bodies never require each other, so circular *requires* can't happen. Circular *dependencies* are still impossible to order and are reported as an error.
	- Do not `table.freeze` a module that declares dependencies -- injection writes to its fields.
]=]
local Dependencies = {}

--[[ HELPERS ]]

-- Unique, private marker key. A local table can never collide with a key in user data, unlike a magic string field.
local MARKER = {}

--[=[
	Returns whether `value` is a dependency marker produced by `use`.

	@param value unknown
	@return boolean
]=]
local function isMarker (value: unknown): boolean
	return typeof(value) == 'table' and (value :: any)[MARKER] == true
end

--[=[
	Kahn's algorithm over entries. `dependenciesOf` maps entry -> array ofunique dependency entries. Returns entries ordered dependencies-first, ornil if a cycle prevents a complete ordering. Among entries whose dependencies are all satisfied, higher `Priority` initializes first, then original order.

	@param entries { Chief.Entry }
	@param dependenciesOf { [Chief.Entry]: { Chief.Entry } }
	@return { Chief.Entry }?
]=]
local function topologicalSort (
	entries: { Chief.Entry },
	dependenciesOf: { [Chief.Entry]: { Chief.Entry } }
): { Chief.Entry }?
	local originalIndex: { [Chief.Entry]: number } = {}
	local inDegree: { [Chief.Entry]: number } = {}
	local dependentsOf: { [Chief.Entry]: { Chief.Entry } } = {}

	for index, entry in entries do
		originalIndex[entry] = index
		inDegree[entry] = #dependenciesOf[entry]
		dependentsOf[entry] = {}
	end

	for _, entry in entries do
		for _, dependency in dependenciesOf[entry] do
			table.insert(dependentsOf[dependency], entry)
		end
	end

	local ready: { Chief.Entry } = {}
	for _, entry in entries do
		if inDegree[entry] == 0 then
			table.insert(ready, entry)
		end
	end

	local sorted: { Chief.Entry } = {}

	while #ready > 0 do
		-- Pick the best ready entry: highest Priority, then earliest added.
		local bestIndex = 1
		for index = 2, #ready do
			local best, candidate = ready[bestIndex], ready[index]
			local bestPriority = best.Module.Priority or 0
			local candidatePriority = candidate.Module.Priority or 0

			if
				candidatePriority > bestPriority
				or (candidatePriority == bestPriority and originalIndex[candidate] < originalIndex[best])
			then
				bestIndex = index
			end
		end

		local entry = table.remove(ready, bestIndex) :: Chief.Entry
		table.insert(sorted, entry)

		for _, dependent in dependentsOf[entry] do
			inDegree[dependent] -= 1

			if inDegree[dependent] == 0 then
				table.insert(ready, dependent)
			end
		end
	end

	if #sorted < #entries then
		return nil
	end

	return sorted
end

--[=[
	Finds and formats one dependency cycle among the given entries via depth-first search, eg. `Shop -> Data -> Shop`. Only called after Kahn's algorithm has already proven a cycle exists.

	@param entries { Chief.Entry }
	@param dependenciesOf { [Chief.Entry]: { Chief.Entry } }
	@return string
]=]
local function findCyclePath (entries: { Chief.Entry }, dependenciesOf: { [Chief.Entry]: { Chief.Entry } }): string
	local state: { [Chief.Entry]: 'Visiting' | 'Done' } = {}
	local stack: { Chief.Entry } = {}

	local function visit (entry: Chief.Entry): { Chief.Entry }?
		state[entry] = 'Visiting'
		table.insert(stack, entry)

		for _, dependency in dependenciesOf[entry] do
			if state[dependency] == 'Visiting' then
				local cycle = {}
				local start = table.find(stack, dependency) :: number

				table.move(stack, start, #stack, 1, cycle)
				table.insert(cycle, dependency)

				return cycle
			elseif state[dependency] == nil then
				local cycle = visit(dependency)

				if cycle then
					return cycle
				end
			end
		end

		state[entry] = 'Done'
		table.remove(stack)

		return nil
	end

	for _, entry in entries do
		if state[entry] == nil then
			local cycle = visit(entry)

			if cycle then
				local names = {}
				for _, cycleEntry in cycle do
					table.insert(names, cycleEntry.Name)
				end

				return table.concat(names, ' -> ')
			end
		end
	end

	return '(cycle could not be reconstructed)'
end

--[[ METHODS ]]

--[=[
	Declare a dependency on another module. Assign the result to a field on your module table; the Dependencies extension replaces the field with the real module during boot, before any `Init` runs.

	For full types, cast with `typeof(require(...))` -- Luau evaluates that at type level only, so it does not cause a runtime circular require:
	```
	ShopModule.Data = Dependencies.use(script.Parent.DataModule) :: typeof(require(script.Parent.DataModule))
	```

	@param moduleScript ModuleScript -- The dependency's ModuleScript.
	@return any -- A marker table, replaced with the real module at boot.

	@error BadArgument -- Thrown when moduleScript is not a `ModuleScript`.
]=]
function Dependencies.use (moduleScript: ModuleScript): any
	assert(
		typeof(moduleScript) == 'Instance' and moduleScript:IsA('ModuleScript'),
		`BadArgument: Bad argument #1 for use (expected ModuleScript, got {typeof(moduleScript)})`
	)

	return {
		[MARKER] = true,
		ModuleScript = moduleScript,
	}
end

--[=[
	Create the Dependencies extension. Add it to Chief with `AddExtension`.

	Each instance tracks the state of a single boot -- create one per Chief instance rather than sharing an instance between them.

	Ordering and injection run at `PreInit`, after every extension's `PostLoad` loading has finished -- registration order relative to other module-loading extensions does not matter.

	@return Extension
]=]
function Dependencies.new (): Chief.Extension
	-- Entry -> array of { Field, ModuleScript } declared by that module.
	local markersOf: { [Chief.Entry]: { { Field: any, ModuleScript: ModuleScript } } } = {}
	local entryByScript: { [ModuleScript]: Chief.Entry } = {}

	local function onModule (_chief: Chief.Self, event: Chief.ModuleEvent, entry: Chief.Entry)
		if event ~= 'Loaded' then
			return
		end

		entryByScript[entry.ModuleScript] = entry

		local markers = {}

		if typeof(entry.Module) == 'table' then
			for field, value in entry.Module :: any do
				if isMarker(value) then
					table.insert(markers, {
						Field = field,
						ModuleScript = value.ModuleScript :: ModuleScript,
					})
				end
			end
		end

		markersOf[entry] = markers
	end

	-- The work is split across two phases. Loading must happen at PostLoad (LoadModule is only callable during the Load/PostLoad window), but ordering and injection wait until PreInit -- by then every extension's PostLoad loading has finished, so modules loaded by extensions registered after this one are still ordered and injected.
	local function onPhase (chief: Chief.Self, phase: Chief.Phase, entries: { Chief.Entry })
		if phase == 'PostLoad' then
			-- Transitively load dependencies that weren't explicitly added. LoadModule appends to `entries` and fires Loaded (which records the new entry's markers above), so this loop naturally walks the whole graph.
			local index = 1
			while index <= #entries do
				for _, marker in markersOf[entries[index]] do
					if not entryByScript[marker.ModuleScript] then
						chief:LoadModule(marker.ModuleScript)
					end
				end

				index += 1
			end

			return
		end

		if phase ~= 'PreInit' then
			return
		end

		-- 1. Build the graph (unique dependencies per entry).
		local dependenciesOf: { [Chief.Entry]: { Chief.Entry } } = {}

		for _, entry in entries do
			local unique: { [Chief.Entry]: boolean } = {}
			local dependencies = {}

			for _, marker in markersOf[entry] do
				local dependency = entryByScript[marker.ModuleScript]

				-- A module loaded after the PostLoad walk above (eg. by a later-registered extension) can declare a dependency that nothing ever loaded, and the load window is closed by now. Fail loudly instead of ordering and injecting incorrectly.
				assert(
					dependency,
					`MissingDependency: Cannot resolve dependency '{marker.ModuleScript.Name}' of {entry.Name} (never loaded -- add it to Chief directly)`
				)

				if not unique[dependency] then
					unique[dependency] = true
					table.insert(dependencies, dependency)
				end
			end

			dependenciesOf[entry] = dependencies
		end

		-- 2. Topologically sort. A cycle makes Init ordering impossible, so it errors with the offending path rather than booting incorrectly.
		local sorted = topologicalSort(entries, dependenciesOf)

		assert(
			sorted,
			`CyclicDependency: Cannot order Init (dependency cycle: {findCyclePath(entries, dependenciesOf)})\n`
				.. '  Break the cycle by moving the cross-calls out of Init, or invert one of the dependencies'
		)

		table.clear(entries)
		table.move(sorted, 1, #sorted, 1, entries)

		-- 3. Inject: replace every marker field with the real module.
		for _, entry in entries do
			for _, marker in markersOf[entry] do
				assert(
					not table.isfrozen(entry.Module :: any),
					`FrozenModule: Cannot inject '{tostring(marker.Field)}' into {entry.Name} (module table is frozen)`
				);

				(entry.Module :: any)[marker.Field] = entryByScript[marker.ModuleScript].Module
			end
		end
	end

	return {
		Name = 'Dependencies',
		onModule = onModule,
		onPhase = onPhase,
	}
end

return Dependencies
