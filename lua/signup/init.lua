-- init.lua
local api = vim.api
local utils = require("signup.utils")
local window = require("signup.window")
local highlights = require("signup.highlights")

local M = {}

-- Default configuration
local default_config = {
    ui = {
        border = "rounded",
        max_width = 80,
        max_height = 10,
        min_width = 40,
        padding = 1,
    },
    icons = {
        signature = "󰊕 ", -- Signature section icon
        parameter = "󰘍 ", -- Parameter section icon
        documentation = "󰈙 ", -- Documentation section icon
        separator = "│", -- Section separator
    },
    colors = {
        signature = "#c099ff", -- Signature section color
        parameter = "#86e1fc", -- Parameter section color
        documentation = "#4fd6be", -- Documentation section color
        active_parameter = {
            fg = "#1a1a1a",
            bg = "#86e1fc",
            bold = true,
        },
    },
    behavior = {
        dock_mode = false,
        dock_position = "bottom", -- bottom, top
        debounce_ms = 50,
    },
    keymaps = {
        toggle = "<C-k>",
        toggle_dock = "<Leader>k",
    }
}

-- SignatureHelp class
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
    local self = setmetatable({
        win = nil,
        buf = nil,
        visible = false,
        config = vim.deepcopy(default_config),
        current_signature = nil,
        current_parameter = 0,
        highlight_ns = api.nvim_create_namespace("SignatureHelp"),
        instance_count = 0, -- Track instances to prevent duplicates
    }, SignatureHelp)
    return self
end

function SignatureHelp:format_signature_content(result)
    if not result or not result.signatures or #result.signatures == 0 then
        return {}
    end

    local signature = result.signatures[1]
    local active_parameter = result.activeParameter or 0
    local contents = {}
    
    -- Convert signature help to markdown lines
    local markdown_lines, active_param_range = vim.lsp.util.convert_signature_help_to_markdown_lines(
        result,
        vim.bo.filetype,
        {
            active_parameter = active_parameter,
            triggers = result.triggers or {},
        }
    )

    if not markdown_lines or #markdown_lines == 0 then
        return {}
    end

    -- Add signature section with icon
    table.insert(contents, string.format("%s %s",
        self.config.icons.signature,
        markdown_lines[1]
    ))

    -- Add parameter documentation if available
    if signature.parameters and signature.parameters[active_parameter + 1] then
        local param = signature.parameters[active_parameter + 1]
        if param.documentation then
            local doc = type(param.documentation) == "string" 
                and param.documentation 
                or param.documentation.value

            if doc then
                table.insert(contents, "")
                table.insert(contents, string.format("%s Parameter", self.config.icons.parameter))
                table.insert(contents, doc)
            end
        end
    end

    -- Add signature documentation if available
    if signature.documentation then
        local doc = type(signature.documentation) == "string" 
            and signature.documentation 
            or signature.documentation.value

        if doc then
            table.insert(contents, "")
            table.insert(contents, string.format("%s Documentation", self.config.icons.documentation))
            table.insert(contents, doc)
        end
    end

    return contents, active_param_range
end

function SignatureHelp:show()
    -- Prevent multiple instances
    if self.instance_count > 0 then
        return
    end

    local params = vim.lsp.util.make_position_params()
    
    vim.lsp.buf_request(0, 'textDocument/signatureHelp', params, function(err, result, ctx)
        if err or not result or not result.signatures or #result.signatures == 0 then
            self:hide()
            return
        end

        local contents, active_param_range = self:format_signature_content(result)
        if #contents == 0 then
            self:hide()
            return
        end

        if self.config.behavior.dock_mode then
            local win, buf = window.create_dock_window(contents, self.config)
            self.win = win
            self.buf = buf
        else
            local win, buf = window.create_floating_window(contents, self.config)
            self.win = win
            self.buf = buf
        end

        self.visible = true
        self.current_signature = result.signatures[1]
        self.current_parameter = result.activeParameter
        self.instance_count = self.instance_count + 1

        -- Apply highlights
        self:apply_highlights(active_param_range)
    end)
end

