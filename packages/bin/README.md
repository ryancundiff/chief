# chief/bin

A small, strictly typed cleanup container for [Chief](https://github.com/ryancundiff/Chief) — and for anything else.

A Bin holds connections, instances, threads, and functions. Emptying it disconnects, destroys, cancels, and calls them, in reverse insertion order, so teardown unwinds setup. The Traits extension attaches one to every bound object as `self.Bin`.

## Installation

```sh
pesde add chief/bin
```

## Usage

```luau
--!strict

local Bin = require('path/to/bin')

local bin = Bin.new()

-- Add returns the item, so adds can wrap assignments.
local connection = bin:Add(part.Touched:Connect(onTouched)) :: RBXScriptConnection

bin:Add(Instance.new('Folder'))
bin:Add(task.spawn(function ()
	while true do
		task.wait(1)
	end
end))
bin:Add(function ()
	print('emptied')
end)

-- Disconnects, destroys, cancels, and calls -- newest first. The Bin stays usable.
bin:Empty()
```

## API

- `Bin.new(): Bin` — create an empty Bin.
- `Bin:Add(item: BinItem): BinItem` — add a connection, instance, thread, or function; returns the item. Throws `BadArgument` for anything else.
- `Bin:Empty()` — clean up every item in reverse insertion order and clear the Bin. The Bin remains usable afterward.

## License

MIT