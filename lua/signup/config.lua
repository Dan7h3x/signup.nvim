local M = {}

---@class SignupConfig
M.defaults = {
  -- General options
  silent = false,
  number = true,
  override = false,     -- Whether to override the default LSP signature handler
  toggle_key = "<C-k>", -- Key to toggle signature in normal mode

  -- Window options
  border = "rounded",
  winblend = 20,
  max_width = 50,
  max_height = 20,
  wrap = true,

  -- Icons used in the signature window
  icons = {
    parameter = " ",
    method = " ",
    documentation = " ",
  },

  -- Colors for different elements
  colors = {
    parameter = "#86e1fc",
    method = "#c099ff",
    documentation = "#4fd6be",
  },

  -- Highlight groups
  highlights = {
    active_parameter = {
      fg = "#89DCEB",    -- Parameter text color
      bg = "#313244",    -- Parameter background
      bold = true,       -- Make it bold
      italic = false,    -- Optional italic
      underline = false, -- Optional underline
    },
    active_signature = {
      fg = "#94E2D5", -- Active signature color
      bold = true,
    },
    parameter_hints = {
      fg = "#BAC2DE", -- Parameter hints color
      italic = true,
    }
  },

  -- Auto-open settings
  auto_open = {
    enabled = true,
    trigger_chars = { "(", "," },    -- Specific trigger characters
    hide_on_completion = true,       -- Hide when nvim-cmp is visible
    throttle = 50,                   -- Reduced throttle time for better responsiveness
  },

  -- Display options
  inline_hints = false, -- Show parameter hints inline (in addition to bottom docs)
}

---@type SignupConfig
M.options = {}

---@param opts? SignupConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M

