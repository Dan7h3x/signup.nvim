local api = vim.api
local utils = require("signup.utils")
local logger = require("signup.logger")
local window = require("signup.window")
local highlights = require("signup.highlights")
local docs = require("signup.docs")
local M = {}



-- Default configuration with better organization and documentation
local default_config = {
    ui = {
        border = "rounded",
        max_width = 80,      -- Maximum width of the floating window
        max_height = 10,     -- Maximum height of the floating window
        min_width = 40,      -- Minimum width to maintain readability
        padding = 1,         -- Padding around the content
        spacing = 1,         -- Spacing between signature elements
        opacity = 0.9,       -- Window opacity (1 = solid, 0 = transparent)
        zindex = 50,         -- Z-index for floating window
        wrap = true,         -- Enable text wrapping
        show_header = true,  -- Show signature header
    },
    parameter_indicators = {
        enabled = true,          -- Show parameter position indicators
        active_symbol = "●",     -- Symbol for active parameter
        inactive_symbol = "○",   -- Symbol for inactive parameters
        separator = " ",         -- Separator between indicators
    },
    highlights = {
        enabled = true,      -- Enable custom highlighting
        icons = true,        -- Highlight icons
        parameters = true,   -- Highlight parameters
        indicators = true,   -- Highlight indicators
        header = true,       -- Highlight header
    },
    position = {
        prefer_above = true,     -- Prefer window above cursor
        padding = 1,             -- Padding from cursor
        avoid_cursor = true,     -- Avoid cursor position
        follow_cursor = true,    -- Move window with cursor
    },
    colors = {
        background = nil,        -- Background color (nil = use default)
        border = nil,           -- Border color
        parameter = "#86e1fc",  -- Parameter highlight color
        text = nil,             -- Text color
        type = "#c099ff",       -- Type highlight color
        method = "#4fd6be",     -- Method highlight color
        documentation = "#4fd6be", -- Documentation text color
        default_value = "#a8a8a8", -- Default value color
        header = "#c099ff",     -- Header color
        active_parameter_colors = {
            fg = "#1a1a1a",     -- Active parameter foreground
            bg = "#86e1fc",     -- Active parameter background
            bold = true,        -- Bold active parameter
        },
    },
    icons = {
        parameter = "󰘍 ",      -- Parameter icon
        method = "󰡱 ",         -- Method icon
        separator = " → ",      -- Separator icon
        header = "󰅲 ",         -- Header icon
    },
    behavior = {
        auto_trigger = true,                -- Auto trigger on typing
        trigger_chars = { "(", ",", "<" },  -- Characters that trigger signature
        close_on_done = true,               -- Close when done typing
        dock_mode = false,                  -- Enable dock mode
        dock_position = "bottom",           -- Dock position (bottom/top/right)
        debounce = 50,                      -- Debounce time in ms
        prefer_active = true,               -- Prefer active signature
        avoid_cmp_overlap = true,           -- Avoid overlap with completion
    },
    performance = {
        cache_size = 10,                    -- Size of signature cache
        throttle = 30,                      -- Throttle time in ms
        gc_interval = 60 * 60,              -- Garbage collection interval
        max_signature_length = 100,         -- Max signature length
    },
    keymaps = {
        toggle = "<A-k>",                   -- Toggle signature help
        next_signature = "<C-j>",           -- Next signature
        prev_signature = "<C-h>",           -- Previous signature
        next_parameter = "<C-l>",           -- Next parameter
        prev_parameter = "<C-h>",           -- Previous parameter
        toggle_dock = "<Leader>sd",         -- Toggle dock mode
        scroll_up = "<C-u>",                -- Scroll documentation up
        scroll_down = "<C-d>",              -- Scroll documentation down
    },
}
-- SignatureHelp class
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
    local self = setmetatable({
        -- Window management
        win = nil,               -- Main window handle
        buf = nil,               -- Main buffer handle
        dock_win = nil,          -- Dock window handle
        dock_buf = nil,          -- Dock buffer handle
        
        -- State management
        highlight_ns = vim.api.nvim_create_namespace("SignatureHelpHighlight"),
        last_context = nil,      -- Last signature context
        visible = false,         -- Window visibility state
        config = vim.deepcopy(default_config),
        
        -- Current signature state
        current = {
            signatures = nil,    -- Current signatures
            active_sig = 1,      -- Active signature index
            active_param = 0,    -- Active parameter index
            dock_mode = false,   -- Dock mode state
        },
        
        -- Performance management
        timers = {
            debounce = nil,      -- Debounce timer
            throttle = nil,      -- Throttle timer
            gc = nil,            -- Garbage collection timer
        },
        
        -- Feature flags
        enabled = false,         -- LSP capability enabled
        normal_mode_active = false, -- Normal mode state
        
        -- Cache management
        last_active_parameter = nil,
        parameter_cache = {},    -- Parameter cache
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

    if new_line ~= old_state.line 
        or new_cursor[1] ~= old_state.row 
        or math.abs((new_cursor[2] or 0) - (old_state.col or 0)) > 1 then
        return false
    end

    return true
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
            linebreak = true,  -- Enable smart line breaks
            breakindent = true, -- Preserve indentation on wrapped lines
            showbreak = "↪ ",  -- Show break indicator
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
            api.nvim_buf_add_highlight(
                self.buf,
                self.highlight_ns,
                "SignatureHelpDocumentation",
                i - 1,
                0,
                -1
            )
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
        api.nvim_buf_add_highlight(
            buf,
            self.highlight_ns,
            "SignatureHelpActiveParameter",
            0,
            start_pos - 1,
            end_pos
        )
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
                    local doc_lines = docs.format_documentation(signature.documentation, self.config)
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
            indicator_line
        })
    end
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
        logger.error("Error formatting signature: " .. (contents or "unknown error"))
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

    return current_sig 
        and new_sig 
        and current_sig.label == new_sig.label 
        and current_param == new_param
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
        pcall(self.set_active_parameter_highlights, self,
            result.activeParameter or 0,
            result.signatures,
            labels
        )
        
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

