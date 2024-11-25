local api = vim.api

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

---Creates a new SignatureHelp instance
---@return SignatureHelp
function SignatureHelp.new()
  return setmetatable({
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
        parameter = "T",
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
      border = "solid",
      winblend = 10,
      auto_close = true,
      trigger_chars = { "(", "," },
      max_height = 10,
      max_width = 40,
      floating_window_above_cur_line = true,
      preview_parameters = true,
      debounce_time = 30,
      dock_mode = {
        enabled = false,
        position = "bottom", -- "bottom" | "top"
        height = 3,         -- number of lines
        padding = 1,        -- padding from edges
      },
      render_style = {
        separator = true,   -- Show separators between sections
        compact = false,    -- Compact mode removes empty lines
        align_icons = true, -- Align icons in separate column
      },
    }
  }, SignatureHelp)
end

---Safely extracts parameter information from signature data
---@param param table Parameter information from LSP
---@return table Processed parameter information
local function process_parameter(param)
  if not param or type(param) ~= "table" then
    return {
      label = "",
      documentation = "",
      type = nil
    }
  end

  local param_info = {
    label = type(param.label) == "string" and param.label or "",
    documentation = "",
    type = nil
  }

  -- Handle documentation
  if param.documentation then
    param_info.documentation = type(param.documentation) == "string"
      and param.documentation
      or (type(param.documentation) == "table" and param.documentation.value or "")
  end

  -- Extract type information if available
  if param_info.label ~= "" then
    param_info.type = param_info.label:match(":%s*(.+)$")
  end

  return param_info
end

---Parses signature information from LSP response
---@param signature table|nil The signature information from LSP
---@return table Processed signature information
function SignatureHelp:parse_signature_info(signature)
  if not signature or type(signature) ~= "table" or not signature.label then
    return {
      name = "unknown",
      full_signature = "",
      documentation = "",
      parameters = {}
    }
  end

  -- Extract function name and parameters
  local function_name = signature.label:match("([^%(]+)") or "unknown"
  local parameters = signature.parameters or {}
  
  -- Process parameters
  local parsed_params = {}
  for i, param in ipairs(parameters) do
    parsed_params[i] = process_parameter(param)
  end
  
  -- Process documentation
  local documentation = ""
  if signature.documentation then
    documentation = type(signature.documentation) == "string"
      and signature.documentation
      or (type(signature.documentation) == "table" and signature.documentation.value or "")
  end

  return {
    name = function_name,
    full_signature = signature.label,
    documentation = documentation,
    parameters = parsed_params,
  }
end

---Safely finds the range of a parameter in a signature string
---@param signature_str string The full signature string
---@param param_info table Parameter information
---@return number|nil, number|nil Start and end positions
function SignatureHelp:find_parameter_range(signature_str, param_info)
  if not signature_str or not param_info or not param_info.label then
    return nil, nil
  end

  -- Extract parameter name without type annotation
  local param_name = param_info.label:match("^([^:]+)")
  if not param_name then
    return nil, nil
  end

  -- Escape special pattern characters
  local escaped_name = vim.pesc(param_name)
  
  -- Try to find the parameter with word boundaries
  local start_pos = signature_str:find([[\b]] .. escaped_name .. [[\b]])
  
  -- Fallback to exact match if word boundary search fails
  if not start_pos then
    start_pos = signature_str:find(escaped_name)
  end

  if not start_pos then
    return nil, nil
  end

  return start_pos, start_pos + #param_name - 1
end

