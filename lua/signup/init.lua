local api = vim.api
local util = require("vim.lsp.util")
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
		buffer_capabilities = {},
		warned_buffers = {},
		current_signature_idx = nil,
		config = nil,
		-- Create namespaces for highlighting and extmarks
		highlight_ns = vim.api.nvim_create_namespace("SignatureHelpActive"),
		pinned = false,
	}, SignatureHelp)

	instance._default_config = {
		silent = true,
		icons = {
			parameter = "",
			method = "󰡱",
			documentation = "󱪙",
			type = "󰌗",
			default = "󰁔",
		},
		colors = {
			parameter = "#86e1fc",
			method = "#c099ff",
			documentation = "#4fd6be",
			default_value = "#a80888",
			type = "#f6c177",
		},
		active_parameter = true,
		active_parameter_colors = {
			bg = "#86e1fc",
			fg = "#1a1a1a",
		},
		border = "rounded",
		dock_border = "rounded",
		winblend = 10,
		auto_close = true,
		trigger_chars = { "(", ",", ")" },
		max_height = 10,
		max_width = 40,
		floating_window_above_cur_line = true,
		debounce_time = 50,
		dock_toggle_key = "<Leader>sd",
		dock_mode = {
			enabled = false,
			position = "bottom", -- "bottom", "top", or "middle"
			height = 4, -- If > 1: fixed height in lines, if <= 1: percentage of window height (e.g., 0.3 = 30%)
			padding = 1, -- Padding from window edges
			side = "right", -- "right", "left", or "center"
			width_percentage = 40, -- Percentage of editor width (10-90%)
		},
	}

	return instance
end

function SignatureHelp:get_active_client()
	local bufnr = vim.api.nvim_get_current_buf()
	-- Use vim.lsp.get_clients which is preferred in newer Neovim versions
	-- Fallback to vim.lsp.get_active_clients for backward compatibility
	local get_clients_fn = vim.lsp.get_clients or vim.lsp.get_active_clients
	local clients = get_clients_fn({ bufnr = bufnr })

	if not clients or #clients == 0 then
		return nil
	end

	for _, client in ipairs(clients) do
		if client.server_capabilities.signatureHelpProvider then
			return client
		end
	end
	return nil
end

-- Check if the buffer has signature help capability
function SignatureHelp:check_capability(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Check if we've already cached the capability
	if self.buffer_capabilities[bufnr] ~= nil then
		return self.buffer_capabilities[bufnr]
	end

	-- Get all LSP clients attached to this buffer
	local client = self:get_active_client()
	if not client then
		self.buffer_capabilities[bufnr] = false

		-- Only warn if not silent
		if not self.config.silent and not self.warned_buffers[bufnr] then
			vim.notify("No LSP server with signature help capability attached to this buffer", vim.log.levels.WARN)
			self.warned_buffers[bufnr] = true
		end

		return false
	end

	self.buffer_capabilities[bufnr] = true
	return true
end

function SignatureHelp:display(result)
	if not result or not result.signatures or #result.signatures == 0 then
		self:hide()
		return
	end

	-- Prevent duplicate displays
	if self.current_signatures and vim.deep_equal(result.signatures, self.current_signatures) then
		return
	end

	self.current_signatures = result.signatures
	self.current_signature_idx = result.activeSignature or 0

	-- Convert to markdown using LSP utilities
	local ft = vim.bo.filetype
	local markdown, active_range =
		vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft, self.config.trigger_chars)

	if not markdown or #markdown == 0 then
		self:hide()
		return
	end

	if self.config.dock_mode.enabled then
		self:display_dock(markdown, active_range)
	else
		self:display_float(markdown, active_range)
	end
end

