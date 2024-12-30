-- init.lua
local api = vim.api
local utils = require("signup.utils")
local window = require("signup.window")
local highlights = require("signup.highlights")

local M = {}

-- Default configuration with better organization and documentation
local default_config = {
    ui = {
        border = "rounded",
        max_width = 80, -- Maximum width of the floating window
        max_height = 10, -- Maximum height of the floating window
        min_width = 40, -- Minimum width to maintain readability
        padding = 1, -- Padding around the content
        spacing = 1, -- Spacing between signature elements
        opacity = 0.9, -- Window opacity (1 = solid, 0 = transparent)
        zindex = 50, -- Z-index for floating window
        wrap = true, -- Enable text wrapping
        show_header = true, -- Show signature header
    },
    parameter_indicators = {
        enabled = true, -- Show parameter position indicators
        active_symbol = "●", -- Symbol for active parameter
        inactive_symbol = "○", -- Symbol for inactive parameters
        separator = " ", -- Separator between indicators
    },
    highlights = {
        enabled = true, -- Enable custom highlighting
        icons = true, -- Highlight icons
        parameters = true, -- Highlight parameters
        indicators = true, -- Highlight indicators
        header = true, -- Highlight header
    },
    position = {
        prefer_above = true, -- Prefer window above cursor
        padding = 1, -- Padding from cursor
        avoid_cursor = true, -- Avoid cursor position
        follow_cursor = true, -- Move window with cursor
    },
    colors = {
        background = nil, -- Background color (nil = use default)
        border = nil, -- Border color
        parameter = "#86e1fc", -- Parameter highlight color
        text = nil, -- Text color
        type = "#c099ff", -- Type highlight color
        method = "#4fd6be", -- Method highlight color
        documentation = "#4fd6be", -- Documentation text color
        default_value = "#a8a8a8", -- Default value color
        header = "#c099ff", -- Header color
        active_parameter_colors = {
            fg = "#1a1a1a", -- Active parameter foreground
            bg = "#86e1fc", -- Active parameter background
            bold = true, -- Bold active parameter
        },
    },
    features = {
        virtual_text = true,
        preview_window = true,
        history = true,
        language_specific = true,
        completion_integration = true,
    },
    virtual_text = {
        enabled = true,
        prefix = "󰏚 ",
        suffix = " ",
    },
    preview = {
        border = "rounded",
        max_width = 60,
        max_height = 10,
        position = "top",
    },
    history = {
        max_entries = 50,
        show_timestamps = true,
    },
    icons = {
        parameter = "󰘍 ", -- Parameter icon
        method = "󰡱 ", -- Method icon
        separator = " → ", -- Separator icon
        header = "󰅲 ", -- Header icon
    },
    behavior = {
        auto_trigger = true, -- Auto trigger on typing
        trigger_chars = { "(", ",", "<" }, -- Characters that trigger signature
        close_on_done = true, -- Close when done typing
        dock_mode = false, -- Enable dock mode
        dock_position = "bottom", -- Dock position (bottom/top/right)
        debounce = 50, -- Debounce time in ms
        prefer_active = true, -- Prefer active signature
        avoid_cmp_overlap = true, -- Avoid overlap with completion
    },
    performance = {
        cache_size = 10, -- Size of signature cache
        throttle = 30, -- Throttle time in ms
        gc_interval = 60 * 60, -- Garbage collection interval
        max_signature_length = 100, -- Max signature length
    },
    keymaps = {
        toggle = "<C-k>", -- Toggle signature help
        next_signature = "<C-j>", -- Next signature
        prev_signature = "<C-h>", -- Previous signature
        next_parameter = "<C-l>", -- Next parameter
        prev_parameter = "<C-h>", -- Previous parameter
        toggle_dock = "<Leader>sd", -- Toggle dock mode
        scroll_up = "<C-u>", -- Scroll documentation up
        scroll_down = "<C-d>", -- Scroll documentation down
    },
}
-- SignatureHelp class
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
    local self = setmetatable({
        -- Window management
        win = nil, -- Main window handle
        buf = nil, -- Main buffer handle
        dock_win = nil, -- Dock window handle
        dock_buf = nil, -- Dock buffer handle

        -- State management
        highlight_ns = vim.api.nvim_create_namespace("SignatureHelpHighlight"),
        last_context = nil, -- Last signature context
        visible = false, -- Window visibility state
        config = vim.deepcopy(default_config),

        -- Current signature state
        current = {
            signatures = nil, -- Current signatures
            active_sig = 1, -- Active signature index
            active_param = 0, -- Active parameter index
            dock_mode = false, -- Dock mode state
        },

        -- Performance management
        timers = {
            debounce = nil, -- Debounce timer
            throttle = nil, -- Throttle timer
            gc = nil, -- Garbage collection timer
        },

        -- Feature flags
        enabled = false, -- LSP capability enabled
        normal_mode_active = false, -- Normal mode state

        -- Cache management
        last_active_parameter = nil,
        parameter_cache = {}, -- Parameter cache
    }, SignatureHelp)

    return self
