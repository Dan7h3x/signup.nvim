local M = {}

local defaults = {
  border = "solid",
  winblend = 10,
  max_width = 50,
  max_height = 20,
  wrap = true,
  
  -- Trigger settings
  trigger_chars = { "(", "," },
  hide_on_completion = true,

  -- Highlighting
  highlights = {
    active_parameter = {
      fg = "#89DCEB",
      bg = "#313244",
      bold = true,
    },
  },
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})
  
  -- Set up highlights
  vim.api.nvim_set_hl(0, "SignatureActiveParameter", config.highlights.active_parameter)
end

function M.get()
  return config
end

return M 