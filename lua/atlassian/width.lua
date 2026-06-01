-- Display-width seam.
--
-- The renderers need the terminal display width of a string (multi-byte/CJK
-- aware) for column alignment. That's the only non-data Neovim dependency left
-- inside the otherwise-pure `build_ir`. Routing it through here means a
-- non-Neovim host (e.g. a Go core driving the same build logic) can swap the
-- implementation without the render code referencing `vim.*` directly.
local M = {}

--- Implementation, overridable by a non-Neovim host. Defaults to Neovim's.
---@type fun(s: string): number
M.impl = function(s)
	return vim.fn.strdisplaywidth(s)
end

--- Display width of a string.
---@param s string
---@return number
function M.display_width(s)
	return M.impl(s or "")
end

return M
