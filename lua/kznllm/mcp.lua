local M = {}

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
      -- print('Response: ' .. vim.inspect(response))
      if not response.id then
        -- TODO: Handle notifications
        return
      end
      local handler = responses[response.id]
      if not handler then
        error('No handler for response: ' .. vim.inspect(response))
        return
      end
      responses[response.id] = nil
      handler(response)
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
    if not options then
      options = {}
    end
    nextRequestId = nextRequestId + 1
    local id = nextRequestId
    if not params or params == {} then
      params = vim.empty_dict()
    end
    -- Setup a response handler
    responses[id] = function(response)
      -- Wait for response
      if response.error then
        error('Error response from server: ' .. vim.inspect(response.error))
        return
      end
      if options.callback then
        options.callback(response.result)
      end
    end
    -- vim.json.encode escapes forward slashes, which is not supported by the
    -- server, so we need to unescape them.
    local encodedRequest = vim.json.encode({
      jsonrpc = "2.0",
      method = method,
      params = params,
      id = id
    }):gsub('\\/', '/') .. '\n'
    process:write(encodedRequest)
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

function Client(name, server, clientCapabilities)
  if not clientCapabilities or clientCapabilities == {} then
    clientCapabilities = vim.empty_dict()
  end

  local C = {
    name = name,
    clientCapabilities = clientCapabilities,
    server = server,
    isInitialized = false,
    onInitializedCallback = function() end,
    resources = {},
    tools = {},
  }

  local result = server:request(
    'initialize',
    {
      protocolVersion = LATEST_PROTOCOL_VERSION,
      clientInfo = {
        name = 'kznllm',
        version = '0.1.0'
      },
      capabilities = clientCapabilities,
    },
    {
      callback = function(result)
        if not result then
          server:kill()
          return
        end
        if not protocolVersionIsSupported(result.protocolVersion) then
          error('Servers protocol version is not supported: ' .. vim.inspect(result.protocolVersion))
          server:kill()
          return
        end
        C.serverCapabilities = result.capabilities
        C.serverVersion = result.serverInfo
        C.isInitialized = true
        C:onInitializedCallback()
      end
    }
  )

  function C:onInitialized(callback)
    if C.isInitialized then
      callback(C)
    else
      local newCallback = callback
      local oldCallback = C.onInitializedCallback
      C.onInitializedCallback = function()
        oldCallback(C)
        newCallback(C)
      end
    end
  end

  function C:kill()
    self.server:kill()
  end

  function C:supportsCapability(capabilities, path)
    local result = capabilities
    for segment in string.gmatch(path, "(%w+)") do
      result = result[segment]
      if not result then
        return false
      end
    end
    if result then
      return true
    end
    return false
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

    if not capabilities then
      error('Method ' .. method .. ' is not supported')
      return false
    end

    for _, capability in ipairs(capabilities) do
      if not self:supportsCapability(self.serverCapabilities, capability) then
        error('Server does not support ' .. capability .. ' (required for ' .. method .. ')')
        return false
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

    if not capabilities then
      error('Notification ' .. method .. ' is not supported')
      return false
    end

    for _, capability in ipairs(capabilities) do
      if not self:supportsCapability(self.clientCapabilities, capability) then
        error('Client does not support ' .. path ..' notifications (required for ' .. method .. ')')
        return false
      end
    end
    return true
  end

  function C:request(method, params, options)
    if not self:assertCapabilityForMethod(method) then
      return
    end
    return self.server:request(method, params, options)
  end

  -- Emits a notification, which is a one-way message that does not expect a response.
  function C:notification(method, params)
    if not self:assertNotificationCapability(method) then
      return
    end
    self.server:notification(method, params)
  end

  function C:ping(options)
    return self:request('ping', options)
  end

  function C:complete(params, options)
    return self:request('completion/complete', params, options)
  end

  function C:setLoggingLevel(level, options)
    return self:request('logging/setLevel', { level = level }, options)
  end

  function C:getPrompt(params, options)
    return self:request('prompts/get', params, options)
  end

  function C:listPrompts(options)
    return self:request('prompts/list', {}, options)
  end

  function C:listResources(options)
    return self:request('resources/list', {}, options)
  end

  function C:listResourceTemplates(params, options)
    return self:request('resources/templates/list', params, options)
  end

  function C:readResource(params, options)
    return self:request('resources/read', params, options)
  end

  function C:subscribeResource(params, options)
    return self:request('resources/subscribe', params, options)
  end

  function C:unsubscribeResource(params, options)
    return self:request('resources/unsubscribe', params, options)
  end

  function C:callTool(params, options)
    return self:request('tools/call', params, options)
  end

  function C:listTools(options)
    return self:request('tools/list', params, options)
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
function M.anthropicToOpenAiTool(anthropicTool)
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

function M.anthropicToOpenAiToolUse(anthropicToolUse)
  return {
    id = anthropicToolUse.id,
    type = 'function',
    ['function'] = {
      name = anthropicToolUse.name,
      arguments = anthropicToolUse.arguments,
    }
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
  isInitialized = false,
  allowedTools = {},
  clients = {},
  clientsByTool = {},
}

function Host:init()
  if self.isInitialized then
    -- Already loaded
    return self
  end
  self.isInitialized = true

  local config = readConfigFile('.mcpconfig.json')
  if not config or config == {} then
    vim.schedule(function()
      vim.notify('No .mcpconfig.json file found', vim.log.levels.DEBUG)
    end)
    return
  end

  if not config.mcpServers or config.mcpServers == {} then
    vim.schedule(function()
      vim.notify('No mcpServers found in .mcpconfig.json', vim.log.levels.DEBUG)
    end)
    return
  end

  self.clientsByTool = {}
  for serverName, serverConfig in pairs(config.mcpServers) do
    vim.schedule(function()
      vim.notify('Initializing MCP Client: ' .. serverName, vim.log.levels.DEBUG)
    end)
    local client = Client(serverName, Server(serverConfig.command, serverConfig.args, serverConfig.env))
    self.clients[serverName] = client
    client:onInitialized(function()
      client:listTools({
        callback = function(result)
          for _, tool in ipairs(result.tools) do
            self.clientsByTool[tool.name] = client
            table.insert(client.tools, M.anthropicToOpenAiTool(tool))
          end
        end
      })
    end)
  end

  return self
end

function Host:getAllTools()
  local tools = {}
  for serverName, client in pairs(self.clients) do
    for _, tool in ipairs(client.tools) do
      table.insert(tools, tool)
    end
  end
  return tools
end

function Host:runTool(toolUse, callback)
  local client = self.clientsByTool[toolUse.name]
  if not client then
    error('Tool not found: ' .. toolUse.name)
    return
  end

  if self.allowedTools[toolUse.name] then
    client:callTool(toolUse, { callback = callback })
    return
  end

  vim.schedule(function()
    vim.ui.select(
      { 'Allow for this session', 'Allow once', 'Deny' },
      {
        prompt = 'Run ' .. toolUse.name .. ' from ' .. client.name,
        default = 'Deny',
      },
      function(choice)
        if choice == 'Deny' then
          callback({ isError = true, content = 'Tool call denied' })
          return
        end
        if choice == 'Allow for this session' then
          self.allowedTools[toolUse.name] = true
        end
        client:callTool(toolUse, { callback = callback })
      end
    )
  end)
end

function Host:killAllClients()
  for serverName, client in pairs(self.clients) do
    vim.schedule(function()
      vim.notify('Killing MCP Client: ' .. serverName, vim.log.levels.DEBUG)
    end)
    client:kill()
  end
  self.clients = {}
end

-- Export the singleton
M.Host = Host
return M
