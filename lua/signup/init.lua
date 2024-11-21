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
        parameter = " ",
        method = " ",
        documentation = " ",
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
      border = "solid",
      winblend = 10,
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
  local width = math.min(45, vim.o.columns)
  local height = math.min(#contents, 10)

  local cursor = api.nvim_win_get_cursor(0)
  local row = cursor[1] - api.nvim_win_get_cursor(0)[1]

  local win_config = {
    relative = "cursor",
    row = row + 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
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

-- function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
--   if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end
--
--   api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)
--
--   for index, signature in ipairs(signatures) do
--     local parameter = signature.activeParameter or active_parameter
--     if parameter and parameter >= 0 and parameter < #signature.parameters then
--       local label = signature.parameters[parameter + 1].label
--       if type(label) == "string" then
--         -- vim.fn.matchadd("LspSignatureActiveParameter", "\\<" .. label .. "\\>")
--         vim.fn.matchadd("LspSignatureActiveParameter", "\\V\\<" .. vim.fn.escape(label, '\\') .. "\\>")
--       elseif type(label) == "table" then
--         -- api.nvim_buf_add_highlight(self.buf, -1, "LspSignatureActiveParameter", labels[index], unpack(label))
--         assert(self.buf and labels[index] and label[1] and label[2], "Invalid arguments")
--         api.nvim_buf_add_highlight(self.buf, -1, "LspSignatureActiveParameter", labels[index], unpack(label))
--       end
--     end
--   end
--
--   -- Add icon highlights
--   local icon_highlights = {
--     { self.config.icons.method,        "SignatureHelpMethod" },
--     { self.config.icons.parameter,     "SignatureHelpParameter" },
--     { self.config.icons.documentation, "SignatureHelpDocumentation" },
--   }
--
--   for _, icon_hl in ipairs(icon_highlights) do
--     local icon, hl_group = unpack(icon_hl)
--     local line_num = 0
--     while line_num < api.nvim_buf_line_count(self.buf) do
--       local line = api.nvim_buf_get_lines(self.buf, line_num, line_num + 1, false)[1]
--       local start_col = line:find(vim.pesc(icon))
--       if start_col then
--         api.nvim_buf_add_highlight(self.buf, -1, hl_group, line_num, start_col + 1, start_col + #icon + 1)
--       end
--       line_num = line_num + 1
--     end
--   end
-- end
function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

  for index, signature in ipairs(signatures) do
    local parameter = signature.activeParameter or active_parameter
    if parameter and parameter >= 0 and parameter < #signature.parameters then
      local label = signature.parameters[parameter + 1].label
      if type(label) == "string" then
        -- Parse the signature string to find the exact range of the active parameter
        local signature_str = signature.label
        local start_pos, end_pos = self:find_parameter_range(signature_str, label)
        if start_pos and end_pos then
          api.nvim_buf_add_highlight(self.buf, -1, "LspSignatureActiveParameter", labels[index], start_pos - 1,
            end_pos - 1)
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
        api.nvim_buf_add_highlight(self.buf, -1, hl_group, line_num, start_col, start_col + #icon)
      end
      line_num = line_num + 1
    end
  end
end

function SignatureHelp:find_parameter_range(signature_str, parameter_label)
  local start_pos = signature_str:find(parameter_label)
  if not start_pos then return nil, nil end

  local end_pos = start_pos + #parameter_label - 1

  -- Ensure the parameter label is not part of a larger word
  local before_char = signature_str:sub(start_pos - 1, start_pos - 1)
  local after_char = signature_str:sub(end_pos + 1, end_pos + 1)
  if (start_pos > 1 and not before_char:match("%s")) or (end_pos < #signature_str and not after_char:match("%s")) then
    return nil, nil
  end

  return start_pos - 1, end_pos
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

    if result then
      self:display(result)
    else
      self:hide()
      if not self.config.silent then
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
  signature_help.config = vim.tbl_deep_extend("force", signature_help.config, opts)
  signature_help:setup_autocmds()

  local toggle_key = opts.toggle_key or "<C-k>"
  vim.keymap.set("n", toggle_key, function()
    signature_help:toggle_normal_mode()
  end, { noremap = true, silent = true, desc = "Toggle signature help in normal mode" })

  if pcall(require, "nvim-treesitter") then
    require("nvim-treesitter").define_modules({
      signature_help_highlighting = {
        module_path = "signature_help.highlighting",
        is_supported = function(lang)
          return lang == "markdown"
        end,
      },
    })
  end
  vim.api.nvim_set_hl(0, "LspSignatureActiveParameter",
    { fg = opts.active_parameter_colors.fg, bg = opts.active_parameter_colors.bg })
  vim.cmd(string.format([[
        highlight default SignatureHelpMethod guifg=%s
        highlight default SignatureHelpParameter guifg=%s
        highlight default SignatureHelpDocumentation guifg=%s
    ]], signature_help.config.colors.method, signature_help.config.colors.parameter,
    signature_help.config.colors.documentation))

  if opts.override then
    vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, context, config)
      config = vim.tbl_deep_extend("force", signature_help.config, config or {})
      signature_help:display(result)
    end
  end
end

return M
