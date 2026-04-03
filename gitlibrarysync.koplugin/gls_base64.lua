local Base64 = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Base64.encode(input)
    input = input or ""
    local out = {}
    for i = 1, #input, 3 do
        local a = input:byte(i) or 0
        local b = input:byte(i + 1) or 0
        local c = input:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        local pad = math.min(2, i + 2 - #input)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        table.insert(out, alphabet:sub(c1 + 1, c1 + 1))
        table.insert(out, alphabet:sub(c2 + 1, c2 + 1))
        table.insert(out, pad >= 2 and "=" or alphabet:sub(c3 + 1, c3 + 1))
        table.insert(out, pad >= 1 and "=" or alphabet:sub(c4 + 1, c4 + 1))
    end
    return table.concat(out)
end

return Base64
