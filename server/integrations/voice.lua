KoraPhone = KoraPhone or {}
KoraPhone.Integrations = KoraPhone.Integrations or {}

local Voice = {}
KoraPhone.Integrations.Voice = Voice

-- kora_voice is the call-audio provider and is checked FIRST: its manifest does
-- `provide 'pma-voice'`, so GetResourceState('pma-voice') also reports started
-- while it is running. Checking pma-voice first would misidentify the provider.
-- A real pma-voice (same setPlayerCall API) remains accepted as a fallback.
local function provider()
    if GetResourceState('kora_voice') == 'started' then return 'kora_voice' end
    if GetResourceState('pma-voice') == 'started' then return 'pma-voice' end
end

Voice.provider = provider

local function invoke(name, source, channel)
    local resource = provider()
    if not resource then return false end
    local ok, result = pcall(function()
        return exports[resource][name](exports[resource], source, channel)
    end)
    -- kora_voice returns true or (false, reason); pma-voice returns nothing on success.
    return ok and result ~= false
end

-- Call membership is assigned only by the server. kora_voice exposes this through
-- its native setPlayerCall export (and its pma-voice compatibility surface when
-- Config.compat.pmaVoice is enabled there); a real pma-voice provides the same API.
function Voice.join(firstSource, secondSource, channel)
    if not invoke('setPlayerCall', firstSource, channel) then return false end
    if invoke('setPlayerCall', secondSource, channel) then return true end
    Voice.leave(firstSource)
    return false
end

function Voice.leave(source, channel)
    if not source then return end
    -- removePlayerFromCall exists on both providers; pma-voice also treats
    -- setPlayerCall(src, 0) as leave.
    if provider() == 'kora_voice' then
        invoke('removePlayerFromCall', source, channel)
    else
        invoke('setPlayerCall', source, 0)
    end
end
