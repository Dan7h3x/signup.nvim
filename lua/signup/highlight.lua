local api = vim.api
local M = {}

---@param config SignupConfig
function M.setup_highlights(config)
  -- Main parameter highlight
  api.nvim_set_hl(0, "LspSignatureActiveParameter", config.highlights.active_parameter)
  
  -- Active signature line
  api.nvim_set_hl(0, "LspSignatureActiveLine", {
    bg = config.highlights.active_parameter.bg,
    blend = 30,
  })
  
  -- Parameter hint highlight
  api.nvim_set_hl(0, "LspSignatureParameterHint", config.highlights.parameter_hints)
  
  -- Method highlight
  api.nvim_set_hl(0, "LspSignatureMethod", {
    fg = config.colors.method,
    bold = true,
  })
  
  -- Documentation highlight
  api.nvim_set_hl(0, "LspSignatureDoc", {
    fg = config.colors.documentation,
    italic = true,
  })
end

---@param config SignupConfig
function M.create_autocmds(config)
  local group = api.nvim_create_augroup("SignupHighlights", { clear = true })
  
  -- Update highlights when colorscheme changes
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.setup_highlights(config)
    end,
  })
end

---@param bufnr number
---@param ns number
---@param line number
---@param start_col number
---@param end_col number
---@param hl_group string
function M.safe_add_highlight(bufnr, ns, line, start_col, end_col, hl_group)
  pcall(api.nvim_buf_add_highlight, bufnr, ns, hl_group, line, start_col, end_col)
end

return M 