local api = vim.api
local lsp = vim.lsp
local fn = vim.fn

---@class SignatureConfig
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow" Border style
---@field max_width number Maximum window width
---@field max_height number Maximum window height
---@field win_opts table Window options
---@field trigger_chars string[] Characters that trigger signature help
---@field debounce_ms number Debounce time in milliseconds
---@field icons table<string, string> Icons for different parts
---@field hl_groups table<string, table> Highlight groups
---@field auto_close table<string, boolean> Auto-close functionality
---@field render table<string, boolean> Render options
local DEFAULT_CONFIG = {
  border = "solid",
  max_width = 40,
  max_height = 20,
  win_opts = {
    winblend = 10,
    wrap = true,
    foldenable = false,
    signcolumn = "no",
    number = false,
    cursorline = false,
  },
  trigger_chars = { "(", "," },
  debounce_ms = 10,
  icons = {
    parameter = "󰘦 ",
    method = "󰡱 ",
    info = " ",
  },
  hl_groups = {
    parameter = { fg = "#89DCEB" },
    method = { fg = "#F5C2E7" },
    info = { fg = "#94E2D5" },
    active_parameter = {
      fg = "#1E1E2E",
      bg = "#89DCEB",
      bold = true,
    },
    default_value = { fg = "#7C7F93", italic = true },
    parameter_separator = { fg = "#6E738D" },
    parameter_count = { fg = "#9399B2", italic = true },
  },
  auto_close = {
    normal_mode = true,
    insert_mode = false,
    cursor_moved_delay = 100,
  },
  render = {
    show_default_value = true,
    parameter_separator = ", ",
    max_parameter_width = 30,
    align_parameters = true,
    show_parameter_count = true,
  },
}

---@class SignatureHelper
---@field private win number? Window handle
---@field private buf number? Buffer handle
---@field private timer number? Debounce timer
---@field private config SignatureConfig Configuration
---@field private current_sig table? Current signature data
local SignatureHelper = {}
SignatureHelper.__index = SignatureHelper

-- Utility functions
local utils = {
  ---@param str string?
  ---@return string[]
  split_lines = function(str)
    if not str or type(str) ~= "string" then return {} end
    return vim.split(str, "\n", { trimempty = true })
  end,

  ---@param value any
  ---@return string
  safe_str = function(value)
    if type(value) == "table" then
      return value.value or ""
    end
    return tostring(value or "")
  end,

  ---@param param table LSP parameter object
  ---@return string?, string? name and default value
  parse_parameter = function(param)
    if not param or not param.label then return nil, nil end
    local label = utils.safe_str(param.label)
    
    -- Try to extract name and default value
    local patterns = {
      "^([%w_]+)%s*=%s*(.+)$",     -- name = default_value
      "^([%w_]+):%s*[%w_]+%s*=%s*(.+)$", -- name: type = default_value
      "^([%w_]+)[:%s]",            -- name: type or name
      "^([%w_]+)$",                -- name
      "%(([%w_]+)%)",              -- (name)
      "<([%w_]+)>",                -- <name>
    }
    
    for _, pattern in ipairs(patterns) do
      local name, default = label:match(pattern)
      if name then
        return name, default
      end
    end
    return nil, nil
  end,

  truncate = function(str, max_len)
    if #str > max_len then
      return str:sub(1, max_len - 3) .. "..."
    end
    return str
  end,
}

---Create a new signature helper instance
---@param config? table
---@return SignatureHelper
function SignatureHelper.new(config)
  local self = setmetatable({
    win = nil,
    buf = nil,
    timer = nil,
    config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, config or {}),
    current_sig = nil,
  }, SignatureHelper)
  
  self:setup_highlights()
  return self
end

---Setup highlight groups
function SignatureHelper:setup_highlights()
  for name, opts in pairs(self.config.hl_groups) do
    vim.api.nvim_set_hl(0, "SignatureHelp" .. name:gsub("^%l", string.upper), opts)
  end
end