end

-- Validation helpers
local function validate_window(self)
    return utils.is_valid_window(self.win)
end

local function validate_buffer(self)
    return utils.is_valid_buffer(self.buf)
end

-- Configuration validation
local function validate_config(config)
    -- Ensure required fields exist
    assert(config.ui, "Missing UI configuration")
    assert(config.behavior, "Missing behavior configuration")
    assert(config.colors, "Missing colors configuration")

    -- Validate UI settings
    assert(type(config.ui.max_width) == "number", "max_width must be a number")
    assert(type(config.ui.max_height) == "number", "max_height must be a number")

    -- Validate behavior settings
    assert(type(config.behavior.auto_trigger) == "boolean", "auto_trigger must be a boolean")
    assert(type(config.behavior.trigger_chars) == "table", "trigger_chars must be a table")

    return true
end

function SignatureHelp:validate_context(old_state, ctx)
    if ctx.bufnr ~= old_state.bufnr then
        return false
    end

    local new_line = vim.api.nvim_get_current_line()
    local new_cursor = vim.api.nvim_win_get_cursor(0)

    if
        new_line ~= old_state.line
        or new_cursor[1] ~= old_state.row
        or math.abs((new_cursor[2] or 0) - (old_state.col or 0)) > 1
    then
        return false
    end

    return true
end

function SignatureHelp:check_capability()
    -- Simple check if LSP is available and has signature help capability
    local clients = vim.lsp.get_active_clients({ bufnr = 0 })
    for _, client in ipairs(clients) do
        if client.server_capabilities.signatureHelpProvider then
            self.enabled = true
            return true
        end
    end
    self.enabled = false
    return false
end

function SignatureHelp:manage_cache()
    local now = vim.loop.now()
    local max_age = self.config.performance.cache_timeout or (60 * 1000) -- 1 minute default

    for k, v in pairs(self.parameter_cache) do
        if (now - v.timestamp) > max_age then
            self.parameter_cache[k] = nil
        end
    end
end

function SignatureHelp:close_dock_window()
    if self.dock_win and api.nvim_win_is_valid(self.dock_win) then
        pcall(api.nvim_win_close, self.dock_win, true)
    end
    if self.dock_buf and api.nvim_buf_is_valid(self.dock_buf) then
        pcall(api.nvim_buf_delete, self.dock_buf, { force = true })
    end
    self.dock_win = nil
    self.dock_buf = nil
end

function SignatureHelp:apply_treesitter_highlighting()
    local buf = self.config.behavior.dock_mode and self.dock_buf or self.buf
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