function SignatureHelp:apply_highlights(active_param_range)
    if not self.buf or not api.nvim_buf_is_valid(self.buf) then
        return
    end

    -- Clear existing highlights
    api.nvim_buf_clear_namespace(self.buf, self.highlight_ns, 0, -1)

    -- Apply section icon highlights
    local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
    for i, line in ipairs(lines) do
        -- Highlight signature icon
        if line:find(vim.pesc(self.config.icons.signature), 1, true) == 1 then
            api.nvim_buf_add_highlight(self.buf, self.highlight_ns, "SignatureHelpSignature", i-1, 0, #self.config.icons.signature)
        end
        -- Highlight parameter icon
        if line:find(vim.pesc(self.config.icons.parameter), 1, true) == 1 then
            api.nvim_buf_add_highlight(self.buf, self.highlight_ns, "SignatureHelpParameter", i-1, 0, #self.config.icons.parameter)
        end
        -- Highlight documentation icon
        if line:find(vim.pesc(self.config.icons.documentation), 1, true) == 1 then
            api.nvim_buf_add_highlight(self.buf, self.highlight_ns, "SignatureHelpDocumentation", i-1, 0, #self.config.icons.documentation)
        end
    end

    -- Highlight active parameter if range is available
    if active_param_range then
        api.nvim_buf_add_highlight(
            self.buf,
            self.highlight_ns,
            "SignatureHelpActiveParameter",
            0, -- First line contains the signature
            active_param_range[1],
            active_param_range[2]
        )
    end
end

function SignatureHelp:hide()
    if self.win and api.nvim_win_is_valid(self.win) then
        api.nvim_win_close(self.win, true)
    end
    if self.buf and api.nvim_buf_is_valid(self.buf) then
        api.nvim_buf_delete(self.buf, { force = true })
    end
    self.visible = false
    self.instance_count = math.max(0, self.instance_count - 1)
end

function SignatureHelp:highlight_active_parameter()
    if not self.buf or not self.current_signature or not self.current_parameter then
        return
    end

    api.nvim_buf_clear_namespace(self.buf, self.highlight_ns, 0, -1)

    local params = self.current_signature.parameters
    if not params then return end

    local param = params[self.current_parameter + 1]
    if not param then return end

    -- Find parameter position in signature line
    local line = api.nvim_buf_get_lines(self.buf, 0, 1, false)[1]
    local start_pos = line:find(string.format("<%s>", vim.pesc(param.label)))
    
    if start_pos then
        api.nvim_buf_add_highlight(
            self.buf,
            self.highlight_ns,
            "SignatureHelpActiveParameter",
            0,
            start_pos - 1,
            start_pos + #param.label + 2
        )
    end
end

function SignatureHelp:toggle_dock_mode()
    self.dock_mode = not self.dock_mode
    if self.visible then
        self:hide()
        self:show()
    end
end

function SignatureHelp:setup_autocmds()
    local group = api.nvim_create_augroup("SignatureHelp", { clear = true })

    -- Auto-trigger in insert mode
    api.nvim_create_autocmd("InsertEnter", {
        group = group,
        callback = function()
            utils.debounce(function() self:show() end, self.config.debounce_ms)
        end
    })

    -- Update on cursor movement in insert mode
    api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        callback = function()
            utils.debounce(function() self:show() end, self.config.debounce_ms)
        end
    })

    -- Hide on leaving insert mode
    api.nvim_create_autocmd("InsertLeave", {
        group = group,
        callback = function()
            self:hide()
        end
    })
end

function SignatureHelp:setup_keymaps()
    -- Toggle signature help in normal mode
    vim.keymap.set("n", self.config.keymaps.toggle, function()
        if self.visible then
            self:hide()
        else
            self:show()
        end
    end, { noremap = true, silent = true })

    -- Toggle dock mode
    vim.keymap.set("n", self.config.keymaps.toggle_dock, function()
        self:toggle_dock_mode()
    end, { noremap = true, silent = true })
end

function M.setup(opts)
    -- Create new instance
    local instance = SignatureHelp.new()
    
    -- Merge configurations properly
    if opts and not vim.tbl_isempty(opts) then
        -- Merge nested tables properly
        for key, value in pairs(opts) do
            if type(value) == "table" and type(instance.config[key]) == "table" then
                instance.config[key] = vim.tbl_deep_extend("force", instance.config[key], value)
            else
                instance.config[key] = value
            end
        end
    end

    -- Setup components
    highlights.setup_highlights(instance.config.colors)
    instance:setup_autocmds()
    instance:setup_keymaps()

    return instance
end

return M

return M