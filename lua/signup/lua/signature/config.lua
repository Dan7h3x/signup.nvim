local M = {}

local defaults = {
  border_chars = {
    { "╭", "FloatBorder" },
    { "─", "FloatBorder" },
    { "╮", "FloatBorder" },
    { "│", "FloatBorder" },
    { "╯", "FloatBorder" },
    { "─", "FloatBorder" },
    { "╰", "FloatBorder" },
    { "│", "FloatBorder" },
  },
  winblend = 10,
  max_width = 30,
  max_height = 15,
  wrap = true,
  
  -- Trigger settings
  trigger_chars = { "(", "," },
  hide_on_completion = true,

  -- Highlighting
  highlights = {
    signature = {
      fg = "#7dcfff",
      bold = true,
    },
    active_parameter = {
      fg = "#89DCEB",
      bg = "#313244",
      bold = true,
    },
    parameter = {
      fg = "#bb9af7",
    },
    documentation = {
      fg = "#9ece6a",
    },
    signature_function = { fg = "#7dcfff", bold = true },
    signature_parameter = { fg = "#bb9af7" },
    signature_active_parameter = { fg = "#89DCEB", bg = "#313244", bold = true },
    signature_delimiter = { fg = "#565f89" },
    signature_parameter_doc = { fg = "#9ece6a" },
    signature_doc = { fg = "#7aa2f7" },
  },
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})
  
  -- Set up highlights
  for name, hl in pairs(config.highlights) do
    vim.api.nvim_set_hl(0, "Signature" .. name:gsub("^%l", string.upper), hl)
  end
end

function M.get()
  return config
end

return M 