function SignatureHelp:process_signature_result(result)
    -- Process signature information
    local active_sig_idx = result.activeSignature or 0
    local sig = result.signatures[active_sig_idx + 1]

    if sig then
        -- Update cache
        self.parameter_cache[sig.label] = {
            count = (sig.parameters and #sig.parameters) or 0,
            active = result.activeParameter or 0, -- Ensure default value
            timestamp = vim.loop.now(),
            signature = sig,
            bufnr = ctx.bufnr,
        }

        -- Manage cache size with safe iteration
        self:manage_cache()
    end

    -- Update state with safe assignment
    self.last_active_parameter = result.activeParameter or 0
    self:smart_refresh()
end

function SignatureHelp:create_window(contents)
    -- Use the window module for creation
    local win, buf = window.create_window(contents, self.config)
    if win and buf then
        self.win = win
        self.buf = buf
        self.visible = true
        self:apply_highlights()
    end
    return win, buf
end

function SignatureHelp:get_window_opts(width, height)
    if self.current.dock_mode then
        return self:get_dock_window_opts(width, height)
    end

    -- Get cursor position
    local cursor_pos = api.nvim_win_get_cursor(0)
    local screen_pos = vim.fn.screenpos(0, cursor_pos[1], cursor_pos[2])
    local row_offset = screen_pos.row - vim.fn.winline()

    return {
        relative = "editor",
        width = width,
        height = height,
        col = screen_pos.col - 1,
        row = row_offset,
        style = "minimal",
        border = self.config.ui.border,
        zindex = self.config.ui.zindex,
    }
end

-- Signature Detection and Parameter Tracking
function SignatureHelp:detect_signature_context()
    local cursor_pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local col = cursor_pos[2]
    local line_to_cursor = line:sub(1, col)

    -- Track parentheses and parameters
    local context = {
        open_parens = 0,
        param_index = 0,
        in_string = false,
        in_comment = false,
        last_char = nil,
        method_start = nil,
        method_name = nil,
    }

    -- Scan line for context
    for i = 1, #line_to_cursor do
        local char = line_to_cursor:sub(i, i)

        -- Skip if in string or comment
        if char == '"' or char == "'" then
            context.in_string = not context.in_string
        elseif not context.in_string then
            if char == "(" then
                context.open_parens = context.open_parens + 1
                if context.open_parens == 1 then
                    context.method_start = i
                    -- Try to extract method name
                    local before = line_to_cursor:sub(1, i - 1)
                    context.method_name = before:match("([%w_]+)%s*$")
                end
            elseif char == ")" then
                context.open_parens = context.open_parens - 1
            elseif char == "," and context.open_parens == 1 then
                context.param_index = context.param_index + 1
            end
        end
        context.last_char = char
    end

    return context
end

function SignatureHelp:detect_active_parameter()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, cursor_pos[2])

    -- Track nested parentheses and strings
    local open_count = 0
    local param_index = 0
    local in_string = false
    local string_char = nil

    for i = 1, #line_to_cursor do
        local char = line_to_cursor:sub(i, i)

        -- Handle string detection
        if char == '"' or char == "'" then
            if not in_string then
                in_string = true
                string_char = char
            elseif string_char == char then
                in_string = false
                string_char = nil
            end
        end

        -- Skip if in string
        if not in_string then
            if char == "(" then
                open_count = open_count + 1
            elseif char == ")" then
                open_count = open_count - 1
            elseif char == "," and open_count > 0 then
                param_index = param_index + 1
            end
        end
    end

    return open_count > 0 and param_index or nil
end

-- Dock Mode Implementation
function SignatureHelp:create_dock_window()
    local dock_config = self:calculate_dock_position()

    -- Create or reuse buffer
    if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
        self.dock_buf = api.nvim_create_buf(false, true)
        vim.bo[self.dock_buf].buftype = "nofile"
        vim.bo[self.dock_buf].bufhidden = "hide"
        vim.bo[self.dock_buf].swapfile = false
        vim.bo[self.dock_buf].filetype = "SignatureHelp"
    end

    -- Remove noautocmd from config for existing windows
    if self.dock_win and api.nvim_win_is_valid(self.dock_win) then
        dock_config.noautocmd = nil
        api.nvim_win_set_config(self.dock_win, dock_config)
    else
        -- Create new window with noautocmd
        self.dock_win = api.nvim_open_win(self.dock_buf, false, dock_config)

        -- Set window options
        local win_opts = {
            wrap = true,
            foldenable = false,
            winblend = math.floor((1 - self.config.ui.opacity) * 100),
            winhighlight = "Normal:SignatureHelpDock,FloatBorder:SignatureHelpBorder",
            signcolumn = "no",
            cursorline = false,
            number = false,
            relativenumber = false,
            linebreak = true, -- Enable smart line breaks
            breakindent = true, -- Preserve indentation on wrapped lines
            showbreak = "↪ ", -- Show break indicator
        }

        for opt, val in pairs(win_opts) do
            vim.wo[self.dock_win][opt] = val
        end
    end

    return self.dock_win, self.dock_buf
end

