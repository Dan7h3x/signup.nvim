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
      border = "rounded",
      winblend = 20,
    },
    _ns = vim.api.nvim_create_namespace('signature_help'),
    _highlight_cache = {},
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

    if signature.parameters and #signature.parameters > 0 then
      table.insert(lines, "")
      table.insert(lines, string.format("%s Parameters:", config.icons.parameter))
      for _, param in ipairs(signature.parameters) do
        table.insert(lines, string.format("  • %s", param.label))
      end
    end

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

function SignatureHelp:create_float_window(contents, signature)
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

  -- Add enhanced parameter documentation
  if signature and signature.activeParameter then
    local param = signature.parameters[signature.activeParameter + 1]
    if param and param.documentation then
      -- Get parameter label
      local param_label = ""
      if type(param.label) == "string" then
        param_label = param.label
      elseif type(param.label) == "table" and #param.label == 2 then
        -- Extract substring from signature label using start/end positions
        param_label = signature.label:sub(param.label[1] + 1, param.label[2])
      end

      local doc_contents = {
        "Parameter: " .. param_label,
        "Documentation:",
        type(param.documentation) == "table" and 
          (param.documentation.value or "") or 
          param.documentation
      }
      
      -- Create secondary float for parameter details
      local doc_buf = api.nvim_create_buf(false, true)
      local doc_win = api.nvim_open_win(doc_buf, false, {
        relative = "win",
        win = self.win,
        row = height,
        col = 0,
        width = width,
        height = #doc_contents,
        style = "minimal",
        border = self.config.border
      })
      
      api.nvim_buf_set_lines(doc_buf, 0, -1, false, doc_contents)
      api.nvim_win_set_option(doc_win, "winblend", self.config.winblend)
    end
  end

  self.visible = true
end

function SignatureHelp:hide()
  if self.visible then
    if self.timer then
      vim.fn.timer_stop(self.timer)
      self.timer = nil
    end
    
    if self.buf then
      self._highlight_cache[self.buf] = nil
    end
    
    pcall(api.nvim_win_close, self.win, true)
    pcall(api.nvim_buf_delete, self.buf, { force = true })
    self.win = nil
    self.buf = nil
    self.visible = false
    self.current_signatures = nil
  end
end

