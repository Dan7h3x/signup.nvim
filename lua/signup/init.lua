local api = vim.api
local lsp = vim.lsp
local fn = vim.fn

-- Safe string utilities
local function safe_str(value)
  if type(value) == "table" then
    return value.value or ""
  end
  return tostring(value or "")
end

local function split_lines(str)
  if not str or type(str) ~= "string" then return {} end
  return vim.split(str, "\n", { trimempty = true })
end

local function truncate(str, max_len)
  if not str or type(str) ~= "string" then return "" end
  if #str > max_len then
    return str:sub(1, max_len - 3) .. "..."
  end
  return str
end

local function parse_parameter(param)
  if not param or not param.label then return nil, nil end
  local label = safe_str(param.label)
  
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
end

-- Default configuration
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
  debounce_ms = 50,
  icons = {
    parameter = "󰘦 ",
    method = "󰡱 ",
    info = "+",
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
  documentation = {
    markdown = true,
    code_block_highlight = true,
    show_links = true,
    max_height = 10,
    sections = {
      parameters = true,
      returns = true,
      examples = true,
      related = true,
    },
    highlights = {
      code_block = { bg = "#1E1E2E", italic = true },
      header = { fg = "#F5C2E7", bold = true },
      inline_code = { fg = "#89DCEB" },
      link = { fg = "#89B4FA", underline = true },
      type = { fg = "#94E2D5", italic = true },
      deprecated = { fg = "#F38BA8", strikethrough = true },
    },
  },
}

-- Add documentation formatting utilities
local doc_utils = {
  parse_markdown = function(text)
    if not text then return {} end
    local lines = {}
    local in_code_block = false
    local code_lang = nil
    
    for _, line in ipairs(split_lines(safe_str(text))) do
      -- Code block detection
      local code_start = line:match("^%s*```(%w*)")
      if code_start then
        in_code_block = not in_code_block
        code_lang = code_start ~= "" and code_start or nil
        table.insert(lines, { line = line, type = "code_fence", lang = code_lang })
        goto continue
      end
      
      if in_code_block then
        table.insert(lines, { line = line, type = "code", lang = code_lang })
        goto continue
      end
      
      -- Headers
      local header_level = line:match("^(#+)%s")
      if header_level then
        table.insert(lines, { 
          line = line, 
          type = "header", 
          level = #header_level 
        })
        goto continue
      end
      
      -- Links
      local link_text, link_url = line:match("%[([^%]]+)%]%(([^%)]+)%)")
      if link_text and link_url then
        table.insert(lines, {
          line = line,
          type = "link",
          text = link_text,
          url = link_url
        })
        goto continue
      end
      
      -- Inline code
      if line:match("`[^`]+`") then
        table.insert(lines, { line = line, type = "inline_code" })
        goto continue
      end
      
      -- Regular text
      table.insert(lines, { line = line, type = "text" })
      
      ::continue::
    end
    
    return lines
  end,
  
  format_type = function(type_info)
    if not type_info then return "" end
    local type_str = safe_str(type_info)
    
    -- Format union types
    type_str = type_str:gsub("|", " | ")
    
    -- Format generic types
    type_str = type_str:gsub("<([^>]+)>", function(inner)
      return "<" .. inner:gsub("%s*,%s*", ", ") .. ">"
    end)
    
    return type_str
  end,
}

---@class SignatureHelper
---@field private win number? Window handle
---@field private buf number? Buffer handle
---@field private timer number? Timer handle
---@field private visible boolean
---@field private current_sig table?
---@field private config table
local SignatureHelper = {}
SignatureHelper.__index = SignatureHelper

function SignatureHelper.new(config)
  local self = setmetatable({
    win = nil,
    buf = nil,
    timer = nil,
    visible = false,
    current_sig = nil,
    config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, config or {}),
  }, SignatureHelper)
  
  self:setup_highlights()
  return self
end