function SignatureHelp:calculate_dock_position()
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines
    local dock_position = self.config.behavior.dock_position
    local padding = self.config.ui.padding

    -- Calculate dimensions
    local width = math.min(
        math.max(40, self.config.ui.min_width),
        self.config.ui.max_width,
        editor_width - (padding * 2)
    )
    local height = math.min(self.config.ui.max_height, #self.current_signatures + 2)

    local config = {
        relative = "editor",
        width = width,
        height = height,
        style = "minimal",
        border = self.config.ui.border,
        zindex = self.config.ui.zindex,
        focusable = false,
        noautocmd = true,
    }

    -- Position based on dock mode configuration
    if dock_position == "bottom" then
        config.row = editor_height - height - 4
        config.col = editor_width - width - padding
    elseif dock_position == "top" then
        config.row = padding + 1
        config.col = editor_width - width - padding
    else -- right
        config.row = math.floor((editor_height - height) / 2)
        config.col = editor_width - width - padding
    end

    return config
end


-- Highlighting and Display Logic
function SignatureHelp:apply_highlights()
    if not self.buf or not api.nvim_buf_is_valid(self.buf) then
        return
    end

    -- Clear existing highlights
    api.nvim_buf_clear_namespace(self.buf, self.highlight_ns, 0, -1)

    -- Get buffer content
    local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)

    -- Apply highlights for each line
    for i, line in ipairs(lines) do
        -- Highlight method name
        local method_start = line:find(vim.pesc(self.config.icons.method))
        if method_start then
            local method_end = line:find("%(")
            if method_end then
                api.nvim_buf_add_highlight(
                    self.buf,
                    self.highlight_ns,
                    "SignatureHelpMethod",
                    i - 1,
                    method_start - 1,
                    method_end - 1
                )
            end
        end

        -- Highlight active parameter
        local active_param_start, active_param_end = line:find("<[^>]+>")
        if active_param_start then
            api.nvim_buf_add_highlight(
                self.buf,
                self.highlight_ns,
                "SignatureHelpActiveParameter",
                i - 1,
                active_param_start - 1,
                active_param_end
            )
        end

        -- Highlight documentation sections
        if line:match("^%s*Documentation:") then
            api.nvim_buf_add_highlight(self.buf, self.highlight_ns, "SignatureHelpDocumentation", i - 1, 0, -1)
        end
    end

    -- Add icon highlights
    self:highlight_icons(self.buf)
end

