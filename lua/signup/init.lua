local api = vim.api

local M = {}

local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
  return setmetatable({
    win = nil,
    buf = nil,
    timer = nil,
    visible = false,
    current_signatures = nil,
    enabled = false,
    normal_mode_active = false,
    config = {
      silent = false,
      number = true,
      icons = {
        parameter = "",
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
    }
  }, SignatureHelp)
end

local function signature_index_comment(index)
  if #vim.bo.commentstring ~= 0 then
    return vim.bo.commentstring:format(index)
  else
    return '(' .. index .. ')'
  end
end

local function markdown_for_signature_list(signatures, config)
  local lines, labels = {}, {}
  local number = config.number and #signatures > 1
  for index, signature in ipairs(signatures) do
    table.insert(labels, #lines + 1)

    local suffix = number and (' ' .. signature_index_comment(index)) or ''

    table.insert(lines, string.format("```%s", vim.bo.filetype))
    table.insert(lines, string.format("%s %s%s", config.icons.method, signature.label, suffix))
    table.insert(lines, "```")

    -- if signature.parameters and #signature.parameters > 0 then
    --   table.insert(lines, "")
    --   table.insert(lines, string.format("%s Parameters:", config.icons.parameter))
    --   for _, param in ipairs(signature.parameters) do
    --     table.insert(lines, string.format("  • %s", param.label))
    --   end
    -- end

    if signature.documentation then
      table.insert(lines, "")
      table.insert(lines, string.format("%s Documentation:", config.icons.documentation))
      vim.list_extend(lines, vim.split(signature.documentation.value or signature.documentation, "\n"))
    end

    if index ~= #signatures then
      table.insert(lines, "---")
    end
  end
  return lines, labels
end

function SignatureHelp:create_float_window(contents)
  local max_width = math.min(self.config.max_width, vim.o.columns)
  local max_height = math.min(self.config.max_height, #contents)

  -- Calculate optimal position
  local cursor = api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local screen_line = vim.fn.screenpos(0, cursor_line, 1).row

  local row_offset = self.config.floating_window_above_cur_line and -max_height - 1 or 1
  if screen_line + row_offset < 1 then
    row_offset = 1  -- Show below if not enough space above
  end

  local win_config = {
    relative = "cursor",
    row = row_offset,
    col = 0,
    width = max_width,
    height = max_height,
    style = "minimal",
    border = self.config.border,
    zindex = 50,  -- Ensure it's above most other floating windows
  }

  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, win_config)
    api.nvim_win_set_buf(self.win, self.buf)
  else
    self.buf = api.nvim_create_buf(false, true)
    self.win = api.nvim_open_win(self.buf, false, win_config)
  end

  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, contents)
  api.nvim_buf_set_option(self.buf, "modifiable", false)
  api.nvim_win_set_option(self.win, "foldenable", false)
  api.nvim_win_set_option(self.win, "wrap", true)
  api.nvim_win_set_option(self.win, "winblend", self.config.winblend)

  self.visible = true
end

function SignatureHelp:hide()
  if self.visible then
    pcall(api.nvim_win_close, self.win, true)
    pcall(api.nvim_buf_delete, self.buf, { force = true })
    self.win = nil
    self.buf = nil
    self.visible = false
    self.current_signatures = nil
  end
end

function SignatureHelp:find_parameter_range(signature_str, parameter_label)
  -- Handle both string and table parameter labels
  if type(parameter_label) == "table" then
    return parameter_label[1], parameter_label[2]
  end

  -- Escape special pattern characters in parameter_label
  local escaped_label = vim.pesc(parameter_label)
  
  -- Look for the parameter with word boundaries
  local pattern = [[\b]] .. escaped_label .. [[\b]]
  local start_pos = signature_str:find(pattern)
  
  if not start_pos then
    -- Fallback: try finding exact match if word boundary search fails
    start_pos = signature_str:find(escaped_label)
  end
  
  if not start_pos then return nil, nil end
  
  local end_pos = start_pos + #parameter_label - 1
  return start_pos, end_pos
end

function SignatureHelp:extract_default_value(param_info)
  -- Check if parameter has documentation that might contain default value
  if not param_info.documentation then return nil end
  
  local doc = type(param_info.documentation) == "string" 
    and param_info.documentation 
    or param_info.documentation.value

  -- Look for common default value patterns
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

function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  -- Clear existing highlights
  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

  for index, signature in ipairs(signatures) do
    local parameter = signature.activeParameter or active_parameter
    if parameter and parameter >= 0 and signature.parameters and parameter < #signature.parameters then
      local param_info = signature.parameters[parameter + 1]
      local label = param_info.label
      
      -- Find the parameter range in the signature
      local start_pos, end_pos = self:find_parameter_range(signature.label, label)
      
      if start_pos and end_pos then
        -- Add active parameter highlight
        api.nvim_buf_add_highlight(
          self.buf, 
          -1, 
          "LspSignatureActiveParameter", 
          labels[index], 
          start_pos - 1,
          end_pos - 1
        )
        
        -- Extract and display default value if available
        local default_value = self:extract_default_value(param_info)
        if default_value then
          local default_text = string.format(" (default: %s)", default_value)
          local line = api.nvim_buf_get_lines(self.buf, labels[index], labels[index] + 1, false)[1]
          local new_line = line .. default_text
          
          -- Update the line with default value
          api.nvim_buf_set_lines(self.buf, labels[index], labels[index] + 1, false, {new_line})
          
          -- Highlight the default value
          local default_start = #line
          local default_end = #new_line
          api.nvim_buf_add_highlight(
            self.buf,
            -1,
            "SignatureHelpDefaultValue",
            labels[index],
            default_start,
            default_end
          )
        end
      end
    end
  end

  -- Add icon highlights
  self:highlight_icons()
end

function SignatureHelp:highlight_icons()
  local icon_highlights = {
    { self.config.icons.method,        "SignatureHelpMethod" },
    { self.config.icons.parameter,     "SignatureHelpParameter" },
    { self.config.icons.documentation, "SignatureHelpDocumentation" },
  }

  for _, icon_hl in ipairs(icon_highlights) do
    local icon, hl_group = unpack(icon_hl)
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

function SignatureHelp:display(result)
  if not result or not result.signatures or #result.signatures == 0 then
    self:hide()
    return
  end

  local markdown, labels = markdown_for_signature_list(result.signatures, self.config)

  if vim.deep_equal(result.signatures, self.current_signatures) then
    return
  end

  self.current_signatures = result.signatures

  if #markdown > 0 then
    self:create_float_window(markdown)
    api.nvim_buf_set_option(self.buf, "filetype", "markdown")
    self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
    self:apply_treesitter_highlighting()
  else
    self:hide()
  end
end

function SignatureHelp:apply_treesitter_highlighting()
  if not pcall(require, "nvim-treesitter") then
    return
  end

  require("nvim-treesitter.highlight").attach(self.buf, "markdown")
end

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
      -- Only notify if not silent and if there was actually no signature help
      if not self.config.silent and result then
        vim.notify("No signature help available", vim.log.levels.INFO)
      end
    end
  end)
