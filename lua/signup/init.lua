local api = vim.api

local M = {}

local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
  local instance = setmetatable({
    win = nil,
    buf = nil,
    dock_win = nil,
    dock_buf = nil,
    dock_win_id = "signature_help_dock_" .. vim.api.nvim_get_current_buf(),
    timer = nil,
    visible = false,
    current_signatures = nil,
    enabled = false,
    normal_mode_active = false,
    current_signature_idx = nil,
    config = nil,
  }, SignatureHelp)

  instance._default_config = {
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
    dock_toggle_key = "<Leader>sd",
    toggle_key = "<C-k>",
    dock_mode = {
      enabled = false,
      position = "bottom",
      height = 3,
      padding = 1,
    },
    render_style = {
      separator = true,
      compact = true,
      align_icons = true,
    },
  }

  return instance
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
        or " "

    -- Method signature with syntax highlighting
    table.insert(lines, string.format("```%s", vim.bo.filetype))
    -- table.insert(lines, string.format("%s Method:", config.icons.method))
    table.insert(lines, string.format("%s %s%s%s",
      config.icons.method,
      signature.label,
      padding,
      suffix
    ))
    table.insert(lines, "```")

    -- Parameters section
    -- if signature.parameters and #signature.parameters > 0 then
    --   if config.render_style.separator then
    --     table.insert(lines, string.rep("─", 40))
    --   end
    --   table.insert(lines, string.format("%s Parameters:", config.icons.parameter))
    --   for _, param in ipairs(signature.parameters) do
    --     local param_doc = param.documentation and
    --         string.format(" - %s", param.documentation.value or param.documentation) or ""
    --     table.insert(lines, string.format("  • %s = %s", param.label, param_doc))
    --   end
    -- end

    -- Documentation section
    if signature.documentation then
      if config.render_style.separator then
        table.insert(lines, string.rep("-", 40))
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
    row_offset = 2 -- Show below if not enough space above
  end

  local win_config = {
    relative = "cursor",
    row = row_offset - 1,
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
    -- Store current window and buffer
    local current_win = api.nvim_get_current_win()
    local current_buf = api.nvim_get_current_buf()

    -- Close appropriate window based on mode
    if self.config.dock_mode.enabled then
      self:close_dock_window()
    else
      if self.win and api.nvim_win_is_valid(self.win) then
        pcall(api.nvim_win_close, self.win, true)
      end
      if self.buf and api.nvim_buf_is_valid(self.buf) then
        pcall(api.nvim_buf_delete, self.buf, { force = true })
      end
      self.win = nil
      self.buf = nil
    end

    self.visible = false

    -- Restore focus
    pcall(api.nvim_set_current_win, current_win)
    pcall(api.nvim_set_current_buf, current_buf)
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

  -- Iterate over signatures to highlight the active parameter
  for index, signature in ipairs(signatures) do
    local parameter = signature.activeParameter or active_parameter
    if parameter and parameter >= 0 and parameter < #signature.parameters then
      local label = signature.parameters[parameter + 1].label
      if type(label) == "string" then
        -- Parse the signature string to find the exact range of the active parameter
        local signature_str = signature.label
        local start_pos, end_pos = self:find_parameter_range(signature_str, label)
        if start_pos and end_pos then
          api.nvim_buf_add_highlight(self.buf, -1, "LspSignatureActiveParameter", labels[index], start_pos,
            end_pos)
        end
      elseif type(label) == "table" then
        local start_pos, end_pos = unpack(label)
        api.nvim_buf_add_highlight(self.buf, -1, "LspSignatureActiveParameter", labels[index], start_pos + 5, end_pos + 5)
      end
    end
  end

  -- Add icon highlights
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
        api.nvim_buf_add_highlight(self.buf, -1, hl_group, line_num, start_col - 1, start_col + #icon - 1)
      end
      line_num = line_num + 1
    end
  end
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

  -- Store current window and buffer
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_get_current_buf()

  -- Prevent duplicate displays of identical content
  if self.current_signatures and vim.deep_equal(result.signatures, self.current_signatures) and
      result.activeParameter == self.current_active_parameter then
    return
  end

  local markdown, labels = markdown_for_signature_list(result.signatures, self.config)
  self.current_signatures = result.signatures
  self.current_active_parameter = result.activeParameter

  if #markdown > 0 then
    if self.config.dock_mode.enabled then
      local win, buf = self:create_dock_window()
      if win and buf then
        api.nvim_buf_set_option(buf, "modifiable", true)
        api.nvim_buf_set_lines(buf, 0, -1, false, markdown)
        api.nvim_buf_set_option(buf, "modifiable", false)
        self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
        self:apply_treesitter_highlighting()
      end
    else
      self:create_float_window(markdown)
      api.nvim_buf_set_option(self.buf, "filetype", "markdown")
      self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
      self:apply_treesitter_highlighting()
    end
  else
    self:hide()
  end

  -- Restore focus to original window and buffer
  api.nvim_set_current_win(current_win)
  api.nvim_set_current_buf(current_buf)
end

function SignatureHelp:apply_treesitter_highlighting()
  local buf = self.config.dock_mode.enabled and self.dock_buf or self.buf
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end

  if not pcall(require, "nvim-treesitter") then
    return
  end

  -- Store current window and buffer
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_get_current_buf()

  -- Apply treesitter highlighting
  pcall(function()
    require("nvim-treesitter.highlight").attach(buf, "markdown")
  end)

  -- Restore focus
  api.nvim_set_current_win(current_win)
  api.nvim_set_current_buf(current_buf)
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

function SignatureHelp:create_dock_window()
  -- Store current window and buffer
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_get_current_buf()

  -- Update dock window ID for current buffer
  self.dock_win_id = "signature_help_dock_" .. current_buf

  if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
    -- Create dock buffer if needed
    if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
      self.dock_buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_option(self.dock_buf, "buftype", "nofile")
      api.nvim_buf_set_option(self.dock_buf, "bufhidden", "hide")
      api.nvim_buf_set_option(self.dock_buf, "modifiable", false)
      api.nvim_buf_set_option(self.dock_buf, "filetype", "markdown")

      -- Set buffer name with ID for easier tracking
      api.nvim_buf_set_name(self.dock_buf, self.dock_win_id)
    end

    -- Calculate dock position and dimensions
    local win_height = api.nvim_win_get_height(current_win)
    local win_width = api.nvim_win_get_width(current_win)
    local dock_height = math.min(self.config.dock_mode.height, math.floor(win_height * 0.3))
    local padding = self.config.dock_mode.padding
    local dock_width = win_width - (padding * 2)

    local row = self.config.dock_mode.position == "bottom"
        and win_height - dock_height - padding
        or padding

    -- Create dock window with enhanced config
    self.dock_win = api.nvim_open_win(self.dock_buf, false, {
      relative = "win",
      win = current_win,
      width = dock_width,
      height = dock_height,
      row = row,
      col = padding,
      style = "minimal",
      border = self.config.border,
      zindex = 45,
      focusable = false, -- Make window non-focusable to prevent focus issues
    })

    -- Apply window options
    local win_opts = {
      wrap = true,
      winblend = self.config.winblend,
      foldenable = false,
      cursorline = false,
      winhighlight = "Normal:SignatureHelpDock,FloatBorder:SignatureHelpBorder",
      signcolumn = "no",
    }

    for opt, value in pairs(win_opts) do
      api.nvim_win_set_option(self.dock_win, opt, value)
    end

    -- Set up dock window keymaps
    local dock_buf_keymaps = {
      ["q"] = function() self:hide() end,
      ["<Esc>"] = function() self:hide() end,
      ["<C-c>"] = function() self:hide() end,
      ["<C-n>"] = function() self:next_signature() end,
      ["<C-p>"] = function() self:prev_signature() end,
    }

    for key, func in pairs(dock_buf_keymaps) do
      vim.keymap.set("n", key, func, { buffer = self.dock_buf, silent = true, nowait = true })
    end

    -- Set window ID as a window variable
    api.nvim_win_set_var(self.dock_win, "signature_help_id", self.dock_win_id)
  end

  -- Ensure focus returns to original window
  api.nvim_set_current_win(current_win)

  return self.dock_win, self.dock_buf
end

function SignatureHelp:close_dock_window()
  -- Fast check for existing dock window
  if not self.dock_win_id then return end

  -- Try to find window by ID
  local wins = api.nvim_list_wins()
  for _, win in ipairs(wins) do
    local ok, win_id = pcall(api.nvim_win_get_var, win, "signature_help_id")
    if ok and win_id == self.dock_win_id then
      pcall(api.nvim_win_close, win, true)
      break
    end
  end

  -- Clean up buffer
  if self.dock_buf and api.nvim_buf_is_valid(self.dock_buf) then
    pcall(api.nvim_buf_delete, self.dock_buf, { force = true })
  end

  -- Reset dock window state
  self.dock_win = nil
  self.dock_buf = nil
end

-- Add navigation between multiple signatures
function SignatureHelp:next_signature()
  if not self.current_signatures then return end
  self.current_signature_idx = (self.current_signature_idx or 0) + 1
  if self.current_signature_idx > #self.current_signatures then
    self.current_signature_idx = 1
  end
  self:display({
    signatures = self.current_signatures,
    activeParameter = self.current_active_parameter,
    activeSignature = self.current_signature_idx - 1
  })
end

function SignatureHelp:prev_signature()
  if not self.current_signatures then return end
  self.current_signature_idx = (self.current_signature_idx or 1) - 1
  if self.current_signature_idx < 1 then
    self.current_signature_idx = #self.current_signatures
  end
  self:display({
    signatures = self.current_signatures,
    activeParameter = self.current_active_parameter,
    activeSignature = self.current_signature_idx - 1
  })
end

function SignatureHelp:toggle_dock_mode()
  -- Store current window and buffer
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_get_current_buf()

  -- Store current signatures
  local current_sigs = self.current_signatures
  local current_active = self.current_active_parameter

  -- Close existing windows efficiently
  if self.config.dock_mode.enabled then
    self:close_dock_window()
  else
    if self.win and api.nvim_win_is_valid(self.win) then
      pcall(api.nvim_win_close, self.win, true)
      pcall(api.nvim_buf_delete, self.buf, { force = true })
      self.win = nil
      self.buf = nil
    end
  end

  -- Toggle mode
  self.config.dock_mode.enabled = not self.config.dock_mode.enabled

  -- Redisplay if we had signatures
  if current_sigs then
    self:display({
      signatures = current_sigs,
      activeParameter = current_active
    })
  end

  -- Restore focus
  pcall(api.nvim_set_current_win, current_win)
  pcall(api.nvim_set_current_buf, current_buf)
end

function SignatureHelp:setup_keymaps()
  -- Setup toggle keys using the actual config
  local toggle_key = self.config.toggle_key
  local dock_toggle_key = self.config.dock_toggle_key

  if toggle_key then
    vim.keymap.set("n", toggle_key, function()
      self:toggle_normal_mode()
    end, { noremap = true, silent = true, desc = "Toggle signature help in normal mode" })
  end

  if dock_toggle_key then
    vim.keymap.set("n", dock_toggle_key, function()
      self:toggle_dock_mode()
    end, { noremap = true, silent = true, desc = "Toggle between dock and float mode" })
  end
end

function M.setup(opts)
  -- Ensure setup is called only once
  if M._initialized then
    return M._instance
  end

  opts = opts or {}
  local signature_help = SignatureHelp.new()

  -- Deep merge user config with defaults
  signature_help.config = vim.tbl_deep_extend("force",
    signature_help._default_config,
    opts
  )

  -- Setup highlights with user config
  local function setup_highlights()
    local colors = signature_help.config.colors
    local highlights = {
      SignatureHelpDock = { link = "NormalFloat" },
      SignatureHelpBorder = { link = "FloatBorder" },
      SignatureHelpMethod = { fg = colors.method },
      SignatureHelpParameter = { fg = colors.parameter },
      SignatureHelpDocumentation = { fg = colors.documentation },
      SignatureHelpDefaultValue = { fg = colors.default_value, italic = true },
      LspSignatureActiveParameter = {
        fg = signature_help.config.active_parameter_colors.fg,
        bg = signature_help.config.active_parameter_colors.bg,
      },
    }

    for group, hl_opts in pairs(highlights) do
      vim.api.nvim_set_hl(0, group, hl_opts)
    end
  end

  -- Setup highlights and ensure they persist across colorscheme changes
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LspSignatureColors", { clear = true }),
    callback = setup_highlights,
  })

  -- Setup autocmds and keymaps
  signature_help:setup_autocmds()
  signature_help:setup_keymaps()

  -- Store instance for potential reuse
  M._initialized = true
  M._instance = signature_help

  return signature_help
end

-- Add version and metadata for lazy.nvim compatibility
M.version = "1.0.0"
M.dependencies = {
  "nvim-treesitter/nvim-treesitter",
}

-- Add API methods for external use
M.toggle_dock = function()
  if M._instance then
    M._instance:toggle_dock_mode()
  end
end

M.toggle_normal_mode = function()
  if M._instance then
    M._instance:toggle_normal_mode()
  end
end

return M
