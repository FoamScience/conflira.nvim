-- Default icon set for CSF concealing and UI
-- Users can override any of these via require("atlassian.icons").setup(overrides)
local M = {
    kind = {
        Reference = " ",
        File = " ",
    },
    ui = {
        Heading1 = "󰲡", Heading2 = "󰲣", Heading3 = "󰲥",
        Heading4 = "󰲧", Heading5 = "󰲩", Heading6 = "󰲫",
        Circle = " ",
        BoldLineLeft = "▎",
        BoxChecked = " ",
        Ellipsis = " ",
        LineMiddle = "│",
        LineBold = "┃",
        HorizontalRule = "━",
        Code = " ",
        Triangle = "󰐊 ",
        BookMark = " ",
        List = " ",
        Target = "󰀘 ",
        Table = " ",
        Pencil = "󰏫 ",
        MathBlock = "∑",
        MathInline = "∫",
    },
    diagnostics = {
        Information = " ",
        Warning = " ",
        Hint = "󰌶 ",
    },
    misc = {
        Smiley = " ",
    },
}

---@param overrides table|nil Icon overrides matching the structure of M
function M.setup(overrides)
    if overrides then
        for category, icons in pairs(overrides) do
            if type(icons) == "table" and M[category] then
                for key, value in pairs(icons) do
                    M[category][key] = value
                end
            end
        end
    end
end

return M
