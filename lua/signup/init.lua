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
		last_active_parameter = nil,
		parameter_cache = {},
		cmp_visible_cache = false,
		debounce_cache = {},
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
		avoid_cmp_overlap = true, -- Avoid showing signature when cmp is visible
		parameter_detection = {
			enabled = true, -- Enable dynamic parameter detection
			trigger_on_comma = true, -- Trigger signature help on comma
		},
		performance = {
			debounce_time = 30, -- Debounce time for signature updates
			cache_size = 10, -- Size of parameter cache
		},
		dock_mode = {
			enabled = false,
			position = "bottom",
			height = 3,
			width = 40,
			padding = 1,
			auto_adjust = true,
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
		return "(" .. index .. ")"
	end
end

local function markdown_for_signature_list(signatures, config)
	-- Convert signatures to markdown using LSP utilities
	local contents = {}
	local labels = {}
	local number = config.number and #signatures > 1

	for index, signature in ipairs(signatures) do
		table.insert(labels, #contents + 1)

		-- Convert signature to markdown lines
		local markdown_lines, active_param_range = vim.lsp.util.convert_signature_help_to_markdown_lines({
			activeSignature = index - 1,
			activeParameter = signature.activeParameter,
			signatures = { signature },
		}, vim.bo.filetype, config.trigger_chars)

		-- Add method icon and suffix inline with first line
		local suffix = number and (" " .. signature_index_comment(index)) or ""
		markdown_lines[1] = string.format("%s %s%s", config.icons.method, markdown_lines[1], suffix)

		-- Add signature lines (filtering empty lines)
		for _, line in ipairs(markdown_lines) do
			if line:match("%S") then -- Only add non-empty lines
				table.insert(contents, line)
			end
		end

		-- Documentation section (if exists and not empty)
		if signature.documentation then
			local doc_lines = vim.lsp.util.convert_input_to_markdown_lines(signature.documentation)
			local has_content = false

			-- Check if documentation has any non-empty content
			for _, line in ipairs(doc_lines) do
				if line:match("%S") then
					has_content = true
					break
				end
			end

			if has_content then
				if config.render_style.separator then
					table.insert(contents, string.rep("─", 40))
				end
				table.insert(
					contents,
					string.format("%s %s", config.icons.documentation, doc_lines[1] or "Documentation")
				)

				-- Add remaining doc lines, skipping empty ones
				for i = 2, #doc_lines do
					if doc_lines[i]:match("%S") then
						table.insert(contents, "  " .. doc_lines[i])
					end
				end
			end
		end

		-- Add separator between signatures if needed
		if index ~= #signatures and config.render_style.separator then
			table.insert(contents, string.rep("═", 40))
		end
	end

	-- Remove any trailing empty lines
	while #contents > 0 and not contents[#contents]:match("%S") do
		table.remove(contents)
	end

	return contents, labels
end

local function create_window(self, buf, opts)
	if not buf or not api.nvim_buf_is_valid(buf) then
		buf = api.nvim_create_buf(false, true)
	end

	local win = api.nvim_open_win(buf, false, opts)
	api.nvim_win_set_option(win, "wrap", true)
	api.nvim_win_set_option(win, "winblend", self.config.winblend)
	return win, buf
end

function SignatureHelp:detect_active_parameter()
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_get_current_line()
	local line_to_cursor = line:sub(1, cursor_pos[2])

	-- Count parentheses and commas
	local open_count = 0
	local param_index = 0

	for i = 1, #line_to_cursor do
		local char = line_to_cursor:sub(i, i)
		if char == "(" then
			open_count = open_count + 1
		elseif char == ")" then
			open_count = open_count - 1
		elseif char == "," and open_count == 1 then
			param_index = param_index + 1
		end
	end

	return open_count > 0 and param_index or nil
end
function SignatureHelp:create_float_window(contents)
	local opts = {
		relative = "cursor",
		row = self.config.floating_window_above_cur_line and -2 or 1,
		col = 0,
		width = math.min(self.config.max_width, vim.o.columns),
		height = math.min(self.config.max_height, #contents),
		style = "minimal",
		border = self.config.border,
		zindex = 50,
		focusable = true, -- Make window focusable
		focus = false, -- Don't focus by default
		anchor_bias = self.config.floating_window_above_cur_line and "above" or "below",
		close_events = { "CursorMoved", "BufHidden", "InsertLeave" },
	}

	return create_window(self, self.buf, opts)
	-- Use LSP util for better floating window management
	-- local bufnr, winid = vim.lsp.util.open_floating_preview(contents, "markdown", opts)
	--
	-- self.buf = bufnr
	-- self.win = winid
	-- self.visible = true
	--
	-- -- Apply window options
	-- api.nvim_win_set_option(self.win, "foldenable", false)
	-- api.nvim_win_set_option(self.win, "wrap", true)
	-- api.nvim_win_set_option(self.win, "winblend", self.config.winblend)
	--
	-- return bufnr, winid
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
				api.nvim_win_close(self.win, true)
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

	if not start_pos then
		return nil, nil
	end

	local end_pos = start_pos + #parameter_label - 1
	return start_pos, end_pos
end

function SignatureHelp:extract_default_value(param_info)
	-- Check if parameter has documentation that might contain default value
	if not param_info.documentation then
		return nil
	end

	local doc = type(param_info.documentation) == "string" and param_info.documentation
		or param_info.documentation.value

	-- Look for common default value patterns
	local patterns = {
		"default:%s*([^%s]+)",
		"defaults%s+to%s+([^%s]+)",
		"%(default:%s*([^%)]+)%)",
	}

	for _, pattern in ipairs(patterns) do
		local default = doc:match(pattern)
		if default then
			return default
		end
	end

	return nil
end

function SignatureHelp:set_active_parameter_highlights(active_parameter, signatures, labels)
	if not self.buf or not api.nvim_buf_is_valid(self.buf) then
		return
	end

	-- Clear existing highlights
	api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)

	-- Iterate over signatures to highlight the active parameter
	for index, signature in ipairs(signatures) do
		local parameter = signature.activeParameter or active_parameter
		if parameter and parameter >= 0 and parameter < #signature.parameters then
			-- Convert signature help to markdown to get parameter ranges
			local _, param_range = vim.lsp.util.convert_signature_help_to_markdown_lines({
				activeSignature = index - 1,
				activeParameter = parameter,
				signatures = { signature },
			}, vim.bo.filetype, self.config.trigger_chars)

			-- Apply highlight if we got a valid range
			if param_range then
				api.nvim_buf_add_highlight(
					self.buf,
					-1,
					"LspSignatureActiveParameter",
					labels[index],
					param_range[1],
					param_range[2]
				)
			end
		end
	end

	-- Add icon highlights
	self:highlight_icons()
end

function SignatureHelp:highlight_icons()
	local icon_highlights = {
		{ self.config.icons.method, "SignatureHelpMethod" },
		{ self.config.icons.parameter, "SignatureHelpParameter" },
		{ self.config.icons.documentation, "SignatureHelpDocumentation" },
	}
	local line_count = api.nvim_buf_line_count(self.buf)
	for _, icon_hl in ipairs(icon_highlights) do
		local icon, hl_group = unpack(icon_hl)
		for line_num = 0, math.min(line_count - 1, 100) do -- Limit to first 100 lines
			local line = api.nvim_buf_get_lines(self.buf, line_num, line_num + 1, false)[1]
			if line then
				local start_col = line:find(vim.pesc(icon))
				if start_col then
					api.nvim_buf_add_highlight(self.buf, -1, hl_group, line_num, start_col - 1, start_col - 1 + #icon)
				end
			end
		end
	end
	-- for _, icon_hl in ipairs(icon_highlights) do
	-- 	local icon, hl_group = unpack(icon_hl)
	-- 	local line_num = 0
	-- 	while line_num < api.nvim_buf_line_count(self.buf) do
	-- 		local line = api.nvim_buf_get_lines(self.buf, line_num, line_num + 1, false)[1]
	-- 		local start_col = line:find(vim.pesc(icon))
	-- 		if start_col then
	-- 			api.nvim_buf_add_highlight(self.buf, -1, hl_group, line_num, start_col - 1, start_col - 1 + #icon)
	-- 		end
	-- 		line_num = line_num + 1
	-- 	end
	-- end
end

-- Modify the display function to handle dock mode parameter highlights
function SignatureHelp:display(result)
	if not result or not result.signatures or #result.signatures == 0 then
		self:hide()
		return
	end

	if self.visible and self.current_signatures then
		local current_sig = self.current_signatures[self.current_signature_idx or 1]
		local new_sig = result.signatures[result.activeSignature or 0]

		if
			current_sig
			and new_sig
			and current_sig.label == new_sig.label
			and self.last_active_parameter == result.activeParameter
		then
			return
		end
	end

	-- Store current signatures for navigation
	self.current_signatures = result.signatures
	self.current_active_parameter = result.activeParameter
	self.current_signature_idx = result.activeSignature and (result.activeSignature + 1) or 1

	-- Convert to markdown and get labels
	local contents, labels = markdown_for_signature_list(result.signatures, self.config)

	if #contents > 0 then
		if self.config.dock_mode.enabled then
			local win, buf = self:create_dock_window()
			if win and buf then
				-- Set content with error handling
				pcall(api.nvim_buf_set_lines, buf, 0, -1, false, contents)
				-- Apply markdown styling safely
				pcall(vim.lsp.util.stylize_markdown, buf, contents, {})
				-- Set parameter highlights
				self:set_dock_parameter_highlights(result.activeParameter, result.signatures)
				self.visible = true
			end
		else
			-- Use existing floating window logic
			local bufnr, winid = self:create_float_window(contents)
			if bufnr and winid then
				self:set_active_parameter_highlights(result.activeParameter, result.signatures, labels)
			end
		end
	end
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
	if not self.enabled then
		return
	end
	local cmp_visible = pcall(require, "cmp") and require("cmp").visible() or false
	self.cmp_visible_cache = cmp_visible
	if cmp_visible and self.config.avoid_cmp_overlap then
		self:hide()
		return
	end
	local clients = vim.lsp.get_clients({ bufnr = 0 })

	local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)

	vim.lsp.buf_request(0, "textDocument/signatureHelp", params, function(err, result, _)
		if err then
			if not self.config.silent then
				vim.notify("Error in LSP Signature Help: " .. vim.inspect(err), vim.log.levels.ERROR)
			end
			self:hide()
			return
		end

		if result and result.signatures and #result.signatures > 0 then
			self.last_active_parameter = result.activeParameter
			local sig = result.signatures[result.activeSignature or 0]
			if sig then
				self.parameter_cache[sig.label] = {
					count = (sig.parameters and #sig.parameters) or 0,
					active = result.activeParameter,
				}
			end
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
		-- Close dock window if it exists when entering normal mode
		if self.config.dock_mode.enabled then
			self:close_dock_window()
			-- Temporarily disable dock mode
			local was_dock_enabled = self.config.dock_mode.enabled
			self.config.dock_mode.enabled = false
			self:trigger()
			self.config.dock_mode.enabled = was_dock_enabled
		else
			self:trigger()
		end
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
		self.timer = vim.fn.timer_start(self.config.debounce_time, function()
			-- Check LSP capability before triggering
			local clients = vim.lsp.get_clients()
			local has_signature = false
			for _, client in ipairs(clients) do
				if client.server_capabilities.signatureHelpProvider then
					has_signature = true
					break
				end
			end

			if has_signature then
				self:trigger()
			end
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
		end,
	})

	api.nvim_create_autocmd({ "CursorMoved" }, {
		group = group,
		callback = function()
			if self.normal_mode_active then
				debounced_trigger()
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
function SignatureHelp:create_dock_window()
	local dock_config = self:calculate_dock_position()
	return create_window(self, self.dock_buf, dock_config)
end
-- function SignatureHelp:create_dock_window()
-- 	-- Cache current window and buffer
-- 	local current_win = api.nvim_get_current_win()
-- 	local current_buf = api.nvim_get_current_buf()
--
-- 	-- Create or reuse buffer
-- 	if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
-- 		self.dock_buf = api.nvim_create_buf(false, true)
--
-- 		-- Set buffer options
-- 		local buf_opts = {
-- 			buftype = "nofile",
-- 			bufhidden = "hide",
-- 			modifiable = true,
-- 			filetype = "markdown",
-- 			swapfile = false,
-- 		}
--
-- 		for opt, val in pairs(buf_opts) do
-- 			api.nvim_buf_set_option(self.dock_buf, opt, val)
-- 		end
-- 	end
--
-- 	-- Calculate position and create/update window
-- 	local dock_config = self:calculate_dock_position()
--
-- 	-- Use dock-specific border
-- 	dock_config.border = self.config.dock_border
--
-- 	if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
-- 		self.dock_win = api.nvim_open_win(self.dock_buf, false, dock_config)
-- 	else
-- 		api.nvim_win_set_config(self.dock_win, dock_config)
-- 	end
--
-- 	-- Set window options
-- 	local win_opts = {
-- 		wrap = true,
-- 		winblend = self.config.winblend,
-- 		foldenable = false,
-- 		cursorline = false,
-- 		winhighlight = "Normal:SignatureHelpDock,FloatBorder:SignatureHelpBorder",
-- 		signcolumn = "no",
-- 		number = false,
-- 		relativenumber = false,
-- 	}
--
-- 	for opt, val in pairs(win_opts) do
-- 		api.nvim_win_set_option(self.dock_win, opt, val)
-- 	end
--
-- 	-- Store window ID for identification
-- 	pcall(api.nvim_win_set_var, self.dock_win, "signature_help_id", self.dock_win_id)
--
-- 	return self.dock_win, self.dock_buf
-- end

function SignatureHelp:close_dock_window()
	-- Fast check for existing dock window
	if not self.dock_win_id then
		return
	end

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
			activeParameter = current_active,
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

function SignatureHelp:calculate_dock_position()
	local current_win = api.nvim_get_current_win()
	local win_height = api.nvim_win_get_height(current_win)
	local win_width = api.nvim_win_get_width(current_win)
	local padding = self.config.dock_mode.padding

	local position = self.config.dock_mode.position
	local dock_height = self.config.dock_mode.height
	local dock_width = self.config.dock_mode.width

	-- Auto-adjust size if enabled
	if self.config.dock_mode.auto_adjust and self.current_signatures then
		local content_height = #self.current_signatures
		dock_height = math.min(math.max(content_height + 1, 3), self.config.max_height)
	end

	local config = {
		relative = "win",
		width = math.min(dock_width, win_width - (padding * 2)),
		height = dock_height,
		style = "minimal",
		border = self.config.border,
		zindex = 50,
		focusable = true,
		noautocmd = true,
	}

	-- Position-specific configurations
	if position == "bottom" then
		config.row = win_height - dock_height - padding
		config.col = padding
	elseif position == "top" then
		config.row = padding
		config.col = padding
	elseif position == "right" then
		config.col = win_width - dock_width - padding
		config.row = math.floor((win_height - dock_height) / 2)
		config.width = math.min(dock_width, win_width - config.col - padding)
	end

	return config
end

-- function SignatureHelp:update_dock_active_parameter(parameter_index)
-- 	if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
-- 		return
-- 	end
--
-- 	-- Clear existing highlights
-- 	api.nvim_buf_clear_namespace(self.dock_buf, -1, 0, -1)
--
-- 	-- Get current signature
-- 	local signature = self.current_signatures[self.current_signature_idx or 1]
-- 	if not signature then
-- 		return
-- 	end
--
-- 	-- Update active parameter
-- 	signature.activeParameter = parameter_index
--
-- 	-- Refresh display with new active parameter
-- 	self:display({
-- 		signatures = self.current_signatures,
-- 		activeParameter = parameter_index,
-- 		activeSignature = self.current_signature_idx and (self.current_signature_idx - 1) or 0,
-- 	})
-- end

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

	-- Get the parameters and their ranges
	local params = signature.parameters or {}
	if active_parameter and params[active_parameter + 1] then
		local param = params[active_parameter + 1]
		local label = type(param.label) == "table" and param.label or { param.label }

		-- Get the first line of the buffer
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
			-- Find the parameter in the line
			local escaped_label = vim.pesc(label)
			start_pos = line:find(escaped_label)
			if start_pos then
				end_pos = start_pos + #label - 1
			end
		end

		-- Apply highlight if we found the parameter
		if start_pos and end_pos then
			api.nvim_buf_add_highlight(
				self.dock_buf,
				-1,
				"LspSignatureActiveParameter",
				0, -- Line number (first line)
				start_pos - 1,
				end_pos
			)
		end
	end

	-- Add icon highlights
	self:highlight_icons()
end

-- Add a function to update active parameter in dock mode
function SignatureHelp:update_dock_active_parameter(parameter_index)
	if not self.dock_buf or not api.nvim_buf_is_valid(self.dock_buf) then
		return
	end

	-- Clear existing highlights
	api.nvim_buf_clear_namespace(self.dock_buf, -1, 0, -1)

	-- Get current signature
	local signature = self.current_signatures[self.current_signature_idx or 1]
	if not signature then
		return
	end

	-- Update active parameter
	signature.activeParameter = parameter_index

	-- Refresh display with new active parameter
	self:display({
		signatures = self.current_signatures,
		activeParameter = parameter_index,
		activeSignature = self.current_signature_idx and (self.current_signature_idx - 1) or 0,
	})
end

function SignatureHelp:setup_dock_autocmds()
	if not self.dock_autocmd_group then
		self.dock_autocmd_group = api.nvim_create_augroup("SignatureHelpDock", { clear = true })
	end

	api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
		group = self.dock_autocmd_group,
		callback = function()
			if self.visible and self.config.dock_mode.enabled then
				local dock_config = self:calculate_dock_position()
				if self.dock_win and api.nvim_win_is_valid(self.dock_win) then
					api.nvim_win_set_config(self.dock_win, dock_config)
				end
			end
		end,
	})
end

function M.setup(opts)
	-- Ensure setup is called only once
	if M._initialized then
		return M._instance
	end

	opts = opts or {}
	local signature_help = SignatureHelp.new()

	-- Deep merge user config with defaults
	signature_help.config = vim.tbl_deep_extend("force", signature_help._default_config, opts)

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
	signature_help:setup_dock_autocmds()

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
