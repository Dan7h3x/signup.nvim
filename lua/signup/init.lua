local api = vim.api
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

-- Utility functions
local utils = {
  safe_tostring = function(value)
    if type(value) == "table" then
      return value.value or ""
    end
    return tostring(value or "")
  end,

  split_lines = function(str)
    if type(str) ~= "string" then return {} end
    local lines = {}
    for line in str:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end
    return lines
  end,

  extract_param_name = function(param)
    if not param then return nil end
    local label = type(param.label) == "table" and param.label.value or param.label
    if not label then return nil end
    
    local name = tostring(label):match("^([%w_]+)[:%s]") or
                 tostring(label):match("^([%w_]+)$") or
                 tostring(label):match("%(([%w_]+)%)")
    return name
  end,

  debounce = function(fn, ms)
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
}

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
      border = "rounded",
      winblend = 10,
      auto_close = true,
      trigger_chars = { "(", "," },
      max_height = 10,
      max_width = 80,
      floating_window_above_cur_line = true,
      debounce_time = 50,
      icons = {
        parameter = "",
        method = "󰡱",
        documentation = "󱪙",
      },
      colors = {
        parameter = "#86e1fc",
        method = "#c099ff",
        documentation = "#4fd6be",
      },
      active_parameter_colors = {
        bg = "#86e1fc",
        fg = "#1a1a1a",
      },
    }
  }, SignatureHelp)

  return self
end

