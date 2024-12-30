-- docs.lua
local M = {}

function M.format_documentation(doc, config)
    if not doc then return {} end
    
    local lines = {}
    local doc_text = type(doc) == "string" and doc or (doc.value or "")
    
    if doc_text:match("%S") then
        table.insert(lines, string.rep("─", 40))
        table.insert(lines, config.icons.method .. " Documentation:")
        
        for _, line in ipairs(vim.split(doc_text, "\n")) do
            if line:match("%S") then
                table.insert(lines, "  " .. line)
            end
        end
    end
    
    return lines
end

return M