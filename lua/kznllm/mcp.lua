local LATEST_PROTOCOL_VERSION = "2024-11-05"
local SUPPORTED_PROTOCOL_VERSIONS = { LATEST_PROTOCOL_VERSION, "2024-10-07" }

local DEFAULT_TIMEOUT = 5000 -- 5 seconds

local function protocolVersionIsSupported(needle)
    for _, version in ipairs(SUPPORTED_PROTOCOL_VERSIONS) do
        if version == needle then
            return true
        end
    end
    return false
  end

local function Server(cmd, args, env, onExit)
  local nextRequestId = 0
  local responses = {}
  local exec = { cmd, unpack(args or {}) }
  local process = vim.system(exec, {
    env = env,
    stdin = true,
    stdout = function(err, data)
      if data == nil then
        return
      end
      -- Handle data
      local response = vim.json.decode(data)
      if response == nil then
        return
      end
      if not response.id then
        -- TODO: Handle notifications
        return
      end
      responses[response.id] = response
    end,
    stderr = function(err, data)
      if data == nil then
        return
      end
      -- Handle error
      print(data)
    end,
    text = true,
  },
  onExit)
  local S = {}

  function S:request(method, params, options)
    nextRequestId = nextRequestId + 1
    local id = nextRequestId
    if not params or params == {} then
      params = vim.empty_dict()
    end
    process:write(vim.json.encode({
      jsonrpc = "2.0",
      method = method,
      params = params,
      id = id
    }) .. '\n')
    -- Wait for response
    -- TODO: Do this asynchronously to not block the main thread
    local waitOk = vim.wait(options.timeout or DEFAULT_TIMEOUT, function()
      return responses[id] ~= nil
    end)
    if not waitOk then
      error('Timeout waiting for response from MCP server')
      return
    end
    local response = responses[id]
    assert(response ~= nil, 'Response is nil')
    responses[id] = nil
    if response.error then
      error('Error response from server: ' .. vim.inspect(response.error))
      return
    end
    return response.result
  end

  function S:notification(method, params)
    if not params or params == {} then
      params = vim.empty_dict()
    end
    process:write(vim.json.encode({
      jsonrpc = "2.0",
      method = method,
      params = params,
    }) .. '\n')
  end

  function S:kill()
    -- Close stdin
    process:write(nil)
    -- Kill the server
    process:kill(9)
  end
  return S
end

function Client(server, capabilities)
  if not capabilities or capabilities == {} then
    capabilities = vim.empty_dict()
  end
  local result = server:request('initialize', {
    protocolVersion = LATEST_PROTOCOL_VERSION,
    clientInfo = {
      name = 'kznllm',
      version = '0.1.0'
    },
    capabilities = capabilities,
  })
  if result == nil then
    server:kill()
    return
  end
  if not protocolVersionIsSupported(result.protocolVersion) then
    error('Servers protocol version is not supported: ' .. vim.inspect(result.protocolVersion))
    server:kill()
    return
  end

  local C = {
    server = server,
    serverCapabilities = result.capabilities,
    serverVersion = result.serverInfo,
  }

  function C:kill()
    self.server:kill()
  end

  function C:assertCapabilityForMethod(method)
    local requirements = {
      ['logging/setLevel'] = {'logging'},
      ['prompts/get'] = {'prompts'},
      ['prompts/list'] = {'prompts'},
      ['resources/list'] = {'resources'},
      ['resources/templates/list'] = {'resources'},
      ['resources/read'] = {'resources'},
      ['resources/subscribe'] = {'resources', 'resources/subsribe'},
      ['resources/unsubscribe'] = {'resources'},
      ['tools/call'] = {'tools'},
      ['tools/list'] = {'tools'},
      ['completion/complete'] = {'prompts'},
      ['initialize'] = {},
      ['ping'] = {},
    }
    local capabilities = requirements[method]

    if capabilities == nil then
      error('Method ' .. method .. ' is not supported')
      return false
    end

    for _, path in ipairs(capabilities) do
       for capability in string.gmatch(path, "(%w+)") do
        if not self.serverCapabilities[capability] then
          error('Server does not support ' .. path .. ' (required for ' .. method .. ')')
          return false
        end
       end
    end
    return true
  end

  function C:assertNotificationCapability(method)
    local requirements = {
      ['notifications/roots/list_changed'] = {'roots/list_changed'},
      ['notifications/initialized'] = {},
      ['notifications/cancelled'] = {},
      ['notifications/progress'] = {},
    }
    local capabilities = requirements[method]

    if capabilities == nil then
      error('Notification ' .. method .. ' is not supported')
      return false
    end

    for _, path in ipairs(capabilities) do
       for capability in string.gmatch(path, "(%w+)") do
        if not self.serverCapabilities[capability] then
          error('Client does not support ' .. path ..' notifications (required for ' .. method .. ')')
          return false
        end
       end
     end
     return true
  end

  function C:request(method, params)
    if not self:assertCapabilityForMethod(method) then
      return
    end
    return self.server:request(method, params)
  end

  -- Emits a notification, which is a one-way message that does not expect a response.
  function C:notification(method, params)
    if not self:assertNotificationCapability(method) then
      return
    end
    self.server:notification(method, params)
  end

  function C:ping()
    return self:request('ping')
  end

  function C:complete(params)
    return self:request('completion/complete', params)
  end

  function C:setLoggingLevel(level)
    return self:request('logging/setLevel', { level = level })
  end

  function C:getPrompt(params)
    return self:request('prompts/get', params)
  end

  function C:listPrompts(params)
    return self:request('prompts/list', params)
  end

  function C:listResources(params)
    return self:request('resources/list', params)
  end

  function C:listResourceTemplates(params)
    return self:request('resources/templates/list', params)
  end

  function C:readResource(params)
    return self:request('resources/read', params)
  end

  function C:subscribeResource(params)
    return self:request('resources/subscribe', params)
  end

  function C:unsubscribeResource(params)
    return self:request('resources/unsubscribe', params)
  end

  function C:callTool(params)
    return self:request('tools/call', params)
  end

  function C:listTools(params)
    return self:request('tools/list', params)
  end

  function C:sendRootsListChanged()
    return self.server:notification('notifications/roots/list_changed')
  end

  -- Finish initialization, and notify server we're ready
  C:notification('notifications/initialized')

  return C
