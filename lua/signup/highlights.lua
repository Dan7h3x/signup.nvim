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
        SignatureHelpIcon = { fg = colors.signature, bold = true },
        SignatureHelpParamIcon = { fg = colors.parameter, bold = true },
        SignatureHelpDocIcon = { fg = colors.documentation, bold = true },
        SignatureHelpSeparator = { fg = colors.signature, bold = true },
    }

    for group, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, group, opts)
    end
end

-- Get highlight group attributes
function M.get_hl_attributes(name)
    local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
    if not ok then return {} end
    return hl
end

-- Create highlight group with fallback
function M.create_highlight(name, opts, fallback)
    local hl = opts
    if vim.tbl_isempty(hl) and fallback then
        hl = M.get_hl_attributes(fallback)
    end
    vim.api.nvim_set_hl(0, name, hl)
end

return M