function SignatureHelp:display_float(markdown, active_range)
	local bufnr, winid = vim.lsp.util.open_floating_preview(markdown, "markdown", {
		border = self.config.border,
		focusable = false,
		zindex = 50,
		max_width = self.config.max_width,
		max_height = self.config.max_height,
		relative = "cursor",
		row = self.config.floating_window_above_cur_line and -#markdown - 1 or 1,
		col = 0,
	})

	if bufnr and winid then
		self.buf = bufnr
		self.win = winid
		self.visible = true

		if active_range and self.config.active_parameter then
			local highlight_ns = SignatureHelp.highlight_ns
			api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)

			-- Check if active_range has valid start and end fields
			if active_range.start and active_range["end"] then
				local start_line = active_range.start[1]
				local start_col = active_range.start[2]
				local end_line = active_range["end"][1]
				local end_col = active_range["end"][2]

				-- Add additional nil check before highlighting
				if start_line ~= nil and start_col ~= nil and end_col ~= nil then
					-- Get the active parameter colors from config
					local bg_color = self.config.active_parameter_colors.bg
					local fg_color = self.config.active_parameter_colors.fg

					-- Set highlight group for active parameter
					vim.api.nvim_set_hl(0, "LspSignatureActiveParameter", {
						fg = fg_color,
						bg = bg_color,
						bold = true,
					})

					api.nvim_buf_add_highlight(
						bufnr,
						highlight_ns,
						"LspSignatureActiveParameter",
						start_line,
						start_col,
						end_col
					)
				end
			end
		end

		api.nvim_set_option_value("winblend", self.config.winblend, { win = winid })
		api.nvim_set_option_value("foldenable", false, { win = winid })
		api.nvim_set_option_value("wrap", true, { win = winid })
	end
end

-- Get markdown for signature help (for fixed dock mode)
function SignatureHelp:get_signature_markdown()
	local bufnr = vim.api.nvim_get_current_buf()

	if not self:check_capability(bufnr) then
		return nil, nil
	end

	local client = self:get_active_client()
	if not client then
		return nil, nil
	end

	local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding or "utf-16")
	local result = nil

	-- Use async handler to get signature help directly
	local lsp_result = vim.lsp.buf_request_sync(bufnr, "textDocument/signatureHelp", params, 1000)

	if not lsp_result then
		return nil, nil
	end

	for _, res in pairs(lsp_result) do
		if res.result and res.result.signatures and #res.result.signatures > 0 then
			result = res.result
			break
		end
	end

	if not result then
		return nil, nil
	end

	self.current_signatures = result.signatures
	self.current_signature_idx = result.activeSignature or 0

	-- Safely convert to markdown using LSP utilities
	local ft = vim.bo.filetype
	local markdown, active_range

	-- Wrap in pcall to catch any potential errors during conversion
	local success, result_or_error =
		pcall(vim.lsp.util.convert_signature_help_to_markdown_lines, result, ft, self.config.trigger_chars)

	if success then
		if type(result_or_error) == "table" then
			-- The function might return a table with the markdown and active_range
			if result_or_error[1] and type(result_or_error[1]) == "table" then
				markdown = result_or_error[1]
				active_range = result_or_error[2]
			else
				-- Or it might return just the markdown directly
				markdown = result_or_error
				-- Try to extract the active parameter information
				if result.activeParameter and result.signatures and result.signatures[result.activeSignature + 1] then
					local sig = result.signatures[result.activeSignature + 1]
					if sig.parameters and sig.parameters[result.activeParameter + 1] then
						-- Create our own active_range if we can determine it
						local param = sig.parameters[result.activeParameter + 1]
						if param.label and type(param.label) == "table" and param.label[1] and param.label[2] then
							active_range = {
								start = { 0, param.label[1] },
								["end"] = { 0, param.label[2] },
							}
						end
					end
				end
			end
		else
			markdown = { tostring(result_or_error) }
		end
	else
		-- Fallback if conversion fails
		markdown = { "Error displaying signature help", "Please check your LSP configuration" }
		active_range = nil

		-- Log the error if not silent
		if not self.config.silent then
			vim.notify(
				"Error converting signature help to markdown: " .. tostring(result_or_error),
				vim.log.levels.ERROR
			)
		end
	end

	-- Ensure markdown is valid
	if not markdown or #markdown == 0 then
		markdown = { "No signature information available" }
	end

	return markdown, active_range