function SignatureHelp:highlight_icons(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end

    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
        -- Highlight method icons
        local method_icon_start = line:find(vim.pesc(self.config.icons.method))
        if method_icon_start then
            api.nvim_buf_add_highlight(
                buf,
                self.highlight_ns,
                "SignatureHelpMethodIcon",
                i - 1,
                method_icon_start - 1,
                method_icon_start + #self.config.icons.method - 1
            )
        end

        -- Highlight parameter icons
        local param_icon_start = line:find(vim.pesc(self.config.icons.parameter))
        if param_icon_start then
            api.nvim_buf_add_highlight(
                buf,
                self.highlight_ns,
                "SignatureHelpParamIcon",
                i - 1,
                param_icon_start - 1,
                param_icon_start + #self.config.icons.parameter - 1
            )
        end
    end
end

function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
    local buf = self.current.dock_mode and self.dock_buf or self.buf
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end

    -- Clear existing parameter highlights
    api.nvim_buf_clear_namespace(buf, self.highlight_ns, 0, -1)

    local signature = signatures[self.current_signature_idx or 1]
    if not signature or not signature.parameters then
        return
    end

    local param = signature.parameters[active_parameter + 1]
    if not param then
        return
    end

    -- Get parameter range
    local start_pos, end_pos
    if type(param.label) == "table" then
        start_pos = param.label[1]
        end_pos = param.label[2]
    else
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        local content = lines[1]
        if content then
            start_pos = content:find(vim.pesc(param.label))
            if start_pos then
                end_pos = start_pos + #param.label - 1
            end
        end
    end

    -- Apply highlight with visual distinction
    if start_pos and end_pos then
        api.nvim_buf_add_highlight(buf, self.highlight_ns, "SignatureHelpActiveParameter", 0, start_pos - 1, end_pos)
    end

    -- Reapply other highlights
    self:highlight_icons(buf)
end

function SignatureHelp:format_signature_list(signatures)
    if not signatures or type(signatures) ~= "table" then
        return {}, {}
    end

    local contents = {}
    local labels = {}
    local show_index = #signatures > 1

    for idx, signature in ipairs(signatures) do
        if type(signature) == "table" then
            table.insert(labels, #contents + 1)

            -- Format signature line
            local ok, sig_lines = pcall(self.format_signature_line, self, signature, idx, show_index)
            if ok and sig_lines then
                -- Add signature lines
                for _, line in ipairs(sig_lines) do
                    table.insert(contents, line)
                end

                -- Add documentation using docs module
                if signature.documentation then
                    local doc_lines = self:format_documentation(signature.documentation)
                    for _, line in ipairs(doc_lines) do
                        table.insert(contents, line)
                    end
                end

                -- Add separator between signatures
                if idx < #signatures then
                    table.insert(contents, string.rep("═", 40))
                end
            end
        end
    end

    -- Remove trailing empty lines
    while #contents > 0 and not contents[#contents]:match("%S") do
        table.remove(contents)
    end

    return contents, labels
end

function SignatureHelp:format_documentation(doc)
    local lines = {}
    local doc_text = type(doc) == "string" and doc or (doc.value or "")
    
    if doc_text:match("%S") then
        -- Add separator for visual distinction
        table.insert(lines, string.rep("─", 40))
        -- Add documentation header with icon
        table.insert(lines, self.config.icons.documentation .. " Documentation:")
        
        -- Format each line with proper indentation
        for _, line in ipairs(vim.split(doc_text, "\n")) do
            if line:match("%S") then
                table.insert(lines, "  " .. line)
            end
        end
    end
    
    return lines
end


-- Display Management and Updates
function SignatureHelp:display(result)
    if not result or not result.signatures or #result.signatures == 0 then
        self:hide()
        return
    end

    -- Check if we need to update
    if self:should_skip_update(result) then
        return
    end

    -- Update current state
    self:update_current_state(result)

    -- Format content
    local ok, contents, labels = pcall(self.format_signature_list, self, result.signatures)
    if not ok or not contents or #contents == 0 then
        vim.notify("Error formatting signature: " .. (contents or "unknown error"), vim.log.levels.ERROR)
        return
    end

    -- Create or update window
    if self.config.behavior.dock_mode then
        self:create_dock_display(contents, result)
    else
        self:create_float_display(contents, result, labels)
    end
end

function SignatureHelp:should_skip_update(result)
    if not self.visible or not self.current_signatures then
        return false
    end

    local current_sig = self.current_signatures[self.current_signature_idx or 1]
    local new_sig = result.signatures[result.activeSignature or 0]
    local current_param = self.last_active_parameter or 0
    local new_param = result.activeParameter or 0

    return current_sig and new_sig and current_sig.label == new_sig.label and current_param == new_param
end

function SignatureHelp:update_current_state(result)
    self.current_signatures = result.signatures
    self.current_active_parameter = result.activeParameter or 0
    self.current_signature_idx = (result.activeSignature and result.activeSignature + 1) or 1
end

function SignatureHelp:create_dock_display(contents, result)
    local win, buf = self:create_dock_window()
    if win and buf then
        pcall(api.nvim_buf_set_lines, buf, 0, -1, false, contents)
        pcall(vim.lsp.util.stylize_markdown, buf, contents, {})
        pcall(self.set_dock_parameter_highlights, self, result.activeParameter or 0, result.signatures)
        self.visible = true

        if self.config.parameter_indicators.enabled then
            self:add_parameter_indicators()
        end
    end
end

function SignatureHelp:create_float_display(contents, result, labels)
    local win, buf = self:create_window(contents)
    if win and buf then
        pcall(self.set_active_parameter_highlights, self, result.activeParameter or 0, result.signatures, labels)

        if self.config.parameter_indicators.enabled then
            self:add_parameter_indicators()
        end
    end
end

function SignatureHelp:update_active_parameter()
    local current_param = self:detect_active_parameter()
    if current_param ~= self.current_active_parameter then
        self.current_active_parameter = current_param
        if self.visible then
            self:refresh_display()
        end
    end
end

function SignatureHelp:refresh_display()
    if not self.current_signatures then
        return
    end

    local result = {
        signatures = self.current_signatures,
        activeParameter = self.current_active_parameter,
        activeSignature = self.current_signature_idx and (self.current_signature_idx - 1) or 0,
    }

    self:display(result)
end

function SignatureHelp:add_parameter_indicators()
    if not self.current_signatures then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig or not sig.parameters then
        return
    end

    -- Determine which buffer to use
    local buf = self.current.dock_mode and self.dock_buf or self.buf
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end

    local indicators = {}
    for i = 1, #sig.parameters do
        if i == self.current_active_parameter + 1 then
            table.insert(indicators, self.config.parameter_indicators.active_symbol)
        else
            table.insert(indicators, self.config.parameter_indicators.inactive_symbol)
        end
    end

    -- Add indicators with separator
    if #indicators > 0 then
        local indicator_line = table.concat(indicators, self.config.parameter_indicators.separator)
        pcall(api.nvim_buf_set_lines, buf, -1, -1, false, {
            string.rep("─", #indicator_line),
            indicator_line,
        })
    end
end

function SignatureHelp:toggle_dock_mode()
    -- Store current window and buffer
    local current_win = api.nvim_get_current_win()
    local current_buf = api.nvim_get_current_buf()

    -- Store current signatures
    local current_sigs = self.current_signatures
    local current_active = self.current_active_parameter

    -- Close existing windows efficiently
    if self.config.behavior.dock_mode then
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
    self.config.behavior.dock_mode = not self.config.behavior.dock_mode

    -- Redisplay if we had signatures
    if current_sigs then
        self:display({
            signatures = current_sigs,
            activeParameter = current_active,
        })
    end

    -- Restore focus
    pcall(api.nvim_set_current_win, current_win)
    pcall(api.nvim_set_current_buf, current_buf)
end


-- Event Handling and Keymaps
function SignatureHelp:setup_autocmds()
    local group = api.nvim_create_augroup("SignatureHelp", { clear = true })

    -- Auto-trigger in insert mode
    api.nvim_create_autocmd("InsertEnter", {
        group = group,
        callback = function()
            utils.debounce(function() self:trigger() end, self.config.behavior.debounce)
        end
    })

    -- Update on cursor movement in insert mode
    api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        callback = function()
            utils.debounce(function() self:trigger() end, self.config.behavior.debounce)
        end
    })

    -- Hide on leaving insert mode
    api.nvim_create_autocmd("InsertLeave", {
        group = group,
        callback = function()
            if not self.normal_mode_active then
                self:hide()
            end
        end
    })

    -- Handle window resize
    api.nvim_create_autocmd("VimResized", {
        group = group,
        callback = function()
            if self.visible then
                self:refresh_display()
            end
        end
    })

    -- Handle colorscheme changes
    api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            highlights.setup_highlights(self.config.colors)
            if self.visible then
                self:refresh_display()
            end
        end
    })