---Creates markdown content for signature list
---@param signatures table[] List of signatures from LSP
---@param active_sig_idx number Index of active signature
---@param active_param_idx number Index of active parameter
---@param config table Configuration options
---@return table, table Lines and label positions
local function markdown_for_signature_list(signatures, active_sig_idx, active_param_idx, config)
  if not signatures or type(signatures) ~= "table" then
    return {}, {}
  end

  local lines, labels = {}, {}
  local max_method_len = 0

  -- Calculate max method length for alignment
  if config.render_style.align_icons then
    for _, sig in ipairs(signatures) do
      if sig and sig.label then
        max_method_len = math.max(max_method_len, #sig.label)
      end
    end
  end

  for index, signature in ipairs(signatures) do
    if not signature then goto continue end

    local parsed = SignatureHelp:parse_signature_info(signature)
    local is_active = index - 1 == active_sig_idx
    
    -- Add spacing between signatures
    if not config.render_style.compact then
      table.insert(lines, "")
    end
    table.insert(labels, #lines + 1)

    -- Method section
    local method_prefix = is_active and "→" or " "
    table.insert(lines, string.format("%s %s Method:", method_prefix, config.icons.method))
    
    -- Signature with syntax highlighting
    if parsed.full_signature ~= "" then
      table.insert(lines, string.format("```%s", vim.bo.filetype))
      table.insert(lines, parsed.full_signature)
      table.insert(lines, "```")
    end

    -- Parameters section
    if #parsed.parameters > 0 then
      if config.render_style.separator then
        table.insert(lines, string.rep("─", 40))
      end
      table.insert(lines, string.format("%s Parameters:", config.icons.parameter))
      
      for param_idx, param in ipairs(parsed.parameters) do
        if not param then goto continue_param end

        local is_active_param = is_active and param_idx - 1 == active_param_idx
        local param_prefix = is_active_param and "→" or " "
        local param_text = string.format("%s %s", param_prefix, param.label or "")
        
        -- Add documentation if available
        if param.documentation and param.documentation ~= "" then
          param_text = param_text .. string.format(" - %s", param.documentation)
        end
        
        -- Add default value if available
        local default_value = SignatureHelp:extract_default_value(param)
        if default_value then
          param_text = param_text .. string.format(" (default: %s)", default_value)
        end
        
        table.insert(lines, "  " .. param_text)
        ::continue_param::
      end
    end

    -- Documentation section
    if parsed.documentation and parsed.documentation ~= "" then
      if config.render_style.separator then
        table.insert(lines, string.rep("─", 40))
      end
      table.insert(lines, string.format("%s Documentation:", config.icons.documentation))
      for _, line in ipairs(vim.split(parsed.documentation, "\n")) do
        table.insert(lines, "  " .. line)
      end
    end

    -- Add separator between signatures
    if index ~= #signatures and config.render_style.separator then
      table.insert(lines, string.rep("═", 40))
    end

    ::continue::
  end
  
  return lines, labels
end

---Extracts default value from parameter documentation
---@param param_info table Parameter information
---@return string|nil Default value if found
function SignatureHelp:extract_default_value(param_info)
  if not param_info or not param_info.documentation then
    return nil
  end

  local doc = type(param_info.documentation) == "string"
    and param_info.documentation
    or param_info.documentation.value

  if not doc then return nil end

  -- Common patterns for default values
  local patterns = {
    "default:%s*([^%s]+)",
    "defaults%s+to%s+([^%s]+)",
    "%(default:%s*([^%)]+)%)",
  }

  for _, pattern in ipairs(patterns) do
    local default = doc:match(pattern)
    if default then return default end
  end

  return nil
end

---Sets highlights for active parameter and icons
---@param active_param_idx number Index of active parameter
---@param signatures table[] List of signatures
---@param labels table Label positions
function SignatureHelp:set_active_parameter_highlights(active_param_idx, signatures, labels)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  -- Clear existing highlights
  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

  for index, signature in ipairs(signatures) do
    if not signature then goto continue end

    local parsed = self:parse_signature_info(signature)
    local parameter = signature.activeParameter or active_param_idx
    
    if parameter and parameter >= 0 and parsed.parameters and parameter < #parsed.parameters then
      local param_info = parsed.parameters[parameter + 1]
      if not param_info then goto continue end

      -- Find parameter range in signature
      local start_pos, end_pos = self:find_parameter_range(signature.label, param_info)
      
      if start_pos and end_pos then
        -- Add active parameter highlight
        api.nvim_buf_add_highlight(
          self.buf,
          -1,
          "LspSignatureActiveParameter",
          labels[index] + 2, -- Account for method header and code block start
          start_pos - 1,
          end_pos
        )
      end
    end

    ::continue::
  end

  -- Add icon highlights
  self:highlight_icons()
end

---Creates or updates the floating window
---@param contents string[] Lines to display
function SignatureHelp:create_float_window(contents)
  local max_width = math.min(self.config.max_width, vim.o.columns)
  local max_height = math.min(self.config.max_height, #contents)

  -- Calculate optimal position
  local cursor = api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local screen_line = vim.fn.screenpos(0, cursor_line, 1).row

  local row_offset = self.config.floating_window_above_cur_line and -max_height - 1 or 1
  if screen_line + row_offset < 1 then
    row_offset = 1 -- Show below if not enough space above
  end

  local win_config = {
    relative = "cursor",
    row = row_offset,
    col = 0,
    width = max_width,
    height = max_height,
    style = "minimal",
    border = self.config.border,
    zindex = 50,
  }

  -- Create or update window
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, win_config)
    api.nvim_win_set_buf(self.win, self.buf)
  else
    self.buf = api.nvim_create_buf(false, true)
    self.win = api.nvim_open_win(self.buf, false, win_config)
  end

  -- Set buffer content and options
  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, contents)
  api.nvim_buf_set_option(self.buf, "modifiable", false)
  api.nvim_buf_set_option(self.buf, "filetype", "markdown")
  api.nvim_win_set_option(self.win, "foldenable", false)
  api.nvim_win_set_option(self.win, "wrap", true)
  api.nvim_win_set_option(self.win, "winblend", self.config.winblend)

  self.visible = true
end

---Creates or updates the dock window
---@return number, number Window and buffer handles
function SignatureHelp:create_dock_window()
  -- Create or get dock buffer
  if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
    self.dock_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(self.dock_buf, "buftype", "nofile")
    api.nvim_buf_set_option(self.dock_buf, "bufhidden", "hide")
  end

  -- Calculate dock dimensions
  local win_height = vim.api.nvim_win_get_height(0)
  local win_width = vim.api.nvim_win_get_width(0)
  local dock_height = self.config.dock_mode.height
  local padding = self.config.dock_mode.padding

  local row = self.config.dock_mode.position == "bottom"
    and win_height - dock_height - padding
    or padding

  -- Create or update dock window
  if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
    self.dock_win = api.nvim_open_win(self.dock_buf, false, {
      relative = "win",
      win = 0,
      width = win_width - (padding * 2),
      height = dock_height,
      row = row,
      col = padding,
      style = "minimal",
      border = self.config.border,
      zindex = 45,
    })

    -- Set window options
    api.nvim_win_set_option(self.dock_win, "wrap", true)
    api.nvim_win_set_option(self.dock_win, "winblend", self.config.winblend)
    api.nvim_win_set_option(self.dock_win, "foldenable", false)
  end

  return self.dock_win, self.dock_buf
end

---Displays signature help information
---@param result table LSP signature help result
function SignatureHelp:display(result)
  if not result or not result.signatures or #result.signatures == 0 then
    self:hide()
    return
  end

  -- Prevent duplicate displays
  if vim.deep_equal(result.signatures, self.current_signatures) then
    return
  end

  local active_sig_idx = result.activeSignature or 0
  local active_param_idx = result.activeParameter or 
    (result.signatures[active_sig_idx + 1] and result.signatures[active_sig_idx + 1].activeParameter) or 
    0

  local markdown, labels = markdown_for_signature_list(
    result.signatures, 
    active_sig_idx,
    active_param_idx,
    self.config
  )
  
  self.current_signatures = result.signatures

  if #markdown > 0 then
    if self.config.dock_mode.enabled then
      local win, buf = self:create_dock_window()
      api.nvim_buf_set_option(buf, "modifiable", true)
      api.nvim_buf_set_lines(buf, 0, -1, false, markdown)
      api.nvim_buf_set_option(buf, "modifiable", false)
      api.nvim_buf_set_option(buf, "filetype", "markdown")
      self:set_active_parameter_highlights(active_param_idx, result.signatures, labels)
      self:apply_treesitter_highlighting()
    else
      self:create_float_window(markdown)
      self:set_active_parameter_highlights(active_param_idx, result.signatures, labels)
      self:apply_treesitter_highlighting()
    end
  else
    self:hide()
  end
end

---Hides the signature help window
function SignatureHelp:hide()
  if self.visible then
    if not self.config.dock_mode.enabled then
      pcall(api.nvim_win_close, self.win, true)
      pcall(api.nvim_buf_delete, self.buf, { force = true })
      self.win = nil
      self.buf = nil
    end
    self.visible = false
    self.current_signatures = nil
  end
end

---Setup autocommands for signature help
function SignatureHelp:setup_autocmds()
  local group = api.nvim_create_augroup("SignatureHelp", { clear = true })

  -- Auto-close signature help when cursor moves
  if self.config.auto_close then
    api.nvim_create_autocmd("CursorMoved", {
      group = group,
      callback = function()
        if self.visible and not self.config.dock_mode.enabled then
          self:hide()
        end
      end,
    })
  end

  -- Handle window resize for dock mode
  if self.config.dock_mode.enabled then
    api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if self.visible then
          self:refresh_dock_window()
        end
      end,
    })
  end

  -- Cleanup on buffer unload
  api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function()
      self:hide()
    end,
  })