function SignatureHelp:hide()
    if self.visible then
        -- Store current window and buffer
        local current_win = api.nvim_get_current_win()
        local current_buf = api.nvim_get_current_buf()

        -- Close appropriate window based on mode
        if self.config.behavior.dock_mode then
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

function SignatureHelp:smart_refresh()
    -- Check if we need to refresh based on context
    local context = self:detect_signature_context()
    local current_param = self:detect_active_parameter()

    if self.last_context then
        if context.method_name ~= self.last_context.method_name or current_param ~= self.last_active_parameter then
            self:trigger()
        end
    end

    self.last_context = context
    self.last_active_parameter = current_param
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

-- Setup and Initialization
function SignatureHelp:setup_keymaps()
    -- Setup toggle keys using the actual config
    local toggle_key = self.config.keymaps.toggle
    local dock_toggle_key = self.config.keymaps.toggle_dock

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

function SignatureHelp:setup_autocmds()
    local group = api.nvim_create_augroup("LspSignatureHelp", { clear = true })

    api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
        group = group,
        callback = function()
            local cmp_visible = require("cmp").visible()
            if cmp_visible then
                self:hide()
            elseif vim.fn.pumvisible() == 0 then
                utils.debounce(function()
                    self:trigger()
                end)
            else
                self:hide()
            end
        end,
    })

    api.nvim_create_autocmd({ "CursorMoved" }, {
        group = group,
        callback = function()
            if self.normal_mode_active then
                utils.debounce(function()
                    self:trigger()
                end)
            end
        end,
    })
    api.nvim_create_autocmd({ "CursorMovedI" }, {
        group = group,
        callback = function()
            if self.visible then
                self:update_active_parameter()
            end
        end,
    })

    api.nvim_create_autocmd({ "InsertLeave", "BufHidden", "BufLeave" }, {
        group = group,
        callback = function()
            self:hide()
            self.normal_mode_active = false
        end,
    })

    api.nvim_create_autocmd("LspAttach", {
        group = group,
        callback = function()
            vim.defer_fn(function()
                self:check_capability()
            end, 100)
        end,
    })

    api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            if self.visible then
                self:apply_treesitter_highlighting()
                self:set_active_parameter_highlights(
                    self.current_signatures.activeParameter,
                    self.current_signatures,
                    {}
                )
            end
        end,
    })
