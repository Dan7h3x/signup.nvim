-- highlights.lua
local M = {}

function M.setup_highlights(colors)
    local highlights = {
        SignatureHelpNormal = { link = "NormalFloat" },
        SignatureHelpBorder = { link = "FloatBorder" },
        SignatureHelpActiveParameter = colors.active_parameter,
        SignatureHelpSignature = { fg = colors.signature },
        SignatureHelpParameter = { fg = colors.parameter },
        SignatureHelpDocumentation = { fg = colors.documentation },
        SignatureHelpDock = { link = "NormalFloat" },
    }

    for group, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, group, opts)
    end
end

return M