local api = vim.api
local utils = require('signup.utils')
local logger = require('signup.logger')
local window = require('signup.window')
local highlights = require('signup.highlights')
local docs = require('signup.docs')
local M = {}

-- SignatureHelp class
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

-- Default configuration
local default_config = {
    ui = {
        border = "rounded",
        max_width = 80,      -- Increased for better readability
        max_height = 10,     -- Increased for better visibility
        min_width = 40,
        padding = 1,
        spacing = 1,
        opacity = 0.9,       -- Increased for better visibility
        zindex = 50,
        wrap = true,         -- Added wrap option
        show_header = true,  -- Added option to show/hide header
    },
    parameter_indicators = {
        enabled = true,
        active_symbol = "●",
        inactive_symbol = "○",
        separator = " ",     -- Added separator option
    },
    highlights = {
        enabled = true,      -- Added master switch
        icons = true,
        parameters = true,
        indicators = true,
        header = true,       -- Added header highlight option
    },
    position = {
        prefer_above = true,
        padding = 1,
        avoid_cursor = true,
        follow_cursor = true, -- Added follow cursor option
    },
    colors = {
        background = nil,
        border = nil,
        parameter = "#86e1fc",
        text = nil,
        type = "#c099ff",
        method = "#4fd6be",
        documentation = "#4fd6be",
        default_value = "#a8a8a8",
        header = "#c099ff",  -- Added header color
    },
    active_parameter_colors = {
        fg = "#1a1a1a",
        bg = "#86e1fc",
        bold = true,         -- Added bold option
    },
    icons = {
        parameter = "󰘍 ",
        method = "󰡱 ",
        separator = " → ",
        header = "󰅲 ",      -- Added header icon
    },
    behavior = {
        auto_trigger = true,
        trigger_chars = { "(", ",", "<" },  -- Added < for generics
        close_on_done = true,
        dock_mode = false,
        dock_position = "bottom",
        debounce = 50,
        prefer_active = true,
        avoid_cmp_overlap = true,  -- Added option to avoid overlap with cmp
    },
    performance = {
        cache_size = 10,
        throttle = 30,
        gc_interval = 60 * 60,
        max_signature_length = 100, -- Added max signature length
    },
    keymaps = {
        toggle = "<A-k>",
        next_signature = "<C-j>",
        prev_signature = "<C-h>",
        next_parameter = "<C-l>",
        prev_parameter = "<C-h>",
        toggle_dock = "<Leader>sd",
        scroll_up = "<C-u>",    -- Added scroll keymaps
        scroll_down = "<C-d>",
    },
}

function SignatureHelp.new()
    local self = setmetatable({
        win = nil,
        buf = nil,
        dock_win = nil,
        dock_buf = nil,
        highlight_ns = vim.api.nvim_create_namespace("SignatureHelpHighlight"),
        last_context = nil,
        visible = false,
        config = vim.deepcopy(default_config),
        current = {
            signatures = nil,
            active_sig = 1,
            active_param = 0,
            dock_mode = false,
        },
        timers = {
            debounce = nil,
            throttle = nil,
            gc = nil,
        },
        enabled = false,
        last_active_parameter = nil,
        parameter_cache = {},
    }, SignatureHelp)

    return self
end



local function validate_window(self)
    return utils.is_valid_window(self.win)
end

local function validate_buffer(self)
    return utils.is_valid_buffer(self.buf)
end
-- Window Management Methods
-- function SignatureHelp:create_window(contents)
--     -- Create or reuse buffer
--     if not self.buf or not api.nvim_buf_is_valid(self.buf) then
--         self.buf = api.nvim_create_buf(false, true)
--         vim.bo[self.buf].buftype = "nofile"
--         vim.bo[self.buf].bufhidden = "hide"
--         vim.bo[self.buf].swapfile = false
--         vim.bo[self.buf].filetype = "SignatureHelp"
--     end

