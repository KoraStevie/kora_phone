KoraPhone = KoraPhone or {}
local Calls = {}

local function validCall(call)
    return type(call) == 'table'
        and type(call.id) == 'string'
        and #call.id == 36
        and type(call.status) == 'string'
end

local function participantEvent(action, call)
    if not validCall(call) then return false end
    KoraPhone.State.activeCall = call
    KoraPhone.SendNui(action, call)
    return true
end

RegisterNetEvent('kora_phone:client:calls:incoming', function(call)
    if KoraPhone.State.activeCall and KoraPhone.State.activeCall.id ~= (call and call.id) then return end
    if participantEvent('calls:incoming', call) and not KoraPhone.State.open then
        if KoraPhone.State.quiet then
            -- Do Not Disturb: leave the phone closed and drop a silent note in the notification shade.
            KoraPhone.SendNui('notification:push', { title = tostring(call.remoteNumber or 'Unknown'), body = 'Incoming call · Do Not Disturb', app = 'phone' })
        else
            -- The UI is hidden while the phone is closed, so open it or the call would ring unseen.
            KoraPhone.Open()
        end
    end
end)

RegisterNetEvent('kora_phone:client:calls:outgoing', function(call)
    if KoraPhone.State.activeCall and KoraPhone.State.activeCall.id ~= (call and call.id) then return end
    participantEvent('calls:outgoing', call)
end)

RegisterNetEvent('kora_phone:client:calls:accepted', function(call)
    if not validCall(call) or type(call.voiceChannel) ~= 'number' then return end
    local current = KoraPhone.State.activeCall
    if current and current.id ~= call.id then return end
    KoraPhone.State.activeCall = call
    participantEvent('calls:accepted', call)
end)

-- A WebRTC offer/answer/ICE candidate from the other side of the call, passed straight to the NUI's own peer connection.
RegisterNetEvent('kora_phone:client:calls:signal', function(signal)
    if type(signal) ~= 'table' then return end
    if not KoraPhone.State.activeCall or KoraPhone.State.activeCall.id~=signal.id then return end
    KoraPhone.SendNui('videoSignal', signal)
end)

RegisterNetEvent('kora_phone:client:calls:videoControl',function(control)
    if type(control)=='table' and KoraPhone.State.activeCall and KoraPhone.State.activeCall.id==control.id then
        KoraPhone.SendNui('videoControl',control)
    end
end)

-- Remote mute rides pma-voice's isPlayerMuted/toggleMutePlayer client exports, which
-- kora_voice deliberately does not provide in either its native or its pma-voice
-- compat surface. The control stays inert unless a real pma-voice is the provider.
local function muteResource()
    local voice = KoraPhone.Voice
    if not voice or not voice.RemoteMuteResource then return nil end
    return voice.RemoteMuteResource()
end

local mutedPeer
local function clearRemoteMute()
    local resource = muteResource()
    if mutedPeer and resource then
        local ok,muted=pcall(function() return exports[resource]:isPlayerMuted(mutedPeer) end)
        if ok and muted then pcall(function() exports[resource]:toggleMutePlayer(mutedPeer) end) end
    end
    mutedPeer=nil
end
RegisterNetEvent('kora_phone:client:calls:remoteMute',function(data)
    if not KoraPhone.State.activeCall or type(data)~='table' or KoraPhone.State.activeCall.id~=data.id then return end
    if data.muted then
        local resource = muteResource()
        if not resource then return end
        local ok,muted=pcall(function() return exports[resource]:isPlayerMuted(data.source) end)
        if not ok then return end
        if not muted then exports[resource]:toggleMutePlayer(data.source); mutedPeer=data.source end
    else clearRemoteMute() end
end)

RegisterNetEvent('kora_phone:client:calls:ended', function(payload)
    if type(payload) ~= 'table' or type(payload.id) ~= 'string' then return end
    local current = KoraPhone.State.activeCall
    if current and current.id ~= payload.id then return end
    KoraPhone.Voice.Leave()
    clearRemoteMute()
    KoraPhone.State.activeCall = nil
    KoraPhone.SendNui('calls:ended', payload)
end)

function Calls.Cleanup(notifyServer)
    clearRemoteMute()
    local call = KoraPhone.State.activeCall
    KoraPhone.Voice.Leave()
    KoraPhone.State.activeCall = nil
    if notifyServer and call and call.id then
        TriggerServerEvent('kora_phone:server:calls:hangup', call.id)
    end
end

function Calls.IsActive(callId)
    local call = KoraPhone.State.activeCall
    return call ~= nil and (callId == nil or call.id == callId)
end

KoraPhone.Calls = Calls
