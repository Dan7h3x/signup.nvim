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
        default_value = "#a80888",
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
        height = 3,          -- number of lines
        padding = 1,         -- padding from edges
      },
      render_style = {
        separator = true,   -- Show separators between sections
        compact = true,    -- Compact mode removes empty lines
        align_icons = true, -- Align icons in separate column
      },
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
  local max_method_len = 0

  -- First pass to calculate alignment
  if config.render_style.align_icons then
    for _, signature in ipairs(signatures) do
      max_method_len = math.max(max_method_len, #signature.label)
    end
  end

  for index, signature in ipairs(signatures) do
    if not config.render_style.compact then
      table.insert(lines, "")
    end
    table.insert(labels, #lines + 1)

    local suffix = number and (' ' .. signature_index_comment(index)) or ''
    local padding = config.render_style.align_icons
        and string.rep(" ", max_method_len - #signature.label)
        or ""

    -- Method signature with syntax highlighting
    table.insert(lines, string.format("```%s", vim.bo.filetype))
    table.insert(lines, string.format("%s Method: %s%s%s",
      config.icons.method,
      signature.label,
      padding,
      suffix
    ))
    table.insert(lines, "```")

    -- Parameters section
    if signature.parameters and #signature.parameters > 0 then
      if config.render_style.separator then
        table.insert(lines, string.rep("─", 40))
      end
      table.insert(lines, string.format("%s Parameters:", config.icons.parameter))
      for _, param in ipairs(signature.parameters) do
        local param_doc = param.documentation and
            string.format(" - %s", param.documentation.value or param.documentation) or ""
        table.insert(lines, string.format("  • %s = %s", param.label, param_doc))
      end
    end

    -- Documentation section
    if signature.documentation then
      if config.render_style.separator then
        table.insert(lines, string.rep("─", 40))
      end
      table.insert(lines, string.format("%s Documentation:", config.icons.documentation))
      local doc_lines = vim.split(
        signature.documentation.value or signature.documentation,
        "\n"
      )
      for _, line in ipairs(doc_lines) do
        table.insert(lines, "  " .. line)
      end
    end

    if index ~= #signatures and config.render_style.separator then
      table.insert(lines, string.rep("═", 40))
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
    row_offset = 1 -- Show below if not enough space above
  end

  local win_config = {
    relative = "cursor",
    row = row_offset + 1,
    col = 0,
    width = max_width,
    height = max_height,
    style = "minimal",
    border = self.config.border,
    zindex = 50, -- Ensure it's above most other floating windows
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
          start_pos +1,
          end_pos +1
        )

        -- Extract and display default value if available
        local default_value = self:extract_default_value(param_info)
        if default_value then
          local default_text = string.format(" (default: %s)", default_value)
          local line = api.nvim_buf_get_lines(self.buf, labels[index], labels[index] + 1, false)[1]
          local new_line = line .. default_text

          -- Update the line with default value
          api.nvim_buf_set_lines(self.buf, labels[index], labels[index] + 1, false, { new_line })

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

  -- Prevent duplicate displays
  if vim.deep_equal(result.signatures, self.current_signatures) then
    return
  end

  local markdown, labels = markdown_for_signature_list(result.signatures, self.config)
  self.current_signatures = result.signatures

  if #markdown > 0 then
    if self.config.dock_mode.enabled then
      local win, buf = self:create_dock_window()
      api.nvim_buf_set_option(buf, "modifiable", true)
      api.nvim_buf_set_lines(buf, 0, -1, false, markdown)
      api.nvim_buf_set_option(buf, "modifiable", false)
      api.nvim_buf_set_option(buf, "filetype", "markdown")
      self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
      self:apply_treesitter_highlighting()
    else
      self:create_float_window(markdown)
      api.nvim_buf_set_option(self.buf, "filetype", "markdown")
      self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
      self:apply_treesitter_highlighting()
    end
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

function SignatureHelp:setup_autocmds(bufnr, callbacks)
    local group = vim.api.nvim_create_augroup('YourPlugin', { clear = true })
    
    local events = {
        {'InsertEnter', callbacks.on_insert_enter},
        {'InsertLeave', callbacks.on_insert_leave},
        {'BufLeave,BufWinLeave', callbacks.on_buf_leave},
        {'CursorMoved,CursorMovedI', debounced_update(callbacks.on_cursor_move, 100)},
    }
    
    for _, event in ipairs(events) do
        vim.api.nvim_create_autocmd(event[1], {
            group = group,
            buffer = bufnr,
            callback = event[2],
        })
    end
end

function SignatureHelp:create_dock_window()
  if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
    -- Create dock buffer if needed
    if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
      self.dock_buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_option(self.dock_buf, "buftype", "nofile")
      api.nvim_buf_set_option(self.dock_buf, "bufhidden", "hide")
    end

    -- Calculate dock position
    local win_height = vim.api.nvim_win_get_height(0)
    local win_width = vim.api.nvim_win_get_width(0)
    local dock_height = self.config.dock_mode.height
    local padding = self.config.dock_mode.padding

    local row = self.config.dock_mode.position == "bottom"
        and win_height - dock_height - padding
        or padding

    -- Create dock window
    self.dock_win = api.nvim_open_win(self.dock_buf, false, {
      relative = "win",
      win = 0,
      width = win_width - (padding * 2),
      height = dock_height,
      row = row,
      col = padding,
      style = "minimal",
      border = self.config.border,
      zindex = 45, -- Below floating windows but above normal content
    })

    -- Set window options
    api.nvim_win_set_option(self.dock_win, "wrap", true)
    api.nvim_win_set_option(self.dock_win, "winblend", self.config.winblend)
    api.nvim_win_set_option(self.dock_win, "foldenable", false)
  end

  return self.dock_win, self.dock_buf
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

local function create_floating_window(contents, opts)
    opts = opts or {}
    local width = opts.width or 50
    local height = opts.height or 10
    
    -- Calculate position
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]
    
    -- Create buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, true, contents)
    
    -- Window options
    local win_opts = {
        relative = 'cursor',
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = 'minimal',
        border = self.config.border,
    }
    
    -- Create window
    local win = vim.api.nvim_open_win(buf, false, win_opts)
    
    return buf, win
end

-- Centralize state management
local state = {
    windows = {},
    buffers = {},
    cleanup_timer = nil,
}

-- Update cleanup function to use centralized state
local function cleanup(force)
    if state.cleanup_timer then
        state.cleanup_timer:stop()
        state.cleanup_timer = nil
    end
    
    -- Clear virtual text
    vim.api.nvim_buf_clear_namespace(0, ns.virtual_text, 0, -1)
    
    -- Close all floating windows
    for win, _ in pairs(state.windows) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    
    -- Clear state
    if force then
        state.windows = {}
        state.buffers = {}
    end
end

-- Consolidate namespace creation
local ns = {
    virtual_text = vim.api.nvim_create_namespace('signup'),
}

-- Update show_virtual_hint to use consolidated namespace
local function show_virtual_hint(hint, offset)
    local line = vim.api.nvim_win_get_cursor(0)[1] - 1
    
    -- Clear existing virtual text
    vim.api.nvim_buf_clear_namespace(0, ns.virtual_text, 0, -1)
    
    if hint and hint ~= '' then
        vim.api.nvim_buf_set_extmark(0, ns.virtual_text, line, 0, {
            virt_text = {{ hint, 'YourHintHighlight' }},
            virt_text_pos = 'eol',
        })
    end
end

local default_config = {
    enabled = true,
    virtual_text = true,
    floating_window = true,
    max_height = 12,
    max_width = 40,
    wrap = true,
    border = self.config.border,
    hint_prefix = '🔍 ',
}

local function setup(user_config)
    local config = vim.tbl_deep_extend('force', default_config, user_config or {})
    return config
end

-- Add debounced window updates
local function debounced_update(fn, ms)
    local timer = nil
    return function(...)
        local args = {...}
        if timer then
            timer:stop()
            timer = nil
        end
        
        timer = vim.defer_fn(function()
            if timer then
                fn(unpack(args))
                timer = nil
            end
        end, ms or 100)
    end
end

-- Use debounced updates for virtual hints
local update_virtual_hint = debounced_update(show_virtual_hint, 50)

return M