end
function SignatureHelp:setup_keymaps()
    -- Setup toggle keys using the actual config
    local toggle_key = self.config.keymaps.toggle
    local dock_toggle_key = self.config.keymaps.toggle_dock

    if toggle_key then
        vim.keymap.set("n", toggle_key, function()
            self:toggle_normal_mode()
        end, { noremap = true, silent = true, desc = "Toggle signature help in normal mode" })
        vim.keymap.set("i", toggle_key, function()
            if self.visible then
                self:hide()
            else
                self:trigger()
            end
        end, { noremap = true, silent = true, desc = "Toggle signature help in insert mode" })
    end

    if dock_toggle_key then
        vim.keymap.set("n", dock_toggle_key, function()
            self:toggle_dock_mode()
        end, { noremap = true, silent = true, desc = "Toggle between dock and float mode" })
    end

    -- Setup navigation keys
    local next_sig = self.config.keymaps.next_signature
    local prev_sig = self.config.keymaps.prev_signature
    local next_param = self.config.keymaps.next_parameter
    local prev_param = self.config.keymaps.prev_parameter

    if next_sig then
        vim.keymap.set("i", next_sig, function()
            self:next_signature()
        end, { noremap = true, silent = true, desc = "Next signature" })
    end

    if prev_sig then
        vim.keymap.set("i", prev_sig, function()
            self:prev_signature()
        end, { noremap = true, silent = true, desc = "Previous signature" })
    end

    if next_param then
        vim.keymap.set("i", next_param, function()
            self:next_parameter()
        end, { noremap = true, silent = true, desc = "Next parameter" })
    end

    if prev_param then
        vim.keymap.set("i", prev_param, function()
            self:prev_parameter()
        end, { noremap = true, silent = true, desc = "Previous parameter" })
    end
end

-- Navigation Functions
function SignatureHelp:next_signature()
    if not self.current_signatures then
        return
    end
    self.current_signature_idx = (self.current_signature_idx or 0) + 1
    if self.current_signature_idx > #self.current_signatures then
        self.current_signature_idx = 1
    end
    self:display({
        signatures = self.current_signatures,
        activeParameter = self.current_active_parameter,
        activeSignature = self.current_signature_idx - 1,
    })
end

function SignatureHelp:prev_signature()
    if not self.current_signatures then
        return
    end
    self.current_signature_idx = (self.current_signature_idx or 1) - 1
    if self.current_signature_idx < 1 then
        self.current_signature_idx = #self.current_signatures
    end
    self:display({
        signatures = self.current_signatures,
        activeParameter = self.current_active_parameter,
        activeSignature = self.current_signature_idx - 1,
    })
end

function SignatureHelp:next_parameter()
    if not self.current_signatures or not self.current_signature_idx then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig or not sig.parameters then
        return
    end

    local next_param = (self.current_active_parameter or 0) + 1
    if next_param >= #sig.parameters then
        next_param = 0
    end

    self.current_active_parameter = next_param
    self:display({
        signatures = self.current_signatures,
        activeParameter = next_param,
        activeSignature = self.current_signature_idx - 1,
    })
end

function SignatureHelp:prev_parameter()
    if not self.current_signatures or not self.current_signature_idx then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig or not sig.parameters then
        return
    end

    local prev_param = (self.current_active_parameter or 0) - 1
    if prev_param < 0 then
        prev_param = #sig.parameters - 1
    end

    self.current_active_parameter = prev_param
    self:display({
        signatures = self.current_signatures,
        activeParameter = prev_param,
        activeSignature = self.current_signature_idx - 1,
    })
