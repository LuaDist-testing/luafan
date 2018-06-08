local tcpd = require "fan.tcpd"
local connector = require "fan.connector"

local string = string
local table = table
local type = type
local coroutine = coroutine
local tonumber = tonumber

local function request(method, check_body, args)
    if type(args) == "string" then
        args = {url = args}
    end
    local _, _, schema, host, port, path = string.find(args.url, "([^:]+)://([^:]+):(%d+)(.*)")
    if not host then
        _, _, schema, host, path = string.find(args.url, "([^:]+)://([^:/]+)(.*)")
        if schema == "https" then
            port = 443
        else
            port = 80
        end
    end
    
    if schema == "https" then
        args.ssl = true
        if not args.cainfo then
            args.cainfo = "cert.pem"
        end
    end

    if not args.headers["Host"] then
        args.headers["Host"] = host
    end

    print(host, port)
    
    if #path == 0 then
        path = "/"
    end
    
    local headers = {}
    local ret = {responseCode = 0, headers = headers}
    
    local version
    local code
    local message
    
    local first_line_completed = false
    local header_complete = false
    local accepted = false
    local disconnected = false
    
    local content_length = 0
    local chunked = false
    
    local conn
    local conn_connected = false
    
    conn = connector.connect(string.format("tcp://%s:%d", host, port), args)
    
    local t = {string.format("%s %s HTTP/1.0\r\n", method:upper(), path)}
    if not args.headers or type(args.headers) ~= "table" then
        args.headers = {}
    end
    
    if check_body then
        if args.onbodylength and type(args.onbodylength) == "function" and args.onbody and type(args.onbody) == "function" then
            args.headers["Content-Length"] = args:onbodylength()
        else
            if args.body and type(args.body) == "string" then
                args.headers["Content-Length"] = #(args.body)
            else
                args.headers["Content-Length"] = 0
                args.body = ""
            end
        end
    end
    if args.headers then
        for k, v in pairs(args.headers) do
            table.insert(t, string.format("%s: %s\r\n", k, v))
        end
    end
    table.insert(t, "\r\n")
    
    conn:send(table.concat(t))
    
    if check_body then
        if args.onbody then
            args:onbody(conn)
        else
            conn:send(args.body)
        end
    end
    
    local input
    while not header_complete do
        input = conn:receive()
        if input then
            local line, breakflag = input:readline()
            if not breakflag then
                input = conn:receive(#line + 2)
            elseif not line then
                break
            else
                if #(line) == 0 then
                    header_complete = true
                    if args.onheader then
                        local st, msg = pcall(args.onheader, ret)
                        if not st then
                            print(msg)
                        elseif msg == "break" then
                            ret.error = "canceled"
                            conn:close()
                            return ret
                        end
                    end
                else
                    if first_line_completed then
                        local k, v = string.match(line, "([^:]+):[ ]*(.*)")
                        k = string.lower(k)
                        if k == "content-length" then
                            content_length = tonumber(v)
                        elseif k == "transfer-encoding" and v == "chunked" then
                            chunked = true
                        end
                        local old = headers[k]
                        if old then
                            if type(old) == "table" then
                                table.insert(old, v)
                            else
                                headers[k] = {old, v}
                            end
                        else
                            headers[k] = v
                        end
                    else
                        version, code, message = string.match(line, "HTTP/([0-9.]+) (%d+) (.+)")
                        first_line_completed = true
                        ret.responseCode = code
                        ret.responseMessage = message
                    end
                end
            end
        else
            break
        end
    end
    
    if header_complete then
        local t = {}
        local count = 0
        
        if chunked then
            local line_total = 0
            repeat
                if line_total > 0 then
                    local buff = input:GetBytes(line_total)
                    if buff then
                        table.insert(t, buff)
                        input = conn:receive(2)
                        if input then
                            local line, breakflag = input:readline()
                            if breakflag ~= "\r\n" then
                                ret.error = "checked error 1."
                                break
                            end
                        end
                        line_total = 0
                    end
                else
                    local line, breakflag = input:readline()
                    if line and breakflag == "\r\n" then
                        line_total = tonumber(line, 16)
                        if line_total == 0 then
                            input = conn:receive(2)
                            if input then
                                local line, breakflag = input:readline()
                                if breakflag == "\r\n" then
                                    ret.body = table.concat(t)
                                else
                                    ret.error = "chunked error 2."
                                end
                            else
                                ret.error = conn.disconnected_message
                            end
                            
                            break
                        end
                    end
                end
                
                input = conn:receive()
                if not input then
                    ret.error = "chunked error 3."
                end
            until not input
        else
            repeat
                local buff = input:GetBytes()
                if buff then
                    table.insert(t, buff)
                    count = count + #buff
                end
                
                input = conn:receive()
            until count >= content_length or not input
            
            if count == content_length then
                ret.body = table.concat(t)
            else
                ret.error = conn.disconnected_message
            end
        end
    else
        ret.error = conn.disconnected_message
    end
    
    conn:close()
    
    return ret
end

return {get = function(args)
        return request("GET", false, args)
    end, post = function(args)
        return request("POST", true, args)
    end, put = function(args)
        return request("PUT", true, args)
    end, head = function(args)
        return request("HEAD", false, args)
    end, update = function(args)
        return request("UPDATE", false, args)
    end, delete = function(args)
        return request("DELETE", false, args)
    end}
