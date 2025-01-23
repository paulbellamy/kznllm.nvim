local BaseProvider = require('kznllm.specs')
local utils = require('kznllm.utils')
local openai = require('kznllm.specs.openai')

local M = {}

---@class OllamaProvider : BaseProvider
---@field make_curl_args fun(self, opts: OllamaCurlOptions)
M.OllamaProvider = {}

---@param opts? BaseProviderOptions
---@return OllamaProvider
function M.OllamaProvider:new(opts)
  local o = opts or {}
  local instance = BaseProvider:new({
    base_url = o.base_url or 'http://localhost:11434'
  })

  -- Set proper metatable for inheritance
  setmetatable(instance, { __index = self })
  setmetatable(self, { __index = BaseProvider })

  return instance
end

function M.OllamaProvider.handle_sse_stream(buf)
  -- based on sse spec (OpenAI spec uses data-only server-sent events)
  local content = {}

  for data in buf:gmatch('({.-})\n') do
    -- if data and data:match '"delta":' then
    local json = vim.json.decode(data)
    -- sglang server returns the role as one of the events and it becomes `vim.NIL`, so we have to handle it here
    if not json.message then
      vim.print(data)
      return
    end

    local message = json.message

    if message.content and message.content ~= '' then
      table.insert(content, { type = 'text', text = message.content })
    elseif message.tool_calls then
      for _, tool_call in ipairs(message.tool_calls) do
        table.insert(
          content,
          {
            type = 'tool_call',
            tool_call = {
              type = 'tool_use',
              id = tool_call.id,
              name = tool_call['function'].name,
              arguments = vim.json.decode(tool_call['function'].arguments),
            }
          }
        )
      end
    end
  end

  return content
end

function M.OllamaProvider.handle_tool_result(previous_request, response, tool_result, is_error)
  -- Add the model's response to the conversation history
  local text = {}
  local tool_calls = {}
  for _, choice in ipairs(response) do
    if choice.type == 'text' then
      table.insert(text, choice.text)
    elseif choice.type == 'tool_call' then
      table.insert(tool_calls, choice.tool_call)
    end
  end
  if #text > 0 or #tool_calls > 0 then
    table.insert(previous_request.data.messages, {
      role = 'assistant',
      content = table.concat(text),
      tool_calls = tool_calls,
    })
  end
  -- add the tool result to the conversation history
  if is_error then
    table.insert(previous_request.data.messages, {
      role = 'tool',
      content = 'An error occurred while calling the tool',
    })
  end
  if tool_result then
    table.insert(previous_request.data.messages, {
      role = 'tool',
      content = tool_result,
    })
  end
  return previous_request
end


---@class OllamaPresetConfig
---@field id string
---@field description string
---@field curl_options OllamaCurlOptions

---@class OllamaPresetSystemTemplate
---@field path string

---@class OllamaPresetMessageTemplate
---@field type OllamaMessageContentType
---@field role OllamaMessageRole
---@field path string

---@class OllamaPresetBuilder : BasePresetBuilder
---@field provider OllamaProvider
---@field system_templates OllamaPresetSystemTemplate[]
---@field message_templates OllamaPresetMessageTemplate[]
---@field debug_template? string
---@field headers OllamaHeaders
---@field params OllamaParameters
M.OllamaPresetBuilder = {}

local ollama_template_path = utils.join_path({ utils.TEMPLATE_PATH, 'ollama' })

---@param opts? { provider: OllamaProvider, headers: OllamaHeaders, params: OllamaParameters, debug_template_path: string }
---@return OllamaPresetBuilder
function M.OllamaPresetBuilder:new(opts)
  local o = opts or {}
  o.provider = o.provider or M.OllamaProvider:new()
  o.debug_template_path = o.debug_template_path or utils.join_path({ ollama_template_path, 'debug.xml.jinja' })
  o.headers = o.headers or { endpoint = '/api/chat' }
  o.params = (opts and opts.params) and opts.params or {
    ['model'] = 'llama3.2',
  }
  return openai.OpenAIPresetBuilder:new(o)
end

return M