end

function SignatureHelp:check_capability()
  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if client.server_capabilities.signatureHelpProvider then
      self.enabled = true
      return
    end
  end
  self.enabled = false
end

function SignatureHelp:toggle_normal_mode()
  self.normal_mode_active = not self.normal_mode_active
  if self.normal_mode_active then
    self:trigger()
  else
    self:hide()
  end
end

function SignatureHelp:setup_autocmds()
  local group = api.nvim_create_augroup("LspSignatureHelp", { clear = true })

  local function debounced_trigger()
    if self.timer then
      vim.fn.timer_stop(self.timer)
    end
    self.timer = vim.fn.timer_start(30, function()
      self:trigger()
    end)
  end

  api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
    group = group,
    callback = function()
      local cmp_visible = require("cmp").visible()
      if cmp_visible then
        self:hide()
      elseif vim.fn.pumvisible() == 0 then
        debounced_trigger()
      else
        self:hide()
      end
    end
  })

  api.nvim_create_autocmd({ "CursorMoved" }, {
    group = group,
    callback = function()
      if self.normal_mode_active then
        debounced_trigger()
      end
    end
  })

  api.nvim_create_autocmd({ "InsertLeave", "BufHidden", "BufLeave" }, {
    group = group,
    callback = function()
      self:hide()
      self.normal_mode_active = false
    end
  })

  api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function()
      vim.defer_fn(function()
        self:check_capability()
      end, 100)
    end
  })

  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if self.visible then
        self:apply_treesitter_highlighting()
        self:set_active_parameter_highlights(self.current_signatures.activeParameter, self.current_signatures, {})
      end
    end
  })
end

function M.setup(opts)
  opts = opts or {}
  local signature_help = SignatureHelp.new()
  
  -- Properly merge configs
  signature_help.config = vim.tbl_deep_extend("force", signature_help.config, opts)
  signature_help:setup_autocmds()

  local toggle_key = opts.toggle_key or "<C-k>"
  vim.keymap.set("n", toggle_key, function()
    signature_help:toggle_normal_mode()
  end, { noremap = true, silent = true, desc = "Toggle signature help in normal mode" })

  -- Setup highlighting
  if pcall(require, "nvim-treesitter") then
    require("nvim-treesitter").define_modules({
      signature_help_highlighting = {
        module_path = "signature_help.highlighting",
        is_supported = function(lang) return lang == "markdown" end,
      },
    })
  end

  -- Fix: Use signature_help.config instead of opts.config
  vim.api.nvim_set_hl(0, "LspSignatureActiveParameter", {
    fg = signature_help.config.active_parameter_colors.fg,
    bg = signature_help.config.active_parameter_colors.bg
  })

  -- Setup other highlights
  local colors = signature_help.config.colors
  vim.cmd(string.format([[
    highlight default SignatureHelpMethod guifg=%s
    highlight default SignatureHelpParameter guifg=%s
    highlight default SignatureHelpDocumentation guifg=%s
  ]], colors.method, colors.parameter, colors.documentation))

  -- Setup default value highlight
  vim.api.nvim_set_hl(0, "SignatureHelpDefaultValue", {
    fg = signature_help.config.colors.default_value,
    italic = true
  })

  if opts.override then
    vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, context, config)
      config = vim.tbl_deep_extend("force", signature_help.config, config or {})
      signature_help:display(result)
    end
  end
end

return M
