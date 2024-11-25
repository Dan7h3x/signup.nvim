local api = vim.api
local fn = vim.fn
local lsp = vim.lsp

local M = {}

---@class SignatureHelp
---@field win number|nil Window handle
---@field buf number|nil Buffer handle
---@field timer number|nil Timer handle
---@field visible boolean
---@field current_signatures table|nil
---@field enabled boolean
---@field normal_mode_active boolean
---@field config table
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

-- Single instance for memory efficiency
local signature_instance = nil

-- Debounce utility function
local function debounce(fn, ms)
  local timer = nil
  return function(...)
    if timer then
      vim.fn.timer_stop(timer)
    end
    local args = {...}
    timer = vim.fn.timer_start(ms, function()
      timer = nil
      fn(unpack(args))
    end)
  end
end

-- Safe string concatenation helper
local function safe_concat(...)
  local result = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "table" then
      table.insert(result, value.value or "")
    else
      table.insert(result, tostring(value))
    end
  end
  return table.concat(result)
end

-- Add this helper function at the top with other helpers
local function split_lines(str)
  if type(str) ~= "string" then return {} end
  local lines = {}
  for line in str:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

function SignatureHelp.new()
  local self = setmetatable({
    win = nil,
    buf = nil,
    timer = nil,
    visible = false,
    current_signatures = nil,
    enabled = true,
    normal_mode_active = false,
    config = {
      silent = false,
      number = true,
      icons = {
        parameter = "",
        method = "󰡱",
        documentation = "󱪙",
      },
      colors = {
        parameter = "#86e1fc",
        method = "#c099ff",
        documentation = "#4fd6be",
        default_value = "#888888",
      },
      active_parameter_colors = {
        bg = "#86e1fc",
        fg = "#1a1a1a",
      },
      border = "rounded",
      winblend = 10,
      auto_close = true,
      trigger_chars = { "(", "," },
      max_height = 10,
      max_width = 80,
      floating_window_above_cur_line = true,
      preview_parameters = true,
      debounce_time = 50,
      dock_mode = {
        enabled = false,
        position = "bottom",
        height = 3,
        padding = 1,
      },
      render_style = {
        separator = true,
        compact = false,
        align_icons = true,
      },
    }
  }, SignatureHelp)

  return self
end

function SignatureHelp:setup_trigger_chars()
  if not self.config.trigger_chars then return end
  
  local group = api.nvim_create_augroup("SignatureHelpTrigger", { clear = true })
  
  -- Optimized trigger detection
  local trigger_check = debounce(function()
    if not self.enabled or vim.api.nvim_get_mode().mode ~= "i" then return end
    
    local cursor = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local col = cursor[2]
    
    -- Check current and previous character
    local curr_char = line:sub(col, col)
    local prev_char = col > 0 and line:sub(col, col) or ""
    
    if vim.tbl_contains(self.config.trigger_chars, curr_char) or 
       vim.tbl_contains(self.config.trigger_chars, prev_char) then
      self:trigger()
    end
  end, self.config.debounce_time)

  api.nvim_create_autocmd({"InsertCharPre", "CursorMovedI"}, {
    group = group,
    callback = trigger_check,
  })
end

function SignatureHelp:trigger()
  if not self.enabled then return end

  local params = lsp.util.make_position_params()
  lsp.buf_request(0, "textDocument/signatureHelp", params, function(err, result, _, _)
    if err then
      if not self.config.silent then
        vim.notify("LSP Signature Help Error: " .. vim.inspect(err), vim.log.levels.ERROR)
      end
      self:hide()
      return
    end

    if result and result.signatures and #result.signatures > 0 then
      -- Safely wrap in schedule to avoid race conditions
      vim.schedule(function()
        self:display(result)
      end)
    else
      self:hide()
    end
  end)
end

function SignatureHelp:display(result)
  if not result or not result.signatures or #result.signatures == 0 then
    self:hide()
    return
  end

  -- Memory-efficient comparison
  local should_update = not self.current_signatures or
    not vim.deep_equal(result.signatures, self.current_signatures)

  if not should_update then return end

  local active_sig_idx = result.activeSignature or 0
  local active_param_idx = result.activeParameter or 
    (result.signatures[active_sig_idx + 1] and result.signatures[active_sig_idx + 1].activeParameter) or 
    0

  -- Create content
  local content = self:create_signature_content(
    result.signatures,
    active_sig_idx,
    active_param_idx
  )

  if #content > 0 then
    self:update_window(content, result.signatures, active_param_idx)
    self.current_signatures = result.signatures
  else
    self:hide()
  end
end

