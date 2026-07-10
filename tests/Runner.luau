--!strict

--[=[
	A minimal test runner for Chief.

	It exists because Jest's sandbox rejects require-by-string, which pesde's generated shims rely on -- under Jest, only dependency-free packages can be required at all. This runner loads specs with a plain `require`, so every package is testable.

	The API mirrors Jest's (`describe`, `it`, `beforeEach`, `expect(...).toBe(...)`) so specs read the same and could move back to Jest if that restriction is ever lifted. Unlike Jest, nothing is injected as a global: specs require what they use, so they typecheck under strict mode.

	How to write a spec (any ModuleScript named `*.spec`):
	```
	local Runner = require('./Runner')

	local describe = Runner.describe
	local expect = Runner.expect
	local it = Runner.it

	describe('addition', function ()
		it('adds', function ()
			expect(1 + 1).toBe(2)
		end)
	end)

	return {}
	```
]=]
local Runner = {}

--[[ HELPERS ]]

--[=[
	Render a value for a failure message: strings quoted, everything else via tostring.

	@param value any
	@return string
]=]
local function inspect (value: any): string
	if typeof(value) == 'string' then
		return `'{value}'`
	end

	return tostring(value)
end

--[=[
	Raise an assertion failure, blaming the spec line that called the matcher rather than this module.

	@param message string

	@error AssertionFailed
]=]
local function fail (message: string): ()
	-- Level 3: fail -> matcher -> the spec's `expect(...)` line.
	error(message, 3)
end

--[=[
	Create an empty suite.

	@param name string
	@param parent Suite?
	@return Suite
]=]
local function newSuite (name: string, parent: Suite?): Suite
	return {
		Name = name,
		Parent = parent,
		Tests = {},
		Children = {},
		BeforeEach = {},
		AfterEach = {},
	}
end

-- The suite currently being described. `describe` swaps it while its body runs.
local root: Suite = newSuite('', nil)
local current: Suite = root

--[=[
	Every hook from the root suite down to (and including) `suite`, outermost first. `AfterEach` hooks run in the reverse order, so teardown unwinds setup.

	@param suite Suite
	@param field 'BeforeEach' | 'AfterEach'
	@return { () -> () }
]=]
local function hooksFor (suite: Suite, field: 'BeforeEach' | 'AfterEach'): { () -> () }
	local ancestry: { Suite } = {}
	local node: Suite? = suite

	while node ~= nil do
		table.insert(ancestry, 1, node)
		node = node.Parent
	end

	if field == 'AfterEach' then
		local reversed: { Suite } = {}

		for index = #ancestry, 1, -1 do
			table.insert(reversed, ancestry[index])
		end

		ancestry = reversed
	end

	local hooks: { () -> () } = {}

	for _, ancestor in ancestry do
		for _, hook in ancestor[field] do
			table.insert(hooks, hook)
		end
	end

	return hooks
end

--[=[
	Run `callback`, returning false plus a traceback when it errors. Yields are allowed -- a test may `task.wait()` for a deferred signal -- so this cannot use Chief's own `callProtected`, which treats yielding as a failure.

	@param callback () -> ()
	@return (boolean, string?)
]=]
local function callProtected (callback: () -> ()): (boolean, string?)
	-- The traceback is captured in the handler, where the error's stack is still live. It cannot
	-- be returned from `xpcall`: `callback` returns nothing, so `xpcall` yields only the boolean.
	local traceback: string? = nil

	local ok = xpcall(callback, function (raised: any)
		traceback = debug.traceback(tostring(raised), 2)
	end)

	return ok, traceback
end

--[=[
	The full `describe > describe > it` path of a test, for reporting.

	@param suite Suite
	@param testName string
	@return string
]=]
local function pathOf (suite: Suite, testName: string): string
	local parts: { string } = { testName }
	local node: Suite? = suite

	while node ~= nil and node.Name ~= '' do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end

	return table.concat(parts, ' > ')
end

--[[ METHODS ]]

--[=[
	Group related tests. Nesting is allowed; `beforeEach` hooks accumulate from the outside in.

	@param name string
	@param body () -> () -- Declares the group's tests, hooks, and nested groups.
]=]
function Runner.describe (name: string, body: () -> ())
	local suite = newSuite(name, current)

	table.insert(current.Children, suite)

	local previous = current
	current = suite

	body()

	current = previous
end

--[=[
	Declare a test. The body may yield.

	@param name string
	@param body () -> ()
]=]
function Runner.it (name: string, body: () -> ())
	table.insert(current.Tests, { Name = name, Fn = body })
end

--[=[
	Run `body` before each test in the enclosing group (and its nested groups).

	@param body () -> ()
]=]
function Runner.beforeEach (body: () -> ())
	table.insert(current.BeforeEach, body)
end

--[=[
	Run `body` after each test in the enclosing group (and its nested groups), even when the test fails.

	@param body () -> ()
]=]
function Runner.afterEach (body: () -> ())
	table.insert(current.AfterEach, body)
end

