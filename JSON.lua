--[[
  JSON.lua — Minimal JSON decoder for the Photo Keyworder plugin.
  Handles the full JSON spec well enough for Google Vision API responses.
  No external dependencies.
--]]

local JSON = {}

--- Decode a JSON string and return a Lua value (table / string / number / bool / nil).
--- Returns nil if parsing fails.
function JSON.decode(s)
    if type(s) ~= 'string' or #s == 0 then return nil end

    local pos = 1
    local len = #s

    -- Skip ASCII whitespace
    local function skip()
        while pos <= len and s:byte(pos) <= 32 do
            pos = pos + 1
        end
    end

    -- Forward-declare so string/object/array parsers can call each other
    local parseValue

    -- Parse a JSON string starting at the current quote character
    local function parseString()
        pos = pos + 1  -- skip opening "
        local buf = {}
        while pos <= len do
            local b = s:byte(pos)
            if b == 34 then          -- closing "
                pos = pos + 1
                return table.concat(buf)
            elseif b == 92 then      -- backslash escape
                pos = pos + 1
                local e = s:byte(pos)
                if     e == 34  then buf[#buf+1] = '"'
                elseif e == 92  then buf[#buf+1] = '\\'
                elseif e == 47  then buf[#buf+1] = '/'
                elseif e == 98  then buf[#buf+1] = '\b'
                elseif e == 102 then buf[#buf+1] = '\f'
                elseif e == 110 then buf[#buf+1] = '\n'
                elseif e == 114 then buf[#buf+1] = '\r'
                elseif e == 116 then buf[#buf+1] = '\t'
                elseif e == 117 then -- \uXXXX — skip 4 hex digits (simplified)
                    pos = pos + 4
                end
                pos = pos + 1
            else
                buf[#buf+1] = s:sub(pos, pos)
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    -- Parse a JSON object  { "key": value, ... }
    local function parseObject()
        pos = pos + 1  -- skip {
        local obj = {}
        skip()
        if s:byte(pos) == 125 then pos = pos + 1; return obj end  -- empty {}
        while pos <= len do
            skip()
            local key = parseValue()          -- key is always a string in valid JSON
            skip()
            if s:byte(pos) == 58 then pos = pos + 1 end  -- skip :
            local v = parseValue()
            if key ~= nil then obj[key] = v end
            skip()
            local sep = s:byte(pos)
            if sep == 125 then pos = pos + 1; break end  -- }
            if sep == 44  then pos = pos + 1 end          -- ,
        end
        return obj
    end

    -- Parse a JSON array  [ value, ... ]
    local function parseArray()
        pos = pos + 1  -- skip [
        local arr = {}
        skip()
        if s:byte(pos) == 93 then pos = pos + 1; return arr end  -- empty []
        while pos <= len do
            arr[#arr+1] = parseValue()
            skip()
            local sep = s:byte(pos)
            if sep == 93 then pos = pos + 1; break end  -- ]
            if sep == 44 then pos = pos + 1 end          -- ,
        end
        return arr
    end

    -- Parse any JSON value
    parseValue = function()
        skip()
        if pos > len then return nil end
        local c = s:byte(pos)

        if c == 34  then return parseString() end  -- "
        if c == 123 then return parseObject()  end  -- {
        if c == 91  then return parseArray()   end  -- [

        -- Boolean / null literals
        if s:sub(pos, pos + 3) == 'true'  then pos = pos + 4; return true  end
        if s:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false end
        if s:sub(pos, pos + 3) == 'null'  then pos = pos + 4; return nil   end

        -- Number (integer or float, optionally with exponent)
        local num, np = s:match('^(-?%d+%.?%d*[eE]?[+%-]?%d*)()', pos)
        if num then
            pos = np
            return tonumber(num)
        end

        return nil  -- unrecognised — skip
    end

    local ok, result = pcall(parseValue)
    if ok then return result end
    return nil
end

return JSON
