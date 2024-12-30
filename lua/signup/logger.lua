-- logger.lua
local M = {}

local levels = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
}

M.level = levels.INFO

function M.log(level, msg, ...)
    if level >= M.level then
        local formatted = string.format(msg, ...)
        vim.notify("signup.nvim: " .. formatted, vim.log.levels[level])
    end
end

function M.debug(msg, ...) M.log(levels.DEBUG, msg, ...) end
function M.info(msg, ...) M.log(levels.INFO, msg, ...) end
function M.warn(msg, ...) M.log(levels.WARN, msg, ...) end
function M.error(msg, ...) M.log(levels.ERROR, msg, ...) end

return M