end

function SignatureHelp:display_dock(markdown, active_range)
	local win, buf = self:create_dock_window()
	if not win or not buf then
		return
	end

	-- Clear existing highlights and content
	api.nvim_buf_clear_namespace(buf, self.highlight_ns, 0, -1)

	-- Set content
	api.nvim_buf_set_option(buf, "modifiable", true)
	api.nvim_buf_set_lines(buf, 0, -1, false, markdown)
	api.nvim_buf_set_option(buf, "modifiable", false)

	-- Apply highlights for active parameter
	if active_range and self.config.active_parameter then
		if active_range.start and active_range["end"] then
			local start_line = active_range.start[1]
			local start_col = active_range.start[2]
			local end_line = active_range["end"][1]
			local end_col = active_range["end"][2]

			if start_line ~= nil and start_col ~= nil and end_col ~= nil then
				local bg_color = self.config.active_parameter_colors.bg
				local fg_color = self.config.active_parameter_colors.fg

				vim.api.nvim_set_hl(0, "LspSignatureActiveParameter", {
					fg = fg_color,
					bg = bg_color,
					bold = true,
				})

				api.nvim_buf_add_highlight(
					buf,
					self.highlight_ns,
					"LspSignatureActiveParameter",
					start_line,
					start_col,
					end_col
				)
			end
		end
	end

	-- Update status line
	self:update_status_line()

	-- Auto-resize if not pinned
	if not self.pinned then
		self:resize_dock()
	end

	-- Mark window as visible
	self.visible = true
end

function SignatureHelp:create_dock_window()
	if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
		self.dock_buf = api.nvim_create_buf(false, true)
		vim.bo[self.dock_buf].buftype = "nofile"
		vim.bo[self.dock_buf].bufhidden = "hide"
		vim.bo[self.dock_buf].swapfile = false
		vim.bo[self.dock_buf].modifiable = true
		vim.bo[self.dock_buf].filetype = "markdown"

		local win_height = api.nvim_win_get_height(0)
		local win_width = api.nvim_win_get_width(0)
		local padding = self.config.dock_mode.padding

		-- Use either fixed height or percentage of window height
		local height_value = self.config.dock_mode.height
		local dock_height
		if type(height_value) == "number" and height_value > 1 then
			-- Fixed height in lines
			dock_height = math.min(height_value, math.floor(win_height * 0.5))
		else
			-- Treat as percentage of window height (default 30%)
			local height_percentage = (type(height_value) == "number" and height_value <= 1) and height_value * 100
				or 30
			dock_height = math.floor(win_height * (height_percentage / 100))
		end

		-- Calculate width based on percentage
		local percentage = self.config.dock_mode.width_percentage or 40
		percentage = math.min(math.max(percentage, 10), 90) -- Clamp between 10% and 90%
		local dock_width = math.floor((win_width * percentage) / 100)

		-- Calculate position based on side and position settings
		local row, col

		-- Determine vertical position (row)
		if self.config.dock_mode.position == "bottom" then
			row = win_height - dock_height - padding
		elseif self.config.dock_mode.position == "middle" then
			row = math.floor((win_height - dock_height) / 2)
		else -- "top" or default
			row = padding
		end

		-- Determine horizontal position (col)
		if self.config.dock_mode.side == "right" then
			col = win_width - dock_width - padding
		elseif self.config.dock_mode.side == "center" then
			col = math.floor((win_width - dock_width) / 2)
		else -- "left" or default
			col = padding
		end

		self.dock_win = api.nvim_open_win(self.dock_buf, false, {
			relative = "editor",
			width = dock_width,
			height = dock_height,
			row = row,
			col = col,
			style = "minimal",
			border = self.config.dock_border,
			zindex = 50,
			focusable = true,
			title = "Signup",
			title_pos = "center",
		})

		-- Set window options
		local win_opts = {
			wrap = true,
			conceallevel = 2,
			winblend = self.config.winblend,
			foldenable = false,
			winhighlight = table.concat({
				"Normal:SignatureHelpDock",
				"FloatBorder:SignatureHelpBorder",
				"CursorLine:SignatureHelpActiveLine",
				"EndOfBuffer:SignatureHelpDock",
			}, ","),
			signcolumn = "no",
			number = false,
			relativenumber = false,
			cursorline = true,
			spell = false,
			list = false,
		}

		for opt, value in pairs(win_opts) do
			api.nvim_set_option_value(opt, value, { win = self.dock_win })
		end

		-- Add keymaps
		local keymaps = {
			{
				"n",
				"<Esc>",
				function()
					self:close_dock_window()
				end,
				{ buffer = self.dock_buf, desc = "Close dock" },
			},
		}

		for _, keymap in ipairs(keymaps) do
			vim.keymap.set(unpack(keymap))
		end

		-- Add status line
		self:update_status_line()
	end

	return self.dock_win, self.dock_buf