end

-- Ollama uses openai API-style tools, but MCP uses anthropic-style tools, so
-- we need to convert them.
function anthropicToOpenAiTool(anthropicTool)
  return {
    type = 'function',
    ['function'] = {
      name = anthropicTool.name,
      description = anthropicTool.description,
      parameters = {
        type = 'object',
        properties = anthropicTool.inputSchema.properties,
        required = anthropicTool.inputSchema.required or {},
      },
    },
  }
end

function anthropicToOpenAiToolUse(anthropicToolUse)
  return {
    id = anthropicToolUse.id,
    type = 'function',
    ['function'] = {
      name = anthropicToolUse.name,
      arguments = anthropicToolUse.input,
    }
  }
end

function openAIToAnthropicToolUse(openAiToolUse)
  return {
      type = 'tool_use',
      id = openAiToolUse.id,
      name = openAiToolUse['function'].name,
      input = openAiToolUse['function'].arguments,
  }
end

---project scoped .mcpconfig.json support
---
---Retrieves .mcpconfig.json files based on the current working directory.
---
--- Schema:
--- {
---   "mcpServers": {
---     "github": {
---       "command": "npx",
---       "args": ["-y", "@modelcontextprotocol/server-github"],
---       "env": {
---         "GITHUB_PERSONAL_ACCESS_TOKEN": "YOUR_GITHUB_ACCESS_TOKEN"
---       }
---     },
---     "postgres": {
---       "command": "npx",
---       "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/postgres"]
---     }
---   }
--- }
---
---@return json object for the content of the .mcpconfig.json file if found in the working directory
local function readConfigFile(filename)
  if vim.fn.executable('fd') ~= 1 then
    -- only use mcpconfig if `fd` is available
    return
  end

  local fd_dir_result = vim.system({ 'fd', '-tf', '-tl', '-HI', filename, '-1' }):wait()
  local file = vim.trim(fd_dir_result.stdout)
  if file == '' then
    return
  end
  local content = vim.fn.readfile(file)
  if #content == 0 then
    return
  end
  return vim.json.decode(table.concat(content, '\n'))
end

local Host = {
  clients = {},
}

function Host:loadAllClients()
  local config = readConfigFile('.mcpconfig.json')
  if not config or config == {} then
    error('No .mcpconfig.json file found')
    return
  end

  if not config.mcpServers or config.mcpServers == {} then
    error('No mcpServers found in .mcpconfig.json')
    return
  end

  for serverName, serverConfig in pairs(config.mcpServers) do
    print('Initializing MCP Client: ' .. serverName)
    local client = Client(Server(serverConfig.command, serverConfig.args, serverConfig.env))
    self.clients[serverName] = client
    local response = client:ping()
    print('[' .. serverName .. '] Ping Response: ' .. vim.inspect(response))
  end
end

function Host:killAllClients()
  for serverName, client in pairs(self.clients) do
    print('Killing MCP Client: ' .. serverName)
    client:kill()
  end
  self.clients = {}
end

-- Export the singleton
local M = {}
M.host = Host
return M
