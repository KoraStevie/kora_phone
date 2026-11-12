KoraPhone = KoraPhone or {}
local Voice = { provider = 'none', channel = nil, muted = false, speaker = false }

local function resourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- kora_voice is the call-audio provider and is checked FIRST: its manifest does
-- `provide 'pma-voice'`, so GetResourceState('pma-voice') also reports started
-- while it is running. Checking pma-voice first would misidentify the provider.
function Voice.Detect()
    if resourceStarted('kora_voice') then
        Voice.provider = 'kora_voice'
    elseif resourceStarted('pma-voice') then
        Voice.provider = 'pma-voice'
    else
        Voice.provider = 'none'
    end
    return Voice.provider
end

-- Only a real pma-voice exposes the isPlayerMuted/toggleMutePlayer client exports
-- the remote-mute control needs; kora_voice registers them in neither its native
-- nor its pma-voice compat surface.
function Voice.RemoteMuteResource()
    return Voice.Detect() == 'pma-voice' and 'pma-voice' or nil
end

function Voice.Leave()
    Voice.channel = nil
    Voice.muted = false
    Voice.speaker = false
end

function Voice.SetMuted(value)
    -- Neither kora_voice nor pma-voice exposes a call-only microphone mute. The native
    -- per-player mute API alters receive state, not this player's microphone.
    Voice.muted = false
    return false, 'CALL_MUTE_UNSUPPORTED'
end

function Voice.SetSpeaker(value)
    -- Speaker is presentation/volume policy only; call routing stays private.
    Voice.speaker = value == true
    return true
end

function Voice.Capabilities()
    return { provider = Voice.Detect(), available = Voice.provider ~= 'none', remoteMute = Voice.RemoteMuteResource() ~= nil }
end

KoraPhone.Voice = Voice