end

function SignatureHelp:setup_dock_autocmds()
    if not self.dock_autocmd_group then
        self.dock_autocmd_group = api.nvim_create_augroup("SignatureHelpDock", { clear = true })
    end

    api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = self.dock_autocmd_group,
        callback = function()
            if self.visible and self.config.behavior.dock_mode then
                local dock_config = self:calculate_dock_position()
                if self.dock_win and api.nvim_win_is_valid(self.dock_win) then
                    api.nvim_win_set_config(self.dock_win, dock_config)
                end
            end
        end,
    })
end


-- LSP Integration and Trigger Logic
function SignatureHelp:trigger()
    -- Early return if not enabled
    if not self.enabled or vim.api.nvim_get_mode().mode:sub(1,1) ~= 'i' then
        logger.debug("SignatureHelp not enabled")
        return
    end

    -- Define trigger kinds
    local TriggerKind = {
        Invoked = 1,
        TriggerCharacter = 2,
        ContentChange = 3,
    }

    -- Check for cmp visibility with better error handling
    local cmp_ok, cmp = pcall(require, "cmp")
    local cmp_visible = cmp_ok and cmp.visible() or false
    self.cmp_visible_cache = cmp_visible

    -- Enhanced CMP overlap handling
    if cmp_visible and self.config.behavior.avoid_cmp_overlap then
        self:hide()
        return
    end

    -- Get current buffer and position
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1], cursor[2]

    -- Get buffer URI
    local uri = vim.uri_from_bufnr(bufnr)
    if not uri then
        return
    end

    -- Get active clients with capability checking
    local clients = vim.lsp.get_clients({
        bufnr = bufnr,
        method = "textDocument/signatureHelp",
    })

    if not clients or #clients == 0 then
        if not self.config.silent then
            logger.debug("No LSP clients available for signature help")
        end
        return
    end

    -- Find best client with signature help support
    local signature_client
    for _, client in ipairs(clients) do
        if client.server_capabilities.signatureHelpProvider then
            signature_client = client
            break
        end
    end

    if not signature_client then
        if not self.config.silent then
            logger.debug("No LSP client with signature help capability")
        end
        return
    end

    -- Get current line context
    local line = vim.api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, col)
    local trigger_char = line_to_cursor:sub(-1)

    -- Check trigger character validity
    local valid_trigger = false
    local trigger_chars = signature_client.server_capabilities.signatureHelpProvider.triggerCharacters or {}
    for _, char in ipairs(trigger_chars) do
        if trigger_char == char then
            valid_trigger = true
            break
        end
    end

    -- Detect parameter position
    local detected_param = self:detect_active_parameter()
    local retrigger = self.visible and self.last_active_parameter ~= detected_param

    -- Create LSP position parameters
    local params = {
        textDocument = { uri = uri },
        position = {
            line = row - 1,
            character = col,
        },
        context = {
            triggerKind = valid_trigger and TriggerKind.TriggerCharacter or TriggerKind.ContentChange,
            triggerCharacter = valid_trigger and trigger_char or nil,
            isRetrigger = retrigger,
            activeParameter = detected_param,
        },
    }

    -- Cache current state
    local current_state = {
        line = line,
        row = row,
        col = col,
        parameter = detected_param,
        bufnr = bufnr,
    }

    -- Make LSP request with debouncing
    utils.debounce(function()
        vim.lsp.buf_request(bufnr, "textDocument/signatureHelp", params, function(err, result, ctx)
            if not ctx.bufnr or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
                return
            end

            -- Validate context hasn't changed significantly
            if not self:validate_context(current_state, ctx) then
                return
            end

            if err then
                logger.debug("Signature help error: " .. tostring(err))
                return
            end

            if not result or not result.signatures or vim.tbl_isempty(result.signatures) then
                if self.visible then
                    self:hide()
                end
                return
            end

            self:process_signature_result(result)
        end)
    end, self.config.behavior.debounce or 50)