end

function SignatureHelp:update_status_line()
	if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
		return
	end

	local status = {}
	if self.current_signatures and #self.current_signatures > 1 then
		table.insert(
			status,
			string.format("󰡱 %d/%d", (self.current_signature_idx or 0) + 1, #self.current_signatures)
		)
	end
	if self.pinned then
		table.insert(status, "󰆓")
	end

	if #status > 0 then
		api.nvim_win_set_option(self.dock_win, "statusline", table.concat(status, " "))
	else
		api.nvim_win_set_option(self.dock_win, "statusline", "")
	end
end

function SignatureHelp:toggle_pin()
	self.pinned = not self.pinned
	self:update_status_line()
end

function SignatureHelp:resize_dock()
	if not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
		return
	end

	local content = api.nvim_buf_get_lines(self.dock_buf, 0, -1, false)
	local lines = #content
	local max_height = math.floor(api.nvim_win_get_height(0) * 0.5)
	local new_height = math.min(lines + 2, max_height)

	local win_height = api.nvim_win_get_height(0)
	local win_width = api.nvim_win_get_width(0)
	local padding = self.config.dock_mode.padding

	-- Calculate width based on percentage
	local percentage = self.config.dock_mode.width_percentage or 40
	percentage = math.min(math.max(percentage, 10), 90) -- Clamp between 10% and 90%
	local dock_width = math.floor((win_width * percentage) / 100)

	-- Calculate position based on side and position settings
	local row, col

	-- Determine vertical position (row)
	if self.config.dock_mode.position == "bottom" then
		row = win_height - new_height - padding
	elseif self.config.dock_mode.position == "middle" then
		row = math.floor((win_height - new_height) / 2)
	else -- "top" or default
		row = padding
	end

	-- Determine horizontal position (col)
	if self.config.dock_mode.side == "right" then
		col = win_width - dock_width - padding
	elseif self.config.dock_mode.side == "center" then
		col = math.floor((win_width - dock_width) / 2)
	else -- "left" or default
		col = padding
	end

	api.nvim_win_set_config(self.dock_win, {
		relative = "editor",
		width = dock_width,
		height = new_height,
		row = row,
		col = col,
	})
end

function SignatureHelp:navigate_signatures(direction)
	if not self.current_signatures or #self.current_signatures <= 1 then
		return
	end

	local curr_idx = self.current_signature_idx or 0

	if direction == "next" then
		curr_idx = (curr_idx + 1) % #self.current_signatures
	else
		curr_idx = (curr_idx - 1 + #self.current_signatures) % #self.current_signatures
	end

	self.current_signature_idx = curr_idx

	-- Get the active signature
	local active_signature = self.current_signatures[curr_idx + 1]
	if not active_signature then
		return
	end

	-- Create a new result object with the active signature
	local result = {
		signatures = self.current_signatures,
		activeSignature = curr_idx,
		activeParameter = active_signature.activeParameter or 0,
	}

	-- Try to get markdown for the new active signature
	local ft = vim.bo.filetype
	local markdown, active_range

	-- Safely attempt to convert to markdown
	local success, result_or_error =
		pcall(vim.lsp.util.convert_signature_help_to_markdown_lines, result, ft, self.config.trigger_chars)

	if success and result_or_error then
		if type(result_or_error) == "table" then
			if result_or_error[1] and type(result_or_error[1]) == "table" then
				markdown = result_or_error[1]
				active_range = result_or_error[2]
			else
				markdown = result_or_error
				-- Try to extract the active parameter information
				if active_signature.parameters and active_signature.parameters[result.activeParameter + 1] then
					local param = active_signature.parameters[result.activeParameter + 1]
					if param.label and type(param.label) == "table" and param.label[1] and param.label[2] then
						active_range = {
							start = { 0, param.label[1] },
							["end"] = { 0, param.label[2] },
						}
					end
				end
			end
		else
			markdown = { tostring(result_or_error) }
		end

		-- Update the display with new signature
		if self.config.dock_mode.enabled then
			self:display_dock(markdown, active_range)
		else
			self:display_float(markdown, active_range)
		end
	else
		-- If conversion fails, just call display with the raw result
		self:display(result)
	end
end

function SignatureHelp:hide()
	if self.visible then
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

function SignatureHelp:trigger()
	local bufnr = vim.api.nvim_get_current_buf()

	if not self:check_capability(bufnr) then
		return
	end

	if self.config.dock_mode.enabled then
		local markdown, active_range = self:get_signature_markdown()
		if markdown and #markdown > 0 then
			self:display_dock(markdown, active_range)
		end
	else
		local cmp_ok, cmp = pcall(require, "cmp")
		local blink_ok, blink = pcall(require, "blink-cmp")
		if cmp_ok and not cmp.visible() then
			vim.lsp.buf.signature_help({
				bufnr = bufnr,
				focusable = false,
				border = self.config.border,
				max_width = self.config.max_width,
				max_height = self.config.max_height,
				relative = "cursor",
				row = self.config.floating_window_above_cur_line and -1 or 1,
				col = 0,
				anchor_bias = "below",
				title = "Signup",
				title_pos = "center",
				silent = true,
			})
		elseif blink_ok and not blink.is_visible() then
			vim.lsp.buf.signature_help({
				bufnr = bufnr,
				focusable = false,
				border = self.config.border,
				max_width = self.config.max_width,
				max_height = self.config.max_height,
				relative = "cursor",
				row = self.config.floating_window_above_cur_line and -1 or 1,
				col = 0,
				anchor_bias = "below",
				title = "Signup",
				title_pos = "center",
				silent = true,
			})
		end
	end
end

function SignatureHelp:update_dock_window()
	if not self.config.dock_mode.enabled or not self.dock_win or not api.nvim_win_is_valid(self.dock_win) then
		return
	end

	local win_height = api.nvim_win_get_height(0)
	local win_width = api.nvim_win_get_width(0)
	local padding = self.config.dock_mode.padding

	-- Use either fixed height or percentage of window height
	local height_value = self.config.dock_mode.height
	local dock_height
	if type(height_value) == "number" and height_value > 1 then
		-- Fixed height in lines
		dock_height = math.min(height_value, math.floor(win_height * 0.5))
	else
		-- Treat as percentage of window height (default 30%)
		local height_percentage = (type(height_value) == "number" and height_value <= 1) and height_value * 100 or 30
		dock_height = math.floor(win_height * (height_percentage / 100))
	end

	-- Calculate width based on percentage
	local percentage = self.config.dock_mode.width_percentage or 40
	percentage = math.min(math.max(percentage, 10), 90) -- Clamp between 10% and 90%
	local dock_width = math.floor((win_width * percentage) / 100)

	-- Calculate position based on side and position settings
	local row, col

	-- Determine vertical position (row)
	if self.config.dock_mode.position == "bottom" then
		row = win_height - dock_height - padding
	elseif self.config.dock_mode.position == "middle" then
		row = math.floor((win_height - dock_height) / 2)
	else -- "top" or default
		row = padding
	end

	-- Determine horizontal position (col)
	if self.config.dock_mode.side == "right" then
		col = win_width - dock_width - padding
	elseif self.config.dock_mode.side == "center" then
		col = math.floor((win_width - dock_width) / 2)
	else -- "left" or default
		col = padding
	end

	api.nvim_win_set_config(self.dock_win, {
		relative = "editor",
		width = dock_width,
		height = dock_height,
		row = row,
		col = col,
	})
end

function SignatureHelp:setup_autocmds()
	local group = api.nvim_create_augroup("LspSignatureHelp", { clear = true })

	local function debounced_trigger()
		if self.timer then
			pcall(vim.fn.timer_stop, self.timer)
		end
		self.timer = vim.fn.timer_start(self.config.debounce_time, function()
			if not self.pinned then
				self:trigger()
			end
		end)
	end

	api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
		group = group,
		callback = function()
			if vim.fn.pumvisible() == 0 then
				debounced_trigger()
			else
				self:hide()
			end
		end,
	})

	api.nvim_create_autocmd({ "InsertLeave", "BufHidden", "BufLeave" }, {
		group = group,
		callback = function()
			if not self.pinned then
				self:hide()
			end
		end,
	})

	api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if self.config.dock_mode.enabled and self.dock_win and api.nvim_win_is_valid(self.dock_win) then
				self:update_dock_window()
			end
		end,
	})

	-- Clear capabilities cache when LSP attaches/detaches
	api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(args)
			self.buffer_capabilities[args.buf] = nil
			self.warned_buffers[args.buf] = nil
		end,
	})

	api.nvim_create_autocmd("LspDetach", {
		group = group,
		callback = function(args)
			self.buffer_capabilities[args.buf] = nil
		end,
	})