end
-- Virtual Text Support
function SignatureHelp:setup_virtual_text()
    self.virtual_text_ns = vim.api.nvim_create_namespace("SignatureHelpVirtualText")

    -- Setup virtual text autocmd
    local group = vim.api.nvim_create_augroup("SignatureHelpVirtualText", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
        group = group,
        callback = function()
            self:update_virtual_text()
        end,
    })
end

function SignatureHelp:update_virtual_text()
    -- Clear existing virtual text
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(bufnr, self.virtual_text_ns, 0, -1)

    if not self.current_signatures or not self.visible then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig or not sig.parameters then
        return
    end

    local param = sig.parameters[self.current_active_parameter + 1]
    if not param then
        return
    end

    -- Get current line
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local row = cursor_pos[1] - 1

    -- Create virtual text
    local vtext = {
        {
            string.format(
                " %s: %s",
                param.label,
                (param.documentation and type(param.documentation) == "string" and param.documentation)
                    or (param.documentation and param.documentation.value)
                    or ""
            ),
            "SignatureHelpVirtualText",
        },
    }

    -- Set virtual text
    vim.api.nvim_buf_set_virtual_text(bufnr, self.virtual_text_ns, row, vtext, {})
end

-- Preview Window Support
function SignatureHelp:show_parameter_preview()
    if not self.current_signatures or not self.visible then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig or not sig.parameters then
        return
    end

    local param = sig.parameters[self.current_active_parameter + 1]
    if not param then
        return
    end

    -- Create preview buffer if it doesn't exist
    if not self.preview_buf or not vim.api.nvim_buf_is_valid(self.preview_buf) then
        self.preview_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[self.preview_buf].buftype = "nofile"
        vim.bo[self.preview_buf].bufhidden = "hide"
        vim.bo[self.preview_buf].filetype = "markdown"
    end

    -- Format preview content
    local contents = {
        "# Parameter: " .. param.label,
        "",
    }

    -- Add parameter documentation
    if param.documentation then
        local doc = type(param.documentation) == "string" and param.documentation or param.documentation.value
        if doc then
            table.insert(contents, "## Documentation")
            table.insert(contents, "")
            for _, line in ipairs(vim.split(doc, "\n")) do
                table.insert(contents, line)
            end
        end
    end

    -- Set preview content
    vim.api.nvim_buf_set_lines(self.preview_buf, 0, -1, false, contents)

    -- Calculate preview window position
    local win_width = math.min(60, vim.o.columns - 4)
    local win_height = math.min(10, #contents + 2)

    -- Create or update preview window
    if not self.preview_win or not vim.api.nvim_win_is_valid(self.preview_win) then
        self.preview_win = vim.api.nvim_open_win(self.preview_buf, false, {
            relative = "editor",
            width = win_width,
            height = win_height,
            row = 1,
            col = vim.o.columns - win_width - 1,
            style = "minimal",
            border = "rounded",
        })

        -- Set window options
        vim.wo[self.preview_win].wrap = true
        vim.wo[self.preview_win].conceallevel = 2
        vim.wo[self.preview_win].concealcursor = "n"
        vim.wo[self.preview_win].foldenable = false
    else
        vim.api.nvim_win_set_config(self.preview_win, {
            width = win_width,
            height = win_height,
        })
    end

    -- Apply markdown highlighting
    if pcall(require, "nvim-treesitter") then
        require("nvim-treesitter.highlight").attach(self.preview_buf, "markdown")
    end
end

-- Signature History Support
function SignatureHelp:add_to_history()
    if not self.signature_history then
        self.signature_history = {}
    end

    if not self.current_signatures then
        return
    end

    local sig = self.current_signatures[self.current_signature_idx]
    if not sig then
        return
    end

    -- Create history entry
    local entry = {
        signature = sig,
        timestamp = vim.loop.now(),
        bufname = vim.fn.bufname(),
        cursor_pos = vim.api.nvim_win_get_cursor(0),
    }

    -- Add to history (most recent first)
    table.insert(self.signature_history, 1, entry)

    -- Limit history size
    if #self.signature_history > self.config.history.max_entries then
        table.remove(self.signature_history)
    end
end

function SignatureHelp:show_history()
    if not self.signature_history or #self.signature_history == 0 then
        vim.notify("No signature history available", vim.log.levels.INFO)
        return
    end

    -- Create history buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "SignatureHistory"

    -- Format history entries
    local contents = {}
    for i, entry in ipairs(self.signature_history) do
        local sig = entry.signature
        local time_ago = string.format("%.0f", (vim.loop.now() - entry.timestamp) / 1000)

        table.insert(
            contents,
            string.format("### %d. %s (%s seconds ago)", i, vim.fn.fnamemodify(entry.bufname, ":t"), time_ago)
        )
        table.insert(contents, sig.label)
        if sig.documentation then
            local doc = type(sig.documentation) == "string" and sig.documentation or sig.documentation.value
            if doc then
                table.insert(contents, "")
                table.insert(contents, doc)
            end
        end
        table.insert(contents, string.rep("─", 40))
    end

    -- Set buffer contents
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, contents)

    -- Create window
    local win_width = math.min(80, vim.o.columns - 4)
    local win_height = math.min(20, #contents)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = win_width,
        height = win_height,
        row = math.floor((vim.o.lines - win_height) / 2),
        col = math.floor((vim.o.columns - win_width) / 2),
        style = "minimal",
        border = "rounded",
    })

    -- Set window options
    vim.wo[win].wrap = true
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "n"
    vim.wo[win].foldenable = false

    -- Add keymaps for the history window
    local opts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, opts)
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, opts)
    vim.keymap.set("n", "<CR>", function()
        local line = vim.fn.line(".")
        local entry = self.signature_history[math.floor((line - 1) / 4) + 1]
        if entry then
            vim.api.nvim_win_close(win, true)
            self:display({ signatures = { entry.signature } })
        end
    end, opts)