---Format signature information into displayable content
---@param signature table LSP signature information
---@param active_param number? Active parameter index
---@return string[] lines
function SignatureHelper:format_signature(signature, active_param)
  local lines = {}
  
  -- Method signature with parameter count
  local method = utils.safe_str(signature.label)
  local param_count = signature.parameters and #signature.parameters or 0
  local count_suffix = self.config.render.show_parameter_count 
    and string.format(" (%d parameter%s)", param_count, param_count == 1 and "" or "s")
    or ""
  
  table.insert(lines, self.config.icons.method .. method .. count_suffix)
  
  -- Parameters
  if signature.parameters and #signature.parameters > 0 then
    local max_name_width = 0
    local params = {}
    
    -- First pass: collect parameter info and calculate max width
    for i, param in ipairs(signature.parameters) do
      if not param then goto continue end
      
      local name, default = utils.parse_parameter(param)
      if not name then goto continue end
      
      local param_info = {
        index = i,
        name = name,
        default = default,
        doc = param.documentation and utils.safe_str(param.documentation) or nil,
        is_active = i == (active_param or 0) + 1
      }
      
      max_name_width = math.max(max_name_width, #name)
      table.insert(params, param_info)
      
      ::continue::
    end
    
    -- Second pass: format parameters
    for _, param_info in ipairs(params) do
      local prefix = param_info.is_active and "→ " or "  "
      local name_padding = self.config.render.align_parameters 
        and string.rep(" ", max_name_width - #param_info.name) 
        or ""
      
      -- Parameter name and type
      local param_line = prefix .. self.config.icons.parameter .. 
        param_info.name .. name_padding
      
      -- Default value
      if self.config.render.show_default_value and param_info.default then
        param_line = param_line .. " = " .. 
          utils.truncate(param_info.default, self.config.render.max_parameter_width)
      end
      
      table.insert(lines, param_line)
      
      -- Parameter documentation
      if param_info.doc then
        local doc_lines = utils.split_lines(param_info.doc)
        for _, line in ipairs(doc_lines) do
          table.insert(lines, "    " .. line)
        end
      end
    end
  end
  
  -- Method documentation
  if signature.documentation then
    table.insert(lines, "")
    table.insert(lines, self.config.icons.info .. "Documentation:")
    local doc_lines = utils.split_lines(utils.safe_str(signature.documentation))
    for _, line in ipairs(doc_lines) do
      table.insert(lines, "  " .. line)
    end
  end
  
  return lines
end

---Create or update the floating window
---@param contents string[] Lines to display
function SignatureHelper:update_window(contents)
  -- Create buffer if needed
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then
    self.buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(self.buf, "buftype", "nofile")
    api.nvim_buf_set_option(self.buf, "bufhidden", "wipe")
  end
  
  -- Update content
  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, contents)
  api.nvim_buf_set_option(self.buf, "modifiable", false)
  
  -- Calculate window size and position
  local width = math.min(self.config.max_width, vim.o.columns)
  local height = math.min(self.config.max_height, #contents)
  
  local win_config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
    zindex = 50,
  }
  
  -- Create or update window
  if not self.win or not api.nvim_win_is_valid(self.win) then
    self.win = api.nvim_open_win(self.buf, false, win_config)
    
    -- Apply window options
    for opt, value in pairs(self.config.win_opts) do
      api.nvim_win_set_option(self.win, opt, value)
    end
  else
    api.nvim_win_set_config(self.win, win_config)
  end
end

---Apply highlights to the signature window
---@param signature table LSP signature information
---@param active_param number? Active parameter index
function SignatureHelper:apply_highlights()
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end
  
  -- Clear existing highlights
  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)
  
  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    -- Highlight icons
    for name, icon in pairs(self.config.icons) do
      local start = line:find(vim.pesc(icon))
      if start then
        api.nvim_buf_add_highlight(
          self.buf,
          -1,
          "SignatureHelp" .. name:gsub("^%l", string.upper),
          i - 1,
          start - 1,
          start - 1 + #icon
        )
      end
    end
    
    -- Highlight default values
    local default_start = line:find(" = ")
    if default_start then
      api.nvim_buf_add_highlight(
        self.buf,
        -1,
        "SignatureHelpDefaultValue",
        i - 1,
        default_start,
        -1
      )
    end
    
    -- Highlight parameter count
    local count_start = line:find(" %(%d+")
    if count_start then
      api.nvim_buf_add_highlight(
        self.buf,
        -1,
        "SignatureHelpParameterCount",
        i - 1,
        count_start,
        -1
      )
    end
    
    -- Highlight active parameter
    if line:find("^→ ") then
      api.nvim_buf_add_highlight(
        self.buf,
        -1,
        "SignatureHelpActiveParameter",
        i - 1,
        0,
        -1
      )
    end
  end
end

---Handle LSP signature help response
---@param result table? LSP signature help result
function SignatureHelper:display(result)
  if not result or not result.signatures or #result.signatures == 0 then
    self:hide()
    return
  end
  
  -- Get active signature and parameter
  local active_sig = result.activeSignature or 0
  local signature = result.signatures[active_sig + 1]
  if not signature then return end
  
  local active_param = result.activeParameter or signature.activeParameter or 0
  
  -- Format content
  local contents = self:format_signature(signature, active_param)
  if #contents == 0 then return end
  
  -- Update display
  self:update_window(contents)
  self:apply_highlights()
  
  self.current_sig = result
end

---Hide the signature window
function SignatureHelper:hide()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_close(self.win, true)
    self.win = nil
  end
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_delete(self.buf, { force = true })
    self.buf = nil
  end
  self.current_sig = nil
end

---Trigger signature help request
function SignatureHelper:trigger()
  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(0, "textDocument/signatureHelp", params, function(err, result, ctx)
    if err or not result then return end
    vim.schedule(function()
      self:display(result)
    end)
  end)
end

-- Module setup
local M = {}

---@type SignatureHelper?
local instance = nil

---Setup the signature helper
---@param opts? table
function M.setup(opts)
  instance = SignatureHelper.new(opts)
  instance:setup_auto_close()
  
  -- Setup autocommands
  local group = api.nvim_create_augroup("SignatureHelp", { clear = true })
  
  -- Trigger on insert mode events
  api.nvim_create_autocmd({"InsertCharPre", "CursorMovedI"}, {
    group = group,
    callback = function()
      if instance.timer then
        fn.timer_stop(instance.timer)
      end
      instance.timer = fn.timer_start(instance.config.debounce_ms, function()
        instance:trigger()
      end)
    end,
  })
  
  -- Cleanup on mode change
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      if instance then
        instance:hide()
      end
    end,
  })
  
  -- Override default LSP handler
  lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx)
    if err or not result or not instance then return end
    instance:display(result)
  end
end

return M