end

---Refresh the dock window after resize
function SignatureHelp:refresh_dock_window()
  if not self.config.dock_mode.enabled or not self.visible then return end
  
  local win_height = vim.api.nvim_win_get_height(0)
  local win_width = vim.api.nvim_win_get_width(0)
  local dock_height = self.config.dock_mode.height
  local padding = self.config.dock_mode.padding

  local row = self.config.dock_mode.position == "bottom"
    and win_height - dock_height - padding
    or padding

  if self.dock_win and api.nvim_win_is_valid(self.dock_win) then
    api.nvim_win_set_config(self.dock_win, {
      relative = "win",
      win = 0,
      width = win_width - (padding * 2),
      height = dock_height,
      row = row,
      col = padding,
    })
  end
end

---Toggle signature help in normal mode
function SignatureHelp:toggle_normal_mode()
  self.normal_mode_active = not self.normal_mode_active
  if self.normal_mode_active then
    self:trigger()
  else
    self:hide()
  end
end

---Trigger signature help request
function SignatureHelp:trigger()
  if not self.enabled then return end

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(0, "textDocument/signatureHelp", params, function(err, result, _, _)
    if err then
      if not self.config.silent then
        vim.notify("Error in LSP Signature Help: " .. vim.inspect(err), vim.log.levels.ERROR)
      end
      self:hide()
      return
    end

    if result and result.signatures and #result.signatures > 0 then
      self:display(result)
    else
      self:hide()
      if not self.config.silent and result then
        vim.notify("No signature help available", vim.log.levels.INFO)
      end
    end
  end)
