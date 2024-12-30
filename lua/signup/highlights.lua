-- highlights.lua
local M = {}

-- Setup highlight groups with proper fallbacks and inheritance
function M.setup_highlights(colors)
    local highlights = {
        SignatureHelpNormal = { link = "NormalFloat" },
        SignatureHelpBorder = { fg = colors.border },
        SignatureHelpHeader = { fg = colors.header, bold = true },
        SignatureHelpMethod = { fg = colors.method },
        SignatureHelpParameter = { fg = colors.parameter },
        SignatureHelpActiveParameter = {
            fg = colors.active_parameter_colors.fg,
            bg = colors.active_parameter_colors.bg,
            bold = colors.active_parameter_colors.bold,
        },
        SignatureHelpDocumentation = { fg = colors.documentation },
        SignatureHelpType = { fg = colors.type },
        SignatureHelpIndicator = { fg = colors.method },
        SignatureHelpIndicatorActive = { fg = colors.parameter, bold = true },
    }

    -- Apply highlights with error handling
    for group, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, group, opts)
    end
end

return M