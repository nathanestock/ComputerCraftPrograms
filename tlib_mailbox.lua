-- Legacy compatibility shim for older startup/aliases.
local nlib = require("nlib")

local args = { ... }
if #args > 0 and type(nlib.cli) == "function" then
	nlib.cli(args)
end

return nlib