end

function SignatureHelp:setup_keymaps()
	if self.config.dock_toggle_key then
		vim.keymap.set("n", self.config.dock_toggle_key, function()
			if self.config.dock_mode.enabled then
				-- If already enabled, disable it and hide
				self.config.dock_mode.enabled = false
				self:hide()
			else
				-- If disabled, enable it and trigger
				self.config.dock_mode.enabled = true
				self:trigger()
			end
		end, { noremap = true, silent = true, desc = "Toggle signature help dock mode" })
	end
end

function M.setup(opts)
	if M._initialized then
		return M._instance
	end

	opts = opts or {}
	local signature_help = SignatureHelp.new()
	signature_help.config = vim.tbl_deep_extend("force", signature_help._default_config, opts)

	-- Setup highlights
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
				bold = true,
			},
		}

		for group, hl_opts in pairs(highlights) do
			vim.api.nvim_set_hl(0, group, hl_opts)
		end
	end

	setup_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("LspSignatureColors", { clear = true }),
		callback = setup_highlights,
	})

	signature_help:setup_autocmds()
	signature_help:setup_keymaps()

	M._initialized = true
	M._instance = signature_help

	return signature_help
end

-- Method to manually toggle dock mode
function M.toggle_dock_mode()
	if M._instance then
		if M._instance.config.dock_mode.enabled then
			-- If already enabled, disable it and hide
			M._instance.config.dock_mode.enabled = false
			M._instance:hide()
		else
			-- If disabled, enable it and trigger
			M._instance.config.dock_mode.enabled = true
			M._instance:trigger()
		end
	end
end

-- Method to manually request signature help
function M.signature_help()
	if M._instance then
		M._instance:trigger()
	end
end

M.version = "1.0.0"
M.dependencies = {
	"nvim-treesitter/nvim-treesitter",
}

return M