end

-- Plugin Setup and Configuration
function M.setup(opts)
    -- Prevent multiple initializations
    if M._initialized then
        logger.warn("signup.nvim already initialized")
        return M._instance
    end
    return utils.safe_call(function()
        opts = opts or {}
        if type(opts) ~= "table" then
            error("Configuration must be a table")
        end
        -- Create new instance
        local instance = SignatureHelp.new()
        instance.config.behavior = vim.tbl_deep_extend("force", {
            avoid_cmp_overlap = true,
            dock_mode = false,
            auto_trigger = true,
            trigger_chars = { "(", "," },
            close_on_done = true,
            dock_position = "bottom",
            debounce = 50,
            prefer_active = true,
        }, opts.behavior or {})
        -- Merge configurations
        instance.config = vim.tbl_deep_extend("force", instance.config, opts)

        local setup_ok, setup_err = pcall(function()
            instance:setup_highlights()
            instance:setup_autocmds()
            instance:setup_keymaps()
            instance:setup_dock_autocmds()
        end)

        if not setup_ok then
            vim.notify("Failed to setup signup.nvim: " .. tostring(setup_err), vim.log.levels.ERROR)
            return nil
        end

        -- Setup cleanup on exit
        vim.api.nvim_create_autocmd("VimLeavePre", {
            callback = function()
                if M._instance then
                    M._instance:cleanup()
                end
            end,
        })
        -- Store instance
        M._initialized = true
        M._instance = instance

        return instance
    end)
end

-- Configuration Update
function M.update(opts)
    if not M._instance then
        return M.setup(opts)
    end

    -- Merge new options with existing config
    local instance = M._instance
    local function update_config(base, new)
        for k, v in pairs(new) do
            if type(v) == "table" and type(base[k]) == "table" then
                update_config(base[k], v)
            else
                base[k] = v
            end
        end
    end

    -- Safely update configuration
    pcall(update_config, instance.config, opts or {})

    -- Refresh highlights and windows
    pcall(function()
        instance:setup_highlights()
        if instance.visible then
            -- Refresh current display
            instance:display({
                signatures = instance.current_signatures,
                activeParameter = instance.current_active_parameter,
                activeSignature = instance.current_signature_idx and (instance.current_signature_idx - 1) or 0,
            })
        end
    end)

    return instance
end

-- Health Check
function M.health()
    local health = require("health")
    health.report_start("signup.nvim")

    -- Check Neovim version
    if vim.fn.has("nvim-0.7.0") == 1 then
        health.report_ok("Using Neovim >= 0.7.0")
    else
        health.report_error("Neovim >= 0.7.0 is required")
    end

    -- Check for LSP
    if #vim.lsp.get_clients() > 0 then
        health.report_ok("LSP client(s) attached")
    else
        health.report_warn("No LSP clients attached")
    end

    -- Check for optional dependencies
    if pcall(require, "nvim-treesitter") then
        health.report_ok("nvim-treesitter is installed")
    else
        health.report_info("nvim-treesitter is not installed (optional)")
    end
end

-- Plugin Cleanup
function SignatureHelp:cleanup()
    if self.timers.debounce then
        vim.fn.timer_stop(self.timers.debounce)
    end
    if self.timers.throttle then
        vim.fn.timer_stop(self.timers.throttle)
    end
    if self.timers.gc then
        vim.fn.timer_stop(self.timers.gc)
    end

    self:hide()

    -- Clear all autocommands
    if self.dock_autocmd_group then
        pcall(api.nvim_del_augroup_by_id, self.dock_autocmd_group)
    end
end

-- API Methods
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

M.next_signature = function()
    if M._instance then
        M._instance:next_signature()
    end
end

M.prev_signature = function()
    if M._instance then
        M._instance:prev_signature()
    end
end

-- Add version and metadata
M.version = "1.0.0"
M.dependencies = {
    "nvim-treesitter/nvim-treesitter", -- Optional, for better syntax highlighting
}

return M