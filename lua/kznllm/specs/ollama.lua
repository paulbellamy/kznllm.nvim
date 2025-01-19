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
  o.base_url = o.base_url or 'http://localhost:11434'
  return openai.OpenAIProvider:new(o)
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
