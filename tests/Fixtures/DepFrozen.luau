--!strict

local Dependencies = require('../../packages/dependencies/src')

-- Frozen, so Dependencies cannot replace the marker field: injection must fail loudly.
return table.freeze({
	Leaf = Dependencies.use(script.Parent.DepLeaf),
})