end

---Apply treesitter highlighting if available
function SignatureHelp:apply_treesitter_highlighting()
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end
  
  -- Check if treesitter is available
  local has_ts, ts = pcall(require, "nvim-treesitter.highlight")
  if not has_ts then return end

  -- Apply treesitter highlighting
  ts.attach(self.buf, vim.bo.filetype)
end

---Highlight icons in the signature help window
function SignatureHelp:highlight_icons()
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  local icons = {
    { self.config.icons.method, "SignatureHelpMethod" },
    { self.config.icons.parameter, "SignatureHelpParameter" },
    { self.config.icons.documentation, "SignatureHelpDocumentation" },
  }

  for _, icon_data in ipairs(icons) do
    local icon, hl_group = unpack(icon_data)
    local line_num = 0
    
    while line_num < api.nvim_buf_line_count(self.buf) do
      local line = api.nvim_buf_get_lines(self.buf, line_num, line_num + 1, false)[1]
      local start_col = line:find(vim.pesc(icon))
      
      if start_col then
        api.nvim_buf_add_highlight(
          self.buf,
          -1,
          hl_group,
          line_num,
          start_col - 1,
          start_col - 1 + #icon
        )
      end
      
      line_num = line_num + 1
    end
  end
end

---Setup function for the plugin
---@param opts table Configuration options
function M.setup(opts)
  opts = opts or {}
  local signature_help = SignatureHelp.new()
  
  -- Merge configs
  signature_help.config = vim.tbl_deep_extend("force", signature_help.config, opts)
  
  -- Setup autocommands
  signature_help:setup_autocmds()

  -- Setup keymaps
  local toggle_key = opts.toggle_key or "<C-k>"
  vim.keymap.set("n", toggle_key, function()
    signature_help:toggle_normal_mode()
  end, { noremap = true, silent = true, desc = "Toggle signature help in normal mode" })

  -- Setup highlights
  vim.api.nvim_set_hl(0, "LspSignatureActiveParameter", {
    fg = signature_help.config.active_parameter_colors.fg,
    bg = signature_help.config.active_parameter_colors.bg
  })

  local colors = signature_help.config.colors
  vim.api.nvim_set_hl(0, "SignatureHelpMethod", { fg = colors.method })
  vim.api.nvim_set_hl(0, "SignatureHelpParameter", { fg = colors.parameter })
  vim.api.nvim_set_hl(0, "SignatureHelpDocumentation", { fg = colors.documentation })
  vim.api.nvim_set_hl(0, "SignatureHelpDefaultValue", { 
    fg = colors.default_value,
    italic = true 
  })

  -- Override LSP handler if requested
  if opts.override then
    vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, context, config)
      config = vim.tbl_deep_extend("force", signature_help.config, config or {})
      signature_help:display(result)
    end
  end
end

return M