function SignatureHelp:create_signature_content(signatures, active_sig_idx, active_param_idx)
  local content = {}
  
  for idx, signature in ipairs(signatures) do
    if not signature then goto continue end

    local is_active = idx - 1 == active_sig_idx
    local prefix = is_active and "→ " or "  "

    -- Method signature - safely handle label
    local method_label = type(signature.label) == "table" and signature.label.value or signature.label
    table.insert(content, prefix .. self.config.icons.method .. " " .. tostring(method_label))

    -- Parameters
    if signature.parameters and #signature.parameters > 0 then
      for param_idx, param in ipairs(signature.parameters) do
        if not param then goto continue_param end
        
        local param_prefix = param_idx - 1 == active_param_idx and "→ " or "  "
        local param_label = type(param.label) == "table" and param.label.value or param.label
        
        -- Split parameter documentation into lines if it exists
        if param.documentation then
          local doc = type(param.documentation) == "table" 
            and param.documentation.value 
            or tostring(param.documentation)
          
          table.insert(content, param_prefix .. self.config.icons.parameter .. " " .. tostring(param_label))
          for _, line in ipairs(split_lines(doc)) do
            table.insert(content, "    " .. line)
          end
        else
          table.insert(content, param_prefix .. self.config.icons.parameter .. " " .. tostring(param_label))
        end
        
        ::continue_param::
      end
    end

    -- Documentation
    if signature.documentation then
      local doc = type(signature.documentation) == "table" 
        and signature.documentation.value 
        or tostring(signature.documentation)
      
      table.insert(content, "  " .. self.config.icons.documentation .. " Documentation:")
      for _, line in ipairs(split_lines(doc)) do
        table.insert(content, "    " .. line)
      end
    end

    ::continue::
  end

  return content
end

function SignatureHelp:update_window(content, signatures, active_param_idx)
  local bufnr = self.buf
  local winnr = self.win

  -- Create or update buffer
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    bufnr = api.nvim_create_buf(false, true)
    self.buf = bufnr
    
    -- Set buffer options
    api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
    api.nvim_buf_set_option(bufnr, "swapfile", false)
  end

  -- Safely update content
  api.nvim_buf_set_option(bufnr, "modifiable", true)
  pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, content)
  api.nvim_buf_set_option(bufnr, "modifiable", false)

  -- Create or update window
  if not winnr or not api.nvim_win_is_valid(winnr) then
    local win_config = self:get_window_config(#content)
    winnr = api.nvim_open_win(bufnr, false, win_config)
    self.win = winnr

    -- Set window options
    api.nvim_win_set_option(winnr, "wrap", true)
    api.nvim_win_set_option(winnr, "winblend", self.config.winblend)
    api.nvim_win_set_option(winnr, "foldenable", false)
    api.nvim_win_set_option(winnr, "signcolumn", "no")
    api.nvim_win_set_option(winnr, "number", false)
    api.nvim_win_set_option(winnr, "relativenumber", false)
  end

  -- Apply highlights
  self:apply_highlights(signatures, active_param_idx)
  self.visible = true
end

function SignatureHelp:get_window_config(content_height)
  local max_height = math.min(self.config.max_height, content_height)
  local max_width = self.config.max_width

  -- Calculate position
  local cursor = api.nvim_win_get_cursor(0)
  local row_offset = self.config.floating_window_above_cur_line and -max_height - 1 or 1

  -- Safe window configuration
  return {
    relative = "cursor",
    row = row_offset,
    col = 0,
    width = max_width,
    height = max_height,
    style = "minimal",
    border = self.config.border,
    zindex = 50,
  }
end

function SignatureHelp:hide()
  if self.visible then
    if self.win and api.nvim_win_is_valid(self.win) then
      api.nvim_win_close(self.win, true)
      self.win = nil
    end
    if self.buf and api.nvim_buf_is_valid(self.buf) then
      api.nvim_buf_delete(self.buf, { force = true })
      self.buf = nil
    end
    self.visible = false
    self.current_signatures = nil
  end
end

function SignatureHelp:apply_highlights(signatures, active_param_idx)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  -- Clear existing highlights
  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

  -- Apply icon highlights
  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    -- Method icon highlight
    local method_start = line:find(vim.pesc(self.config.icons.method))
    if method_start then
      api.nvim_buf_add_highlight(self.buf, -1, "SignatureHelpMethod", i-1, method_start-1, method_start-1 + #self.config.icons.method)
    end

    -- Parameter icon highlight
    local param_start = line:find(vim.pesc(self.config.icons.parameter))
    if param_start then
      api.nvim_buf_add_highlight(self.buf, -1, "SignatureHelpParameter", i-1, param_start-1, param_start-1 + #self.config.icons.parameter)
    end

    -- Documentation icon highlight
    local doc_start = line:find(vim.pesc(self.config.icons.documentation))
    if doc_start then
      api.nvim_buf_add_highlight(self.buf, -1, "SignatureHelpDocumentation", i-1, doc_start-1, doc_start-1 + #self.config.icons.documentation)
    end
  end
end

function M.setup(opts)
  if not signature_instance then
    signature_instance = SignatureHelp.new()
  end
  
  signature_instance.config = vim.tbl_deep_extend("force", signature_instance.config, opts or {})
  signature_instance:setup_trigger_chars()

  -- Setup LSP handler
  if opts.override then
    lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx)
      if err then return end
      signature_instance:display(result)
    end
  end
end

return M