end



function SignatureHelp:trigger()
    -- Early return if no LSP capability
    if not self:check_capability() then
        return
    end

    -- Get current context
    local context = self:detect_signature_context()
    if not context.method_name then
        self:hide()
        return
    end

    -- Request signature help safely
    local bufnr = vim.api.nvim_get_current_buf()
    vim.lsp.buf.signature_help({
        bufnr = bufnr,
        handler = vim.schedule_wrap(function(err, result, ctx)
            if err or not result or not result.signatures or #result.signatures == 0 then
                return
            end
            
            -- Process and display result
            self:process_signature_result(result)
            self:display(result)
            
            -- Add to history if enabled
            if self.config.features.history then
                self:add_to_history()
            end
        end)
    })
end
function SignatureHelp:hide()
    -- Close main window
    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
    end
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end

    -- Close dock window if exists
    self:close_dock_window()

    -- Reset state
    self.win = nil
    self.buf = nil
    self.visible = false
    self.current.signatures = nil
    self.current.active_sig = 1
    self.current.active_param = 0
end

function SignatureHelp:smart_refresh()
    if not self.visible then
        return
    end

    -- Get current context
    local context = self:detect_signature_context()
    
    -- Hide if no longer in signature context
    if not context.method_name then
        self:hide()
        return
    end

    -- Update active parameter
    local new_param = self:detect_active_parameter()
    if new_param ~= self.current.active_param then
        self.current.active_param = new_param
        self:refresh_display()
    end

    -- Update window position if following cursor
    if self.config.position.follow_cursor and not self.current.dock_mode then
        require('signup.window').update_window_position(self.win, self.config)
    end
end

-- Add to M table at the end
function M.trigger()
    if M._instance then
        M._instance:trigger()
    end
end

function M.hide()
    if M._instance then
        M._instance:hide()
    end
end

function M.toggle()
    if M._instance then
        if M._instance.visible then
            M._instance:hide()
        else
            M._instance:trigger()
        end
    end
end



function M.setup(opts)
    -- Create instance if it doesn't exist
    if not M._instance then
        -- Merge user config with defaults
        local config = vim.tbl_deep_extend("force", default_config, opts or {})
        
        -- Create new instance
        local instance = SignatureHelp.new()
        instance.config = config

        -- Setup highlights
        require('signup.highlights').setup_highlights(config.colors)

        -- Setup autocommands
        instance:setup_autocmds()
        
        -- Setup keymaps
        instance:setup_keymaps()

        -- Setup virtual text if enabled
        if config.features.virtual_text then
            instance:setup_virtual_text()
        end

        -- Store instance globally
        M._instance = instance
    end

    return M._instance
end



local function autoload(opts)
    if not M._instance then
        M.setup(opts)
    end
    return M._instance
end

-- Export methods with autoloading
function M.trigger(opts)
    return autoload(opts):trigger()
end

function M.hide(opts)
    return autoload(opts):hide()
end

function M.toggle(opts)
    local instance = autoload(opts)
    if instance.visible then
        instance:hide()
    else
        instance:trigger()
    end
end

return setmetatable(M, {
    __call = function(_, opts)
        return M.setup(opts)
    end
})