--[=[
	Begin an assertion. Matchers are called with a dot, as in Jest: `expect(value).toBe(other)`.

	@param value any
	@return Expectation
]=]
function Runner.expect (value: any): Expectation
	local expectation: Expectation

	expectation = {
		--[=[ Identity (`==`) equality. ]=]
		toBe = function (expected: any)
			if value ~= expected then
				fail(`Expected {inspect(expected)}, got {inspect(value)}`)
			end
		end,

		--[=[ Anything but `nil` and `false`. ]=]
		toBeTruthy = function ()
			if not value then
				fail(`Expected a truthy value, got {inspect(value)}`)
			end
		end,

		--[=[ Only `nil` or `false`. ]=]
		toBeFalsy = function ()
			if value then
				fail(`Expected a falsy value, got {inspect(value)}`)
			end
		end,

		--[=[ Exactly `nil`. ]=]
		toBeNil = function ()
			if value ~= nil then
				fail(`Expected nil, got {inspect(value)}`)
			end
		end,

		--[=[ Substring of a string, or a member of an array. ]=]
		toContain = function (expected: any)
			if typeof(value) == 'string' then
				if typeof(expected) ~= 'string' then
					fail(`Expected a string to search for, got {inspect(expected)}`)
				end

				if string.find(value, expected, 1, true) == nil then
					fail(`Expected {inspect(value)} to contain {inspect(expected)}`)
				end

				return
			end

			if typeof(value) == 'table' then
				if table.find(value, expected) == nil then
					fail(`Expected {inspect(value)} to contain {inspect(expected)}`)
				end

				return
			end

			fail(`Expected a string or table, got {inspect(value)}`)
		end,

		--[=[
			Calls `value` (which must be a function) and asserts it raised. When `expected` is given, the error message must contain it -- Chief's errors are prefixed (`BadArgument:`, `CyclicDependency:`), so this asserts the kind, not the exact text.
		]=]
		toThrow = function (expected: string?)
			if typeof(value) ~= 'function' then
				fail(`Expected a function to call, got {inspect(value)}`)
			end

			local ok, raised = pcall(value)

			if ok then
				fail('Expected the function to throw, but it returned')
			end

			local message = tostring(raised)

			if expected ~= nil and string.find(message, expected, 1, true) == nil then
				fail(`Expected the error to contain {inspect(expected)}, got {inspect(message)}`)
			end
		end,
	}

	return expectation
end

--[=[
	Require every spec (which registers its tests as a side effect), then run them all.

	Prints a line per test and a summary, and returns the counts so the caller can decide how to fail.

	@param specs { ModuleScript } -- ModuleScripts that call `describe`/`it` at module scope.
	@return Results
]=]
function Runner.run (specs: { ModuleScript }): Results
	-- luau-lsp cannot resolve a require of a non-literal path, though Luau resolves it at runtime.
	local requireSpec = require :: (ModuleScript) -> any

	for _, spec in specs do
		-- Namespace each spec's suites under its own name, so two specs may both `describe('new', ...)`.
		local suite = newSuite(string.gsub(spec.Name, '%.spec$', ''), root)

		table.insert(root.Children, suite)

		current = suite
		requireSpec(spec)
		current = root
	end

	local results: Results = {
		Passed = 0,
		Failed = 0,
		Failures = {},
	}

	local function runSuite (suite: Suite)
		for _, test in suite.Tests do
			local path = pathOf(suite, test.Name)

			local ok, message

			for _, hook in hooksFor(suite, 'BeforeEach') do
				ok, message = callProtected(hook)

				if not ok then
					break
				end
			end

			if ok ~= false then
				ok, message = callProtected(test.Fn)
			end

			-- Teardown must run even when the test failed, and must not mask the failure.
			for _, hook in hooksFor(suite, 'AfterEach') do
				local teardownOk, teardownMessage = callProtected(hook)

				if not teardownOk and ok ~= false then
					ok, message = false, teardownMessage
				end
			end

			if ok then
				results.Passed += 1

				print(`  PASS  {path}`)
			else
				results.Failed += 1

				table.insert(results.Failures, { Path = path, Message = message or '(no message)' })

				print(`  FAIL  {path}`)
			end
		end

		for _, child in suite.Children do
			runSuite(child)
		end
	end

	print('Running Chief tests\n')

	runSuite(root)

	print(`\n{results.Passed} passed, {results.Failed} failed, {results.Passed + results.Failed} total`)

	if results.Failed > 0 then
		print('\nFailures:\n')

		for _, failure in results.Failures do
			print(`  {failure.Path}\n    {failure.Message}\n`)
		end
	end

	return results
end

--[[ TYPES ]]

--[=[
	A group of tests declared by `describe`, or the implicit root group.
]=]
export type Suite = {
	Name: string,
	Parent: Suite?,
	Tests: { { Name: string, Fn: () -> () } },
	Children: { Suite },
	BeforeEach: { () -> () },
	AfterEach: { () -> () },
}

--[=[
	The matchers returned by `expect`.
]=]
export type Expectation = {
	toBe: (expected: any) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	toContain: (expected: any) -> (),
	toThrow: (expected: string?) -> (),
}

--[=[
	The outcome of a run.
]=]
export type Results = {
	Passed: number,
	Failed: number,
	Failures: { { Path: string, Message: string } },
}

return Runner