function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  api.nvim_buf_clear_namespace(self.buf, self._ns, 0, -1)

  if not self._highlight_cache[self.buf] then
    self._highlight_cache[self.buf] = {}
  end

  for index, signature in ipairs(signatures) do
    local parameter = signature.activeParameter or active_parameter
    if parameter and parameter >= 0 and parameter < #signature.parameters then
      local label = signature.parameters[parameter + 1].label
      if type(label) == "string" then
        local line = labels[index]
        local line_text = api.nvim_buf_get_lines(self.buf, line - 1, line, false)[1]
        local start_idx = line_text:find(vim.pesc(label))
        if start_idx then
          api.nvim_buf_add_highlight(self.buf, self._ns, "LspSignatureActiveParameter", 
            line - 1, start_idx - 1, start_idx + #label - 1)
        end
      elseif type(label) == "table" then
        api.nvim_buf_add_highlight(self.buf, self._ns, "LspSignatureActiveParameter", 
          labels[index], unpack(label))
      end
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
    self:create_float_window(markdown, result.signatures[1])
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

function SignatureHelp:setup_triggers()
  self.trigger_chars = {}
  
  -- Get trigger characters from LSP servers
  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if client.server_capabilities.signatureHelpProvider then
      local chars = client.server_capabilities.signatureHelpProvider.triggerCharacters
      if chars then
        vim.list_extend(self.trigger_chars, chars)
      end
    end
  end

  -- Deduplicate trigger characters
  self.trigger_chars = vim.fn.uniq(self.trigger_chars)
end

function SignatureHelp:should_trigger()
  local char = vim.fn.strcharpart(vim.fn.getline('.'):sub(1, vim.fn.col('.')), -1)
  return vim.tbl_contains(self.trigger_chars, char)
end

function SignatureHelp:trigger()
  if not self.enabled then return end
  
  local bufnr = api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then return end

  if not self._has_signature_help_checked then
    self:check_capability()
    self._has_signature_help_checked = true
  end

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(bufnr, "textDocument/signatureHelp", params, function(err, result, _, _)
    if not api.nvim_buf_is_valid(bufnr) then return end
    
    if err then
      if not self.config.silent then
        vim.notify("Error in LSP Signature Help: " .. vim.inspect(err), vim.log.levels.ERROR)
      end
      self:hide()
      return
    end

    if result then
      if not vim.deep_equal(result, self.current_signatures) then
        self:display(result)
      end
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
  
  local debounce_timer = nil
  local function debounced_trigger()
    if debounce_timer then
      vim.fn.timer_stop(debounce_timer)
    end
    debounce_timer = vim.fn.timer_start(30, function()
      debounce_timer = nil
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

  vim.cmd(string.format([[
        highlight default LspSignatureActiveParameter guifg=#c8d3f5 guibg=#4ec9b0 gui=bold
        highlight default link FloatBorder Normal
        highlight default NormalFloat guibg=#1e1e1e guifg=#d4d4d4
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

  -- Cleanup previous instance if exists
  if M._current_instance then
    M._current_instance:hide()
  end
  
  M._current_instance = signature_help
  
  -- Add cleanup on vim exit
  api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if M._current_instance then
        M._current_instance:hide()
      end
    end
  })
end

-- Add new highlight definitions
local function setup_highlights()
  local highlights = {
    SignatureActiveParameter = {
      fg = "#89DCEB", -- Bright cyan for active parameter
      bold = true
    },
    SignatureParameterType = {
      fg = "#94E2D5", -- Muted teal for type info
      italic = true  
    },
    SignatureParameterDoc = {
      fg = "#BAC2DE", -- Light gray for docs
      italic = true
    },
    SignatureDoc = {
      bg = "#1E1E2E", -- Dark background for doc float
    },
    SignatureDocBorder = {
      fg = "#89DCEB", -- Cyan border for doc window
    }
  }

  for group, settings in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, settings)
  end
end

local function create_doc_window(parameter_info)
  -- Create dedicated documentation float window
  local docs = {
    -- Format parameter documentation
    "Parameter: " .. (parameter_info.name or ""),
    "Type: " .. (parameter_info.type or ""),
    "", -- Empty line separator
    parameter_info.doc or ""
  }

  local opts = {
    relative = 'cursor',
    width = 60,
    height = 10,
    style = 'minimal',
    border = 'rounded',
    title = ' Documentation ',
    title_pos = 'center'
  }

  -- Create buffer and window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, docs)
  
  local win = vim.api.nvim_open_win(buf, false, opts)
  
  -- Add highlights
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:SignatureDoc,FloatBorder:SignatureDocBorder')
  
  return win, buf
end

local function enhanced_virtual_hint(hint, parameter_info, off_y)
  if not hint then return end
  
  local vt_ns = vim.api.nvim_create_namespace('enhanced_signature_vt')
  
  -- Create styled virtual text
  local vt = {
    -- Parameter name with custom highlight
    { parameter_info.name or "", "SignatureActiveParameter" },
    -- Parameter type if available
    { ": " .. (parameter_info.type or ""), "SignatureParameterType" },
    -- Parameter description in muted color
    { " " .. (parameter_info.doc or ""), "SignatureParameterDoc" }
  }

  -- Position virtual text based on context
  local pos_opts = {
    virt_text = vt,
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    priority = 100
  }

  -- Add virtual text
  vim.api.nvim_buf_set_extmark(0, vt_ns, off_y, 0, pos_opts)
end

function SignatureHelp:format_markdown(text)
  if not text then return {} end
  
  -- Convert common markdown elements
  local lines = vim.split(text, "\n")
  local formatted = {}
  
  for _, line in ipairs(lines) do
    -- Convert code blocks
    line = line:gsub("```(%w+)(.-?)```", function(lang, code)
      return string.format("\n%s\n%s\n%s", 
        string.rep("─", 40),
        code,
        string.rep("─", 40)
      )
    end)
    
    -- Convert inline code
    line = line:gsub("`([^`]+)`", "│%1│")
    
    table.insert(formatted, line)
  end
  
  return formatted
end

return M