function SignatureHelper:setup_highlights()
  for name, opts in pairs(self.config.hl_groups) do
    pcall(api.nvim_set_hl, 0, "SignatureHelp" .. name:gsub("^%l", string.upper), opts)
  end
end

function SignatureHelper:format_signature(signature, active_param)
  if not signature then return {} end
  
  local lines = {}
  
  -- Method signature with parameter count
  local method = safe_str(signature.label)
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
      
      local name, default = parse_parameter(param)
      if not name then goto continue end
      
      local param_info = {
        index = i,
        name = name,
        default = default,
        doc = param.documentation and safe_str(param.documentation) or nil,
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
          truncate(param_info.default, self.config.render.max_parameter_width)
      end
      
      table.insert(lines, param_line)
      
      -- Parameter documentation
      if param_info.doc then
        local doc_lines = split_lines(param_info.doc)
        for _, line in ipairs(doc_lines) do
          table.insert(lines, "    " .. line)
        end
      end
    end
  end
  
  -- Enhanced documentation
  if signature.documentation and self.config.documentation.markdown then
    table.insert(lines, "")
    table.insert(lines, self.config.icons.info .. "Documentation:")
    
    local doc_lines = doc_utils.parse_markdown(signature.documentation)
    local current_section = nil
    
    for _, doc_line in ipairs(doc_lines) do
      -- Format based on line type
      if doc_line.type == "header" then
        current_section = doc_line.line:lower():match("^#+%s*(.+)$")
        if self.config.documentation.sections[current_section] then
          table.insert(lines, {
            line = doc_line.line,
            hl = "SignatureHelpHeader"
          })
        end
      elseif doc_line.type == "code" or doc_line.type == "code_fence" then
        if self.config.documentation.code_block_highlight then
          table.insert(lines, {
            line = string.rep(" ", 2) .. doc_line.line,
            hl = "SignatureHelpCodeBlock",
            lang = doc_line.lang
          })
        end
      elseif doc_line.type == "link" and self.config.documentation.show_links then
        table.insert(lines, {
          line = string.format("%s (%s)", doc_line.text, doc_line.url),
          hl = "SignatureHelpLink"
        })
      elseif doc_line.type == "inline_code" then
        table.insert(lines, {
          line = string.rep(" ", 2) .. doc_line.line,
          hl = "SignatureHelpInlineCode"
        })
      else
        table.insert(lines, {
          line = string.rep(" ", 2) .. doc_line.line,
          hl = "SignatureHelpDoc"
        })
      end
    end
  end
  
  return lines
end

function SignatureHelper:format_documentation(doc)
  if not doc then return {} end
  local lines = {}
  
  -- Add markdown syntax highlighting
  local md_lines = split_lines(safe_str(doc))
  for _, line in ipairs(md_lines) do
    -- Highlight code blocks
    if line:match("^%s*```") then
      table.insert(lines, { line, "SignatureHelpCodeBlock" })
    -- Highlight headers
    elseif line:match("^#+ ") then
      table.insert(lines, { line, "SignatureHelpHeader" })
    -- Highlight inline code
    elseif line:match("`[^`]+`") then
      table.insert(lines, { line, "SignatureHelpInlineCode" })
    else
      table.insert(lines, { line, "SignatureHelpDoc" })
    end
  end
  return lines
end

-- Add method to apply enhanced highlights
function SignatureHelper:apply_doc_highlights()
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end
  
  local ns_id = api.nvim_create_namespace("SignatureHelpDoc")
  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  
  for i, line in ipairs(lines) do
    if type(line) == "table" and line.hl then
      pcall(api.nvim_buf_add_highlight, self.buf, ns_id, line.hl, i-1, 0, -1)
      
      -- Apply treesitter highlighting for code blocks
      if line.hl == "SignatureHelpCodeBlock" and line.lang then
        pcall(vim.treesitter.highlight.attach, self.buf, line.lang)
      end
    end
  end
end

-- Rest of your code remains the same...