--     -- Calculate window dimensions
--     local width = math.min(math.max(#contents[1] + 4, self.config.ui.min_width), self.config.ui.max_width, vim.o.columns)
--     local height = math.min(#contents, self.config.ui.max_height)

--     -- Get window position and options
--     local pos = self:calculate_window_position()
--     local opts = self:get_window_opts(width, height)
--     opts.row = pos.row
--     opts.col = pos.col

--     -- Create or update window
--     if not self.win or not api.nvim_win_is_valid(self.win) then
--         self.win = api.nvim_open_win(self.buf, false, opts)

--         -- Set window options
--         local win_opts = {
--             wrap = true,
--             foldenable = false,
--             winblend = math.floor((1 - self.config.ui.opacity) * 100),
--             winhighlight = table.concat({
--                 "Normal:SignatureHelpNormal",
--                 "FloatBorder:SignatureHelpBorder",
--                 "CursorLine:SignatureHelpCursorLine",
--             }, ","),
--             signcolumn = "no",
--             cursorline = false,
--             number = false,
--             relativenumber = false,
--             linebreak = true,
--             breakindent = true,
--             showbreak = "↪ ",
--         }

--         for opt, val in pairs(win_opts) do
--             vim.wo[self.win][opt] = val
--         end
--     else
--         api.nvim_win_set_config(self.win, opts)
--     end

--     -- Set content and apply highlighting
--     api.nvim_buf_set_lines(self.buf, 0, -1, false, contents)
--     self:apply_highlights()

--     self.visible = true
--     return self.win, self.buf
-- end
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
function SignatureHelp:get_dock_window_opts(width, height)
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	local opts = {
		relative = "editor",
		width = width,
		height = height,
		style = "minimal",
		border = self.config.ui.border,
		zindex = self.config.ui.zindex,
	}

	-- Position based on dock mode configuration
	if self.config.behavior.dock_position == "bottom" then
		opts.row = editor_height - height - 4
		opts.col = editor_width - width - 2
	elseif self.config.behavior.dock_position == "top" then
		opts.row = 2
		opts.col = editor_width - width - 2
	else -- right
		opts.row = math.floor(editor_height / 2) - math.floor(height / 2)
		opts.col = editor_width - width - 2
	end

	return opts
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

function SignatureHelp:format_signature(signature, active_param)
	local parts = {}
	local params = signature.parameters or {}
	local label = signature.label

	-- Format method name
	local method_name = label:match("^([^(]+)")
	if method_name then
		table.insert(parts, self.config.icons.method .. method_name)
	end

	-- Format parameters
	local param_parts = {}
	for i, param in ipairs(params) do
		local param_text = param.label
		if i == active_param + 1 then
			param_text = string.format("<%s>", param_text)
		end
		table.insert(param_parts, param_text)
	end

	-- Combine all parts
	local full_signature = table.concat(parts, " ") .. "(" .. table.concat(param_parts, ", ") .. ")"

	-- Add documentation if available
	if signature.documentation then
		full_signature = full_signature .. "\n" .. signature.documentation
	end

	return full_signature
end

function SignatureHelp:apply_highlights()
	if not self.buf or not api.nvim_buf_is_valid(self.buf) then
		return
	end

	-- Clear existing highlights
	api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

	-- Get buffer content
	local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)

	-- Apply highlights for each line
	for i, line in ipairs(lines) do
		-- Highlight method name
		local method_start = line:find(self.config.icons.method)
		if method_start then
			local method_end = line:find("%(")
			if method_end then
				api.nvim_buf_add_highlight(self.buf, -1, "SignatureHelpMethod", i - 1, method_start - 1, method_end - 1)
			end
		end

		-- Highlight active parameter
		local active_param_start, active_param_end = line:find("<[^>]+>")
		if active_param_start then
			api.nvim_buf_add_highlight(
				self.buf,
				-1,
				"SignatureHelpParameter",
				i - 1,
				active_param_start - 1,
				active_param_end
			)
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

function SignatureHelp:trigger()
	-- Early return if not enabled
	if not self.enabled then
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
	if cmp_visible then
		if self.config and self.config.behavior and self.config.behavior.avoid_cmp_overlap then
			self:hide()
			return
		elseif self.config and self.config.behavior and self.config.behavior.dock_mode then
			-- Safely access dock mode configuration
			if type(self.config.behavior.dock_mode) == "table" then
				self.config.behavior.dock_mode.position = "bottom"
			end
		end
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
			vim.notify("No LSP clients available for signature help", vim.log.levels.DEBUG)
		end
		return
	end

	-- Find best client with signature help support
	local signature_client
	for _, client in ipairs(clients) do
		if client.server_capabilities.signatureHelpProvider then
			local trigger_chars = client.server_capabilities.signatureHelpProvider.triggerCharacters
			if trigger_chars and #trigger_chars > 0 then
				signature_client = client
				break
			end
		end
	end

	if not signature_client then
		if not self.config.silent then
			vim.notify("No LSP client with signature help capability", vim.log.levels.DEBUG)
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

	-- Create custom position parameters
	local position = {
		textDocument = {
			uri = uri,
		},
		position = {
			line = row - 1, -- LSP uses 0-based line numbers
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

	-- Make request with enhanced error handling
	vim.lsp.buf_request(bufnr, "textDocument/signatureHelp", position, function(err, result, ctx)
		-- Context validation
		if not ctx.bufnr or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
			return
		end

		-- Check for context changes with safe comparisons
		if ctx.bufnr ~= current_state.bufnr then
			return
		end

		local new_line = vim.api.nvim_get_current_line()
		local new_cursor = vim.api.nvim_win_get_cursor(0)

		-- Safe cursor position comparison
		if
			new_line ~= current_state.line
			or new_cursor[1] ~= current_state.row
			or (new_cursor[2] and current_state.col and math.abs(new_cursor[2] - current_state.col) > 1)
		then
			return
		end

		-- Error handling
		if err then
			if not self.config.silent then
				vim.notify("Signature help error: " .. tostring(err), vim.log.levels.WARN)
			end
			return
		end

		-- Result validation
		if not result or not result.signatures or vim.tbl_isempty(result.signatures) then
			if self.visible then
				self:hide()
			end
			return
		end

		-- Process signature information with nil checks
		local active_sig_idx = result.activeSignature or 0
		local sig = result.signatures[active_sig_idx + 1]

		if sig then
			-- Enhanced caching with timestamp and nil checks
			self.parameter_cache[sig.label] = {
				count = (sig.parameters and #sig.parameters) or 0,
				active = result.activeParameter or 0, -- Ensure default value
				timestamp = vim.loop.now(),
				signature = sig,
				bufnr = ctx.bufnr,
			}

			-- Manage cache size with safe iteration
			--
			self:manage_cache()
		end

		-- Update state with safe assignment
		self.last_active_parameter = result.activeParameter or 0
		self:smart_refresh()

		-- Display with debouncing and safe access
		local debounce_time = self.config.performance and self.config.performance.debounce_time or 0

		if debounce_time > 0 then
			if self.display_timer then
				pcall(vim.fn.timer_stop, self.display_timer)
			end
			self.display_timer = vim.fn.timer_start(debounce_time, function()
				self:display(result)
			end)
		else
			self:display(result)
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

function SignatureHelp:setup_autocmds()
	local group = api.nvim_create_augroup("LspSignatureHelp", { clear = true })

	

	api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
		group = group,
		callback = function()
			local cmp_visible = require("cmp").visible()
			if cmp_visible then
				self:hide()
			elseif vim.fn.pumvisible() == 0 then
				utils.debounced_trigger(function() self:trigger() end)
			else
				self:hide()
			end
		end,
	})

	api.nvim_create_autocmd({ "CursorMoved" }, {
		group = group,
		callback = function()
			if self.normal_mode_active then
				utils.debounced_trigger(function() self:trigger() end)
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

function SignatureHelp:display(result)
	if not result or not result.signatures or #result.signatures == 0 then
		self:hide()
		return
	end

	-- Safe signature comparison
	if self.visible and self.current_signatures then
		local current_sig = self.current_signatures[self.current_signature_idx or 1]
		local new_sig = result.signatures[result.activeSignature or 0]
		local current_param = self.last_active_parameter or 0
		local new_param = result.activeParameter or 0

		if current_sig and new_sig and current_sig.label == new_sig.label and current_param == new_param then
			return
		end
	end

	-- Store current signatures with safe values
	self.current_signatures = result.signatures
	self.current_active_parameter = result.activeParameter or 0
	self.current_signature_idx = (result.activeSignature and result.activeSignature + 1) or 1

	-- Safely convert to markdown and get labels
	local ok, contents, labels = pcall(self.format_signature_list, self, result.signatures)
	if not ok or not contents then
		vim.notify("Error formatting signature: " .. (contents or "unknown error"), vim.log.levels.ERROR)
		return
	end

	if #contents > 0 then
		if self.config.behavior and self.config.behavior.dock_mode then
			local win, buf = self:create_dock_window()
			if win and buf then
				-- Set content with error handling
				pcall(api.nvim_buf_set_lines, buf, 0, -1, false, contents)
				pcall(vim.lsp.util.stylize_markdown, buf, contents, {})
				pcall(self.set_dock_parameter_highlights, self, result.activeParameter or 0, result.signatures)
				self.visible = true
				-- Add parameter indicators after window creation
				if self.config.parameter_indicators.enabled then
					self:add_parameter_indicators()
				end
			end
		else
			local win, buf = self:create_window(contents)
			if win and buf then
				pcall(
					self.set_active_parameter_highlights,
					self,
					result.activeParameter or 0,
					result.signatures,
					labels
				)
				-- Add parameter indicators after window creation
				if self.config.parameter_indicators.enabled then
					self:add_parameter_indicators()
				end
			end
		end
	end
end


-- function SignatureHelp:format_signature_list(signatures)
--     if not signatures or type(signatures) ~= "table" then
--         return {}, {}
--     end

--     local contents = {}
--     local labels = {}

--     local show_index = #signatures > 1

--     for idx, signature in ipairs(signatures) do
--         if type(signature) == "table" then
--             table.insert(labels, #contents + 1)

--             -- Safely format the signature line
--             local ok, sig_lines = pcall(self.format_signature_line, self, signature, idx, show_index)
--             if ok and sig_lines then
--                 -- Add each line of the signature
--                 for _, line in ipairs(sig_lines) do
--                     table.insert(contents, line)
--                 end

--                 -- Add documentation if available
--                 if signature.documentation then
--                     local doc = type(signature.documentation) == "string" and signature.documentation
--                         or (signature.documentation.value or "")

--                     if doc and doc:match("%S") then
--                         -- Add separator
--                         table.insert(contents, string.rep("─", 40))
--                         -- Add documentation with icon
--                         table.insert(contents, self.config.icons.method .. " Documentation:")
--                         -- Split and add documentation lines
--                         for _, line in ipairs(vim.split(doc, "\n")) do
--                             if line:match("%S") then
--                                 table.insert(contents, "  " .. line)
--                             end
--                         end
--                     end
--                 end

--                 -- Add separator between signatures
--                 if idx < #signatures then
--                     table.insert(contents, string.rep("═", 40))
--                 end
--             end
--         end
--     end

--     -- Remove trailing empty lines
--     while #contents > 0 and not contents[#contents]:match("%S") do
--         table.remove(contents)
--     end

--     return contents, labels
-- end
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

            -- Safely format the signature line
            local ok, sig_lines = pcall(self.format_signature_line, self, signature, idx, show_index)
            if ok and sig_lines then
                -- Add each line of the signature
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
function SignatureHelp:format_signature_line(signature, index, show_index)
    local parts = {}
    local max_width = self.config.ui.max_width - 4  -- Account for padding

    -- Add method icon and name
    local method_name = signature.label:match("^([^(]+)")
    if method_name then
        table.insert(parts, self.config.icons.method .. method_name)
    end

    -- Format parameters safely
    local param_parts = {}
    local params = signature.parameters or {}
    local active_param = signature.activeParameter or 0

    for i, param in ipairs(params) do
        -- Handle different parameter label formats
        local param_text = ""
        if type(param.label) == "string" then
            param_text = param.label
        elseif type(param.label) == "table" then
            if param.label[1] and param.label[2] then
                param_text = signature.label:sub(param.label[1] + 1, param.label[2])
            end
        end

        -- Add parameter formatting
        if i == active_param + 1 then
            param_text = string.format("<%s>", param_text)
        end

        if param_text ~= "" then
            table.insert(param_parts, param_text)
        end
    end

    -- Safely combine parts
    local method_part = table.concat(parts, " ")
    local params_part = table.concat(param_parts, ", ")
    local sig_line = method_part .. "(" .. params_part .. ")"

    -- Add index if showing multiple signatures
    if show_index then
        sig_line = sig_line .. string.format(" (%d/%d)", index, #params)
    end

    -- Split long lines into multiple lines
    local lines = {}
    if #sig_line > max_width then
        local current_line = ""
        local words = vim.split(sig_line, " ")
        
        for _, word in ipairs(words) do
            if #current_line + #word + 1 <= max_width then
                current_line = current_line == "" and word or current_line .. " " .. word
            else
                table.insert(lines, current_line)
                current_line = "    " .. word  -- Add indentation for wrapped lines
            end
        end
        if current_line ~= "" then
            table.insert(lines, current_line)
        end
    else
        lines = {sig_line}
    end

    return lines
end
function SignatureHelp:calculate_window_position()
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local screen_pos = vim.fn.screenpos(0, cursor_pos[1], cursor_pos[2])
	local editor_height = vim.o.lines
	local editor_width = vim.o.columns

	-- Calculate preferred position
	local preferred_row = screen_pos.row - 2 -- Above cursor
	local preferred_col = screen_pos.col

	-- Adjust for screen boundaries
	if preferred_row < 2 then
		preferred_row = screen_pos.row + 1 -- Below cursor
	end

	if preferred_col + self.config.ui.max_width > editor_width then
		preferred_col = editor_width - self.config.ui.max_width - 2
	end

	return {
		row = preferred_row,
		col = preferred_col,
	}
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
function SignatureHelp:calculate_dock_position()
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local dock_position = self.config.behavior.dock_position
	local padding = self.config.ui.padding

	-- Calculate dimensions
	local width =
		math.min(math.max(40, self.config.ui.min_width), self.config.ui.max_width, editor_width - (padding * 2))
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

function SignatureHelp:set_dock_parameter_highlights(active_parameter, signatures)
	if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
		return
	end

	-- Clear existing highlights
	api.nvim_buf_clear_namespace(self.dock_buf, -1, 0, -1)

	-- Get current signature
	local signature = signatures[self.current_signature_idx or 1]
	if not signature then
		return
	end

	-- Get parameters
	local params = signature.parameters or {}
	if active_parameter and params[active_parameter + 1] then
		local param = params[active_parameter + 1]
		local label = type(param.label) == "table" and param.label or { param.label }

		-- Get first line content
		local lines = api.nvim_buf_get_lines(self.dock_buf, 0, 1, false)
		if #lines == 0 then
			return
		end

		local line = lines[1]
		local start_pos, end_pos

		if type(label) == "table" then
			start_pos = label[1]
			end_pos = label[2]
		else
			-- Find parameter in line
			local escaped_label = vim.pesc(label)
			start_pos = line:find(escaped_label)
			if start_pos then
				end_pos = start_pos + #label - 1
			end
		end

		-- Apply highlight
		if start_pos and end_pos then
			api.nvim_buf_add_highlight(self.dock_buf, -1, "SignatureHelpParameter", 0, start_pos - 1, end_pos)
		end
	end

	-- Add icon highlights
	self:highlight_icons(self.dock_buf)
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
function SignatureHelp:highlight_active_parameter(buf, signature, active_param)
	if not signature or not signature.parameters then
		return
	end

	-- Clear existing highlights
	vim.api.nvim_buf_clear_namespace(buf, self.highlight_ns, 0, -1)

	local param = signature.parameters[active_param + 1]
	if not param then
		return
	end

	-- Get parameter range
	local start_pos, end_pos
	if type(param.label) == "table" then
		start_pos = param.label[1]
		end_pos = param.label[2]
	else
		local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]
		start_pos = content:find(vim.pesc(param.label))
		if start_pos then
			end_pos = start_pos + #param.label - 1
		end
	end

	-- Apply highlight
	if start_pos and end_pos then
		vim.api.nvim_buf_add_highlight(buf, self.highlight_ns, "LspSignatureActiveParameter", 0, start_pos - 1, end_pos)
	end
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
	local buf = self.config.behavior.dock_mode and self.dock_buf or self.buf
	if not buf or not api.nvim_buf_is_valid(buf) then
		return
	end

	local indicators = {}
	for i = 1, #sig.parameters do
		if i == self.current_active_parameter + 1 then
			table.insert(indicators, self.config.parameter_indicators.active_symbol or "●")
		else
			table.insert(indicators, self.config.parameter_indicators.inactive_symbol or "○")
		end
	end

	-- Add indicators to the window
	if #indicators > 0 then
		local indicator_line = table.concat(indicators, " ")
		-- Use pcall to handle potential errors
		pcall(vim.api.nvim_buf_set_lines, buf, -1, -1, false, { string.rep("─", #indicator_line), indicator_line })
	end
end
function SignatureHelp:toggle_normal_mode()
	self.normal_mode_active = not self.normal_mode_active
	if self.normal_mode_active then
		-- Close dock window if it exists when entering normal mode
		if self.config.behavior.dock_mode then
			self:close_dock_window()
			-- Temporarily disable dock mode
			local was_dock_enabled = self.config.behavior.dock_mode
			self.config.behavior.dock_mode = false
			self:trigger()
			self.config.behavior.dock_mode = was_dock_enabled
		else
			self:trigger()
		end
	else
		self:hide()
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

-- function SignatureHelp:setup_highlights()
-- 	local colors = self.config.colors
-- 	local active_colors = self.config.active_parameter_colors

-- 	-- Ensure we have default values if not provided
-- 	active_colors = active_colors or {
-- 		fg = "#1a1a1a",
-- 		bg = "#86e1fc",
-- 	}

-- 	local highlights = {
-- 		SignatureHelpDock = { link = "NormalFloat" },
-- 		SignatureHelpBorder = { link = "FloatBorder" },
-- 		SignatureHelpMethod = { fg = colors.method },
-- 		SignatureHelpParameter = { fg = colors.parameter },
-- 		SignatureHelpDocumentation = { fg = colors.documentation },
-- 		SignatureHelpDefaultValue = { fg = colors.default_value, italic = true },
-- 		SignatureHelpMethodIcon = { fg = colors.method, bold = true },
-- 		SignatureHelpParamIcon = { fg = colors.parameter, bold = true },
-- 		LspSignatureActiveParameter = {
-- 			fg = active_colors.fg,
-- 			bg = active_colors.bg,
-- 			bold = true,
-- 		},
-- 		SignatureHelpIndicator = { fg = colors.method },
-- 		SignatureHelpIndicatorActive = {
-- 			fg = colors.parameter,
-- 			bold = true,
-- 		},
-- 	}

-- 	for group, hl_opts in pairs(highlights) do
-- 		vim.api.nvim_set_hl(0, group, hl_opts)
-- 	end
-- end
function SignatureHelp:setup_highlights()
    highlights.setup_highlights(self.config.colors)
end
-- Add parameter navigation
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

-- Add cleanup function
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


-- Add health check function
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

-- Add better cache management
function SignatureHelp:manage_cache()
	local now = vim.loop.now()
	local max_age = self.config.performance.cache_timeout or (60 * 1000) -- 1 minute default

	for k, v in pairs(self.parameter_cache) do
		if (now - v.timestamp) > max_age then
			self.parameter_cache[k] = nil
		end
	end
end

-- -- Add window position adjustment for multi-monitor setups
-- function SignatureHelp:adjust_window_position(opts)
-- 	local screen_pos = vim.fn.screenpos(0, opts.row or 1, opts.col or 0)
-- 	if screen_pos.row < 1 then
-- 		opts.row = opts.row + math.abs(screen_pos.row) + 1
-- 	end
-- 	if screen_pos.col < 1 then
-- 		opts.col = opts.col + math.abs(screen_pos.col) + 1
-- 	end
-- 	return opts
-- end

-- Setup function
function M.setup(opts)
	-- Prevent multiple initializations
	if M._initialized then
		logger.warn("signup.nvim already initialized")
		return M._instance
	end
	return utils.safe_call(function ()
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

-- Add reload method for plugin reloading
function M.reload()
	if M._instance then
		M._instance:cleanup()
	end

	M._initialized = false
	M._instance = nil

	package.loaded["signup"] = nil
	return require("signup").setup()
end

-- Add version and metadata
M.version = "1.0.0"
M.dependencies = {
	"nvim-treesitter/nvim-treesitter", -- Optional, for better syntax highlighting
}

return M
