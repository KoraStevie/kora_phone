KoraPhone.Permissions = {}

function KoraPhone.Permissions.requirePlayer(source)
    local citizenId = KoraPhone.GetCitizenId(source)
    if not citizenId then return nil, PhoneError(PhoneConstants.Errors.UNAUTHORIZED, 'Character is not loaded') end
    if not KoraPhone.HasPhone(source) then return nil, PhoneError(PhoneConstants.Errors.PHONE_REQUIRED, 'A phone is required') end
    return citizenId
end

-- A phone with a PIN refuses requests until the session is unlocked. Answering or ending a
-- call passes allowLocked so a locked phone can still take a call.
-- Resolves through the SELECTED handset (Handsets.require), never an unordered
-- findByCitizenId: with several handsets owned, `LIMIT 1` on owner_citizenid could
-- return a different handset's device and silently attach app data to it.
function KoraPhone.Permissions.requireDevice(source, allowLocked)
    local citizenId, err = KoraPhone.Permissions.requirePlayer(source)
    if not citizenId then return nil, err end
    return KoraPhone.Handsets.require(source, allowLocked)
end