function SignatureHelp:setup_trigger_chars()
  if not self.config.trigger_chars then return end
  
  local group = api.nvim_create_augroup("SignatureHelpTrigger", { clear = true })
  
  local trigger_check = utils.debounce(function()
    if not self.enabled or vim.api.nvim_get_mode().mode ~= "i" then return end
    
    local cursor = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local col = cursor[2]
    
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

function SignatureHelp:create_signature_content(signatures, active_sig_idx, active_param_idx)
  local content = {}
  
  for idx, signature in ipairs(signatures) do
    if not signature then goto continue end

    local is_active = idx - 1 == active_sig_idx
    local prefix = is_active and "→ " or "  "

    -- Method signature
    local method_label = utils.safe_tostring(signature.label)
    table.insert(content, prefix .. self.config.icons.method .. " " .. method_label)

    -- Parameters
    if signature.parameters and #signature.parameters > 0 then
      for param_idx, param in ipairs(signature.parameters) do
        if not param then goto continue_param end
        
        local param_prefix = param_idx - 1 == active_param_idx and "→ " or "  "
        local param_label = utils.safe_tostring(param.label)
        
        -- Parameter with documentation
        if param.documentation then
          local doc = utils.safe_tostring(param.documentation)
          table.insert(content, param_prefix .. self.config.icons.parameter .. " " .. param_label)
          
          -- Split documentation into lines
          for _, line in ipairs(utils.split_lines(doc)) do
            if line:match("%S") then
              table.insert(content, "    " .. line)
            end
          end
        else
          table.insert(content, param_prefix .. self.config.icons.parameter .. " " .. param_label)
        end
        
        ::continue_param::
      end
    end

    -- Documentation
    if signature.documentation then
      local doc = utils.safe_tostring(signature.documentation)
      if doc:match("%S") then
        table.insert(content, "  " .. self.config.icons.documentation .. " Documentation:")
        for _, line in ipairs(utils.split_lines(doc)) do
          if line:match("%S") then
            table.insert(content, "    " .. line)
          end
        end
      end
    end

    ::continue::
  end

  return content
end

function SignatureHelp:get_window_config(content_height)
  local max_height = math.min(self.config.max_height, content_height)
  local row_offset = self.config.floating_window_above_cur_line and -max_height - 1 or 1

  return {
    relative = "cursor",
    row = row_offset,
    col = 0,
    width = self.config.max_width,
    height = max_height,
    style = "minimal",
    border = self.config.border,
    zindex = 50,
  }
end

function SignatureHelp:update_window(content)
  -- Create or update buffer
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then
    self.buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(self.buf, "buftype", "nofile")
    api.nvim_buf_set_option(self.buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(self.buf, "swapfile", false)
  end

  -- Update content
  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, content)
  api.nvim_buf_set_option(self.buf, "modifiable", false)

  -- Create or update window
  if not self.win or not api.nvim_win_is_valid(self.win) then
    self.win = api.nvim_open_win(self.buf, false, self:get_window_config(#content))
    
    -- Set window options
    api.nvim_win_set_option(self.win, "wrap", true)
    api.nvim_win_set_option(self.win, "winblend", self.config.winblend)
    api.nvim_win_set_option(self.win, "foldenable", false)
    api.nvim_win_set_option(self.win, "signcolumn", "no")
    api.nvim_win_set_option(self.win, "number", false)
    api.nvim_win_set_option(self.win, "relativenumber", false)
  end

  self.visible = true
end

function SignatureHelp:set_active_parameter_highlights(signatures, active_param_idx)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  -- Clear existing highlights
  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    -- Highlight icons
    local icon_highlights = {
      { self.config.icons.method, "SignatureHelpMethod" },
      { self.config.icons.parameter, "SignatureHelpParameter" },
      { self.config.icons.documentation, "SignatureHelpDocumentation" },
    }

    for _, icon_data in ipairs(icon_highlights) do
      local icon, hl_group = unpack(icon_data)
      local icon_start = line:find(vim.pesc(icon))
      if icon_start then
        api.nvim_buf_add_highlight(
          self.buf, 
          -1, 
          hl_group, 
          i-1, 
          icon_start-1, 
          icon_start-1 + #icon
        )
      end
    end

    -- Highlight active parameter
    if signatures and active_param_idx then
      for _, signature in ipairs(signatures) do
        if signature.parameters and signature.parameters[active_param_idx + 1] then
          local param = signature.parameters[active_param_idx + 1]
          local param_name = utils.extract_param_name(param)
          
          if param_name then
            local start_idx = 1
            while true do
              local param_start = line:find(vim.pesc(param_name), start_idx, true)
              if not param_start then break end
              
              local param_end = param_start + #param_name - 1
              local prev_char = param_start > 1 and line:sub(param_start - 1, param_start - 1) or " "
              local next_char = line:sub(param_end + 1, param_end + 1)
              
              if (prev_char:match("[^%w_]") or prev_char == "") and
                 (next_char:match("[^%w_]") or next_char == "") then
                api.nvim_buf_add_highlight(
                  self.buf,
                  -1,
                  "LspSignatureActiveParameter",
                  i-1,
                  param_start-1,
                  param_end
                )
              end
              
              start_idx = param_end + 1
            end
          end
        end
      end
    end
  end
end

function SignatureHelp:trigger()
  if not self.enabled then return end

  local params = lsp.util.make_position_params()
  lsp.buf_request(0, "textDocument/signatureHelp", params, function(err, result, _, _)
    if err then
      if not self.config.silent then
        vim.notify("LSP Signature Help Error", vim.log.levels.ERROR)
      end
      self:hide()
      return
    end

    if result and result.signatures and #result.signatures > 0 then
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

  if vim.deep_equal(result.signatures, self.current_signatures) then
    return
  end

  local active_sig_idx = result.activeSignature or 0
  local active_param_idx = result.activeParameter or 
    (result.signatures[active_sig_idx + 1] and result.signatures[active_sig_idx + 1].activeParameter) or 
    0

  local content = self:create_signature_content(
    result.signatures,
    active_sig_idx,
    active_param_idx
  )

  if #content > 0 then
    self:update_window(content)
    vim.schedule(function()
      self:set_active_parameter_highlights(result.signatures, active_param_idx)
    end)
    self.current_signatures = result.signatures
  else
    self:hide()
  end
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

-- Single instance for memory efficiency
local signature_instance = nil

function M.setup(opts)
  if not signature_instance then
    signature_instance = SignatureHelp.new()
  end
  
  signature_instance.config = vim.tbl_deep_extend("force", signature_instance.config, opts or {})
  signature_instance:setup_trigger_chars()

  -- Setup highlights
  vim.api.nvim_set_hl(0, "LspSignatureActiveParameter", {
    fg = signature_instance.config.active_parameter_colors.fg,
    bg = signature_instance.config.active_parameter_colors.bg,
  })

  local colors = signature_instance.config.colors
  vim.api.nvim_set_hl(0, "SignatureHelpMethod", { fg = colors.method })
  vim.api.nvim_set_hl(0, "SignatureHelpParameter", { fg = colors.parameter })
  vim.api.nvim_set_hl(0, "SignatureHelpDocumentation", { fg = colors.documentation })

  -- Override LSP handler
  if opts.override then
    lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx)
      if err then return end
      signature_instance:display(result)
    end
  end

  -- Setup LSP attach handler
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function()
      signature_instance.enabled = true
    end,
  })
end

return M
