-- Handsets own local profiles; SIMs route numbers; cloud snapshots never grant number ownership.
KoraPhone.Handsets = { selected={}, busy={}, wifi={}, ready=false }
local H = KoraPhone.Handsets
local function random() return exports[GetCurrentResourceName()]:randomHex(16) end
local function fail(message) return PhoneError(PhoneConstants.Errors.FORBIDDEN, message) end
local function row(sql, params) return MySQL.single.await(sql, params or {}) end
local function query(sql, params) return MySQL.query.await(sql, params or {}) or {} end
local function update(sql, params) return MySQL.update.await(sql, params or {}) end
local function cid(src) return KoraPhone.GetCitizenId(src) end
local function inventory(src) local p=KoraPhone.GetPlayer(src); return p and p.items or {} end
local function sentinel(id) return '@' .. id:sub(1,20) end
local function phoneRow(id)
    local device=row([[SELECT d.id,d.owner_citizenid AS ownerCitizenId,d.phone_number AS phoneNumber,
        d.settings_json AS settingsJson,d.label,(d.pin_hash IS NOT NULL OR h.pin_kdf IS NOT NULL) AS hasPin,
        h.id AS handsetId,h.model,h.account_id AS accountId,h.face_citizenid AS faceCitizenId,
        h.pin_kdf AS pinKdf,h.is_reset AS isReset,h.cloud_revision AS cloudRevision
        FROM phone_handsets h JOIN phone_devices d ON d.id=h.device_id WHERE h.id=?]],{id})
    if device and type(device.settingsJson)=='table' then device.settingsJson=json.encode(device.settingsJson) end
    return device
end
local function itemFor(src,id)
    for _,item in pairs(inventory(src)) do
        if Config.Handsets[item.name] and item.info and item.info.handsetId==id then return item end
    end
end
local function inv(src,request)
    return exports.kora_inventory:PhoneItemTransaction(src,request)
end
function H.revoke(src,reason)
    local session=KoraPhone.Sessions.bySource[src]
    local deviceId=session and session.deviceId
    local callId=deviceId and KoraPhone.Services.Calling.callByDevice and KoraPhone.Services.Calling.callByDevice[deviceId]
    KoraPhone.Sessions.close(src)
    H.selected[src]=nil; H.wifi[src]=nil
    if KoraPhone.Integrations and KoraPhone.Integrations.Voice then KoraPhone.Integrations.Voice.leave(src) end
    TriggerClientEvent('kora_phone:client:sessionRevoked',src)
    -- Item observers run inside inventory commits; retire SQL call state outside that lock.
    if callId then SetTimeout(0,function() KoraPhone.Services.Calling.disconnectDevice(deviceId,reason or 'handset_changed',callId) end) end
end
local function syncSim(src,item,device)
    -- Inventory metadata is the insertion authority. SQL is rebuilt on every use after a crash.
    local simId=item.info and item.info.phoneSimId
    local sim=simId and row('SELECT * FROM phone_sims WHERE id=?',{simId})
    if sim and sim.status=='blocked' and H.reconcileReplacement then
        H.reconcileReplacement(sim.id,device.handsetId)
        sim=row('SELECT * FROM phone_sims WHERE id=?',{simId})
    end
    local occupied=sim and sim.handset_id and sim.handset_id~=device.handsetId
    if occupied then return nil end -- duplicate metadata must never acquire another number
    local number=sim and sim.status=='active' and sim.phone_number or sentinel(device.handsetId)
    if device.phoneNumber~=number or (sim and sim.handset_id~=device.handsetId) then
        local statements={
            {query='UPDATE phone_sims SET handset_id=NULL WHERE handset_id=? AND id<>?',values={device.handsetId,simId or ''}},
            {query='UPDATE phone_devices SET phone_number=? WHERE id=?',values={number,device.id}}
        }
        if sim then statements[#statements+1]={query='UPDATE phone_sims SET handset_id=? WHERE id=?',values={device.handsetId,sim.id}} end
        if not MySQL.transaction.await(statements) then return nil end
        local session=KoraPhone.Sessions.bySource[src]
        if session then KoraPhone.Services.Calling.disconnect(src,'sim_changed'); KoraPhone.Sessions.close(src) end
    end
    device.phoneNumber=number; device.sim=sim; device.cellular=sim~=nil and sim.status=='active'
    return device
end
function H.current(src,provision)
    if not H.ready or not cid(src) then return nil end
    local id=H.selected[src]
    local item=id and itemFor(src,id)
    if id and not item then H.revoke(src,'possession_lost'); return nil end
    if not item then
        if H.preferredSlot and H.preferredSlot[src] then
            item=exports.kora_core:getItemBySlot(src,H.preferredSlot[src])
            if item and not Config.Handsets[item.name] then item=nil end
        else
            -- After a relog/restart nothing is selected yet. Face ID and PIN belong to one handset, so with several
            -- phones in the bag resume the one enrolled for this character instead of whichever pairs() yields first.
            local held={}
            for _,v in pairs(inventory(src)) do if Config.Handsets[v.name] then held[#held+1]=v end end
            table.sort(held,function(a,b) return (tonumber(a.slot) or 0)<(tonumber(b.slot) or 0) end)
            item=held[1]
            local cfg=Config.Server and Config.Server.Handsets
            if #held>1 and not (cfg and cfg.ResumeEnrolledHandset==false) then
                for _,v in ipairs(held) do
                    local hid=v.info and v.info.handsetId
                    if hid and row('SELECT 1 AS ok FROM phone_handsets WHERE id=? AND face_citizenid=?',{hid,cid(src)}) then item=v; break end
                end
            end
        end
        if not item then return nil end
        if item.amount~=1 then
            update([[INSERT IGNORE INTO phone_migration_issues(device_id,issue_key,detail)
                VALUES(NULL,?,?)]],{'stacked:'..cid(src)..':'..item.slot,'Split stacked legacy phone items into individual slots before conversion'})
            return nil
        end
        if not (item.info and item.info.handsetId) then
            if not provision then return nil end
            local claim=row('SELECT * FROM phone_legacy_claims WHERE citizenid=? AND claimed_at IS NULL ORDER BY device_id LIMIT 1',{cid(src)})
            id=claim and claim.handset_id or random()
            if not claim then
                local created=MySQL.transaction.await({
                    {query="INSERT INTO phone_devices(owner_citizenid,phone_number,label,settings_json) VALUES(?,?,?,'{}')",values={cid(src),sentinel(id),'New handset'}},
                    {query='INSERT INTO phone_handsets(id,model,device_id) SELECT ?,?,id FROM phone_devices WHERE phone_number=?',values={id,Config.Handsets[item.name],sentinel(id)}}
                })
                if not created then return nil end
            end
            local legacySim=claim and row('SELECT * FROM phone_sims WHERE handset_id=?',{id})
            if claim then update('UPDATE phone_handsets SET model=? WHERE id=?',{Config.Handsets[item.name],id}) end
            local ok,err=inv(src,{op='bindHandset',handsetSlot=item.slot,itemName=item.name,handsetId=id,legacySimId=legacySim and legacySim.id})
            if not ok then
                if not claim then
                    local orphan=phoneRow(id)
                    MySQL.transaction.await({{query='DELETE FROM phone_handsets WHERE id=?',values={id}},
                        {query='DELETE FROM phone_devices WHERE id=?',values={orphan and orphan.id or 0}}})
                end
                error('Could not bind handset: '..tostring(err))
            end
            item=exports.kora_core:getItemBySlot(src,item.slot)
            if claim then
                -- A legacy phone includes its already-existing subscription; no new number is issued.
                update('UPDATE phone_legacy_claims SET claimed_at=CURRENT_TIMESTAMP WHERE device_id=?',{claim.device_id})
                item=exports.kora_core:getItemBySlot(src,item.slot)
            end
        end
        id=item.info.handsetId; H.selected[src]=id
    end
    update('UPDATE phone_legacy_claims SET claimed_at=CURRENT_TIMESTAMP WHERE handset_id=? AND claimed_at IS NULL',{id})
    local device=phoneRow(id)
    if not device or device.model~=Config.Handsets[item.name] then return nil end
    return syncSim(src,item,device)
end
local currentImpl=H.current
H.resolving={}
function H.current(src,provision)
    if H.resolving[src] then return nil end
    local expectedCharacter=cid(src)
    H.resolving[src]=true
    local ok,value=xpcall(function() return currentImpl(src,provision) end,debug.traceback)
    H.resolving[src]=nil
    if not ok then print('[kora_phone] handset resolution failed: '..tostring(value)); return nil end
    if value and (cid(src)~=expectedCharacter or H.selected[src]~=value.handsetId or not itemFor(src,value.handsetId)) then
        H.revoke(src,'possession_lost'); return nil
    end
    if value then value.holderCitizenId=expectedCharacter end
    return value
end
function H.stillHeld(src,device)
    return device and cid(src)==device.holderCitizenId and H.selected[src]==device.handsetId and itemFor(src,device.handsetId)~=nil
end
function H.require(src,locked)
    local player=KoraPhone.GetPlayer(src)
    local metadata=player and player.metadata or {}
    if metadata.isdead or metadata.inlaststand then
        if H.selected[src] then H.revoke(src,'player_dead') end
        return nil,fail('You cannot use a phone right now')
    end
    local device=H.current(src,true)
    if not device then return nil,fail('Select a valid handset in your inventory') end
    local session=KoraPhone.Sessions.ensure(src,device)
    if not locked and (device.hasPin==1 or device.hasPin==true) and not session.unlocked then return nil,fail('Phone is locked') end
    return device
end
local function near(src,point,radius,bucket)
    local ped=GetPlayerPed(src)
    if not ped or ped==0 or GetPlayerRoutingBucket(src)~=(bucket or 0) then return false end
    local pos=GetEntityCoords(ped)
    return (pos.x-point.x)^2+(pos.y-point.y)^2+(pos.z-point.z)^2 <= radius^2
end
local function shop(src,id,employee)
    local s=type(id)=='string' and Config.PhoneServices.shops[id]
    if not s or not near(src,s.coords,s.distance,s.bucket) then return nil end
    if employee and s.job then
        local p=KoraPhone.GetPlayer(src); local j=p and p.job
        if not j or j.name~=s.job or not j.onduty or (j.grade and j.grade.level or 0)<(s.grade or 0) then return nil end
    end
    return s
end
-- Customer grants are consumed by the one trusted BuyItem open, never retained in an inventory session.
H.purchaseCustomers={}
function H.shopStockAccess(src,id)
    if shop(src,id,true) then return true end
    local grant=H.purchaseCustomers[src]
    H.purchaseCustomers[src]=nil
    return grant and grant.shop==id and grant.character==cid(src) and grant.actorCharacter==cid(grant.actor)
        and shop(grant.actor,id,true)~=nil and shop(src,id,false)~=nil or false
end
function H.online(src,device)
    if device.cellular then return true end
    local id=H.wifi[src]; local w=id and Config.PhoneServices.wifi[id]
    return w and near(src,w.coords,w.radius,w.bucket) or false
end
local function simNumber()
    for _=1,50 do
        local digits=Config.PhoneNumber.SubscriberDigits
        local n=Config.PhoneNumber.Prefix..string.format('%0'..digits..'d',math.random(0,10^digits-1))
        -- Check BOTH number spaces: a number already held by a phone_devices row breaks
        -- that table's unique index when syncSim writes the SIM number back to it.
        if not row('SELECT id FROM phone_sims WHERE phone_number=? LIMIT 1',{n})
            and not row('SELECT id FROM phone_devices WHERE phone_number=? LIMIT 1',{n}) then return n end
    end
    error('Phone number space unavailable')
end
local function snapshot(device)
    return {settings=device.settingsJson,contacts=query('SELECT display_name,phone_number,is_favorite,avatar_media_id FROM phone_contacts WHERE owner_device_id=?',{device.id}),
        items=query('SELECT kind,item_key,payload FROM phone_items WHERE device_id=?',{device.id}),
        media=query([[SELECT m.*,((m.owner_device_id=? AND m.deleted_at IS NULL)
            OR EXISTS(SELECT 1 FROM phone_gallery_links l WHERE l.media_id=m.id AND l.device_id=?)) AS is_gallery
            FROM phone_media m WHERE (m.owner_device_id=? AND m.deleted_at IS NULL)
            OR EXISTS(SELECT 1 FROM phone_gallery_links l WHERE l.media_id=m.id AND l.device_id=?)
            OR EXISTS(SELECT 1 FROM phone_mailboxes b WHERE b.device_id=? AND b.media_id=m.id)
            OR EXISTS(SELECT 1 FROM phone_contacts c WHERE c.owner_device_id=? AND c.avatar_media_id=m.id)]],{device.id,device.id,device.id,device.id,device.id,device.id}),
        messages=query('SELECT peer_number,sender_number,body,request_id,created_at,is_read,is_outgoing,media_id FROM phone_mailboxes WHERE device_id=? ORDER BY id',{device.id})}
end
local function clearContent(id)
    return {
        {query='DELETE FROM phone_contacts WHERE owner_device_id=?',values={id}},
        {query='DELETE FROM phone_items WHERE device_id=?',values={id}},
        {query='DELETE FROM phone_mailboxes WHERE device_id=?',values={id}},
        {query='DELETE FROM phone_threads WHERE device_id=?',values={id}},
        {query='UPDATE phone_media SET deleted_at=CURRENT_TIMESTAMP WHERE owner_device_id=?',values={id}},
        {query='DELETE FROM phone_gallery_links WHERE device_id=?',values={id}},
        {query='INSERT IGNORE INTO phone_call_hidden(device_id,call_id) SELECT ?,id FROM phone_calls WHERE caller_device_id=? OR callee_device_id=?',values={id,id,id}},
        {query='DELETE FROM phone_blocks WHERE blocker_device_id=?',values={id}}
    }
end
function H.backup(src)
    local d,err=H.require(src); if not d then return err end
    if not d.accountId then return fail('No cloud account is signed in') end
    if not H.online(src,d) then return fail('Connect to Wi-Fi or insert an active SIM') end
    local saved=snapshot(d)
    local data=json.encode(saved)
    local revision=tonumber(MySQL.scalar.await('SELECT revision FROM phone_cloud_accounts WHERE id=?',{d.accountId}))
    if revision~=tonumber(d.cloudRevision) then return fail('Cloud changed on another handset. Restore before backing up') end
    if not H.stillHeld(src,d) then return fail('Handset is no longer held') end
    local grants={
        {query='UPDATE phone_cloud_accounts SET snapshot_json=?,revision=revision+1 WHERE id=?',values={data,d.accountId}},
        {query='UPDATE phone_handsets SET cloud_revision=cloud_revision+1 WHERE id=?',values={d.handsetId}},
        {query='DELETE FROM phone_cloud_media WHERE account_id=?',values={d.accountId}}
    }
    for _,m in ipairs(saved.media) do grants[#grants+1]={query='INSERT IGNORE INTO phone_cloud_media(account_id,media_id) VALUES(?,?)',values={d.accountId,m.id}} end
    if not MySQL.transaction.await(grants) then return fail('Backup failed; your previous backup is unchanged') end
    return PhoneResult({saved=true})
end
H.accountLocks={}
function H.accountLock(id,handler)
    if type(id)~='string' or #id>64 then return fail('Invalid cloud account') end
    if H.accountLocks[id] then return fail('Cloud account is busy; try again') end
    H.accountLocks[id]=true
    local ok,result=xpcall(handler,debug.traceback)
    H.accountLocks[id]=nil
    if not ok then print('[kora_phone] cloud operation failed: '..tostring(result)); return fail('Cloud operation failed') end
    return result
end
local backupImpl=H.backup
function H.backup(src)
    local d,e=H.require(src); if not d then return e end
    if not d.accountId then return fail('No cloud account is signed in') end
    return H.accountLock(d.accountId,function() return backupImpl(src) end)
end
local function restore(src,d,account)
    local content=account.snapshot_json and json.decode(account.snapshot_json) or {settings='{}'}
    local statements=clearContent(d.id)
    local function add(sql,args) statements[#statements+1]={query=sql,values=args} end
    local mediaIds={}
    -- Restore access grants, never duplicate provider keys or delete cloud-retained objects.
    for _,m in ipairs(content.media or {}) do
        mediaIds[tostring(m.id)]=m.id
        if m.is_gallery==nil or m.is_gallery==1 or m.is_gallery==true then
            add('INSERT IGNORE INTO phone_gallery_links(device_id,media_id) SELECT ?,id FROM phone_media WHERE id=?',{d.id,m.id})
        end
    end
    for _,c in ipairs(content.contacts or {}) do add('INSERT INTO phone_contacts(owner_device_id,display_name,phone_number,is_favorite,avatar_media_id) VALUES(?,?,?,?,NULLIF(?,0))',{d.id,c.display_name,c.phone_number,c.is_favorite,mediaIds[tostring(c.avatar_media_id)] or 0}) end
    for _,i in ipairs(content.items or {}) do add('INSERT INTO phone_items(device_id,kind,item_key,payload) VALUES(?,?,?,?)',{d.id,i.kind,i.item_key,type(i.payload)=='table' and json.encode(i.payload) or i.payload}) end
    for _,m in ipairs(content.messages or {}) do
        add('INSERT INTO phone_mailboxes(device_id,peer_number,sender_number,body,request_id,created_at,is_read,is_outgoing,media_id) VALUES(?,?,?,?,?,?,?,?,NULLIF(?,0))',
            {d.id,m.peer_number,m.sender_number,m.body,m.request_id,m.created_at,m.is_read,m.is_outgoing or 0,mediaIds[tostring(m.media_id)] or 0})
        add('INSERT IGNORE INTO phone_threads(device_id,peer_number) VALUES(?,?)',{d.id,m.peer_number})
    end
    add('UPDATE phone_devices SET settings_json=? WHERE id=?',{type(content.settings)=='table' and json.encode(content.settings) or content.settings or '{}',d.id})
    add('UPDATE phone_handsets SET account_id=?,cloud_revision=?,is_reset=0 WHERE id=?',{account.id,account.revision,d.handsetId})
    if not H.stillHeld(src,d) then return fail('Handset is no longer held') end
    if not MySQL.transaction.await(statements) then return fail('Cloud restore failed; try again') end
    TriggerClientEvent('kora_phone:client:contentCleared',src)
    KoraPhone.Sessions.close(src)
    return PhoneResult({restored=true})
end
-- The inventory gateway moves the SIM item in the same commit as the handset metadata. This confirms
-- the result so an older companion file cannot leave the SIM both inserted and loose (or lost on removal).
function H.settleSimItem(src,op,request,info)
    if op=='insertSim' then
        local left=exports.kora_core:getItemBySlot(src,request.simSlot)
        if left and left.name==Config.SimItem and left.amount==1 and left.info and left.info.simId==request.simId then
            local removed,why=exports.kora_inventory:RemoveItem(src,Config.SimItem,1,request.simSlot,'phone-sim-install')
            if not removed then
                print('[kora_phone] SIM install could not consume the SIM item: '..tostring(why))
                return false,'SIM item could not be moved into the phone'
            end
        end
    else
        for _,item in pairs(inventory(src)) do
            if item.name==Config.SimItem and item.info and item.info.simId==request.simId then return true end
        end
        if type(info)~='table' or info.simId~=request.simId then return false,'SIM details are missing' end
        local added,why=exports.kora_inventory:AddItem(src,Config.SimItem,1,nil,info,'phone-sim-remove')
        if not added then
            print('[kora_phone] SIM removal could not return the SIM item: '..tostring(why))
            return false,'No room to return the SIM to your inventory'
        end
    end
    return true
end
function H.action(src,p)
    local op=p.op
    if op=='select' then
        local item=exports.kora_core:getItemBySlot(src,tonumber(p.slot) or -1)
        if not item or not Config.Handsets[item.name] then return fail('Handset not found') end
        H.revoke(src,'handset_changed')
        H.selected[src]=item.info and item.info.handsetId
        -- Provision the requested slot, not whichever phone happens to be first.
        if not H.selected[src] then
            H.preferredSlot=H.preferredSlot or {}; H.preferredSlot[src]=tonumber(p.slot)
            local d=H.current(src,true); H.preferredSlot[src]=nil
            if not d then return fail('Could not provision handset') end
        end
        return PhoneResult({selected=true})
    end
    local d,err=H.require(src,op=='faceUnlock' or op=='status'); if not d then return err end
    if op=='status' then
        local phones,sims,hotspots,shops={},{},{},{}
        for _,i in pairs(inventory(src)) do
            if Config.Handsets[i.name] then phones[#phones+1]={slot=i.slot,model=Config.Handsets[i.name],id=i.info and i.info.handsetId} end
            if i.name==Config.SimItem then sims[#sims+1]={slot=i.slot,id=i.info and i.info.simId} end
        end
        for id,w in pairs(Config.PhoneServices.wifi) do if near(src,w.coords,w.radius,w.bucket) then hotspots[#hotspots+1]={id=id,label=w.label,private=w.passwordConvar~=nil} end end
        for id,s in pairs(Config.PhoneServices.shops) do if shop(src,id,false) then shops[#shops+1]={id=id,label=s.label,prices=s.prices,business=s.job~=nil} end end
        return PhoneResult({handset={id=d.handsetId,model=d.model},cellular=d.cellular,number=d.cellular and d.phoneNumber or '',
            sim=d.sim and {id=d.sim.id,status=d.sim.status},accountId=d.accountId,faceId=d.faceCitizenId~=nil,
            wifi=H.wifi[src],online=H.online(src,d),phones=phones,sims=sims,hotspots=hotspots,shops=shops,simSwap=Config.SimSwap})
    elseif op=='faceUnlock' then
        if d.faceCitizenId~=cid(src) or not d.pinKdf and not (d.hasPin==1 or d.hasPin==true) then return fail('Face ID did not recognise you') end
        local state=KoraPhone.Repositories.Phones.pinState(d.id)
        if state and (tonumber(state.lockedUntil) or 0)>os.time() then return fail('Unlock is temporarily locked') end
        if not H.stillHeld(src,d) then return fail('Handset is no longer held') end
        KoraPhone.Sessions.ensure(src,d).unlocked=true; return PhoneResult({unlocked=true})
    elseif op=='faceEnroll' then
        if not (d.hasPin==1 or d.hasPin==true) then return fail('Set a backup PIN first') end
        update('UPDATE phone_handsets SET face_citizenid=? WHERE id=?',{cid(src),d.handsetId}); return PhoneResult(true)
    elseif op=='wifi' then
        local w=type(p.id)=='string' and Config.PhoneServices.wifi[p.id]
        if not w or not near(src,w.coords,w.radius,w.bucket) then return fail('Wi-Fi is out of range') end
        if w.passwordConvar and (GetConvar(w.passwordConvar,'')=='' or p.password~=GetConvar(w.passwordConvar,'')) then return fail('Incorrect Wi-Fi password') end
        H.wifi[src]=p.id; return PhoneResult(true)
    elseif op=='insertSim' or op=='removeSim' then
        if op=='insertSim' and d.sim then return fail('Remove the current SIM first') end
        if Config.SimSwap=='shop' or p.shop then if not shop(src,p.shop,true) then return fail('Visit an authorised shop counter') end
        elseif Config.SimSwap~='both' and Config.SimSwap~='player' then return fail('SIM swapping is disabled') end
        local handset=itemFor(src,d.handsetId)
        local request={op=op,handsetSlot=handset.slot,handsetId=d.handsetId,simId=handset.info.phoneSimId}
        if op=='insertSim' then
            local item=exports.kora_core:getItemBySlot(src,tonumber(p.slot) or -1)
            if not item or item.name~=Config.SimItem or item.amount~=1 then return fail('SIM not found') end
            if not (item.info and item.info.simId) then
                local id=random(); update('INSERT INTO phone_sims(id,phone_number,owner_citizenid) VALUES(?,?,?)',{id,simNumber(),cid(src)})
                local bound=inv(src,{op='bindSim',simSlot=item.slot,itemName=item.name,simId=id})
                if not bound then return fail('Could not initialise SIM') end
                item=exports.kora_core:getItemBySlot(src,item.slot)
            end
            local sim=row('SELECT * FROM phone_sims WHERE id=?',{item.info.simId})
            if not sim or sim.status~='active' then return fail('SIM is unavailable') end
            if sim.handset_id then
                -- A held loose SIM proves removal even if SQL lagged behind the inventory commit.
                local oldHandset=sim.handset_id
                local detached=MySQL.transaction.await({
                    {query="UPDATE phone_devices d JOIN phone_handsets h ON h.device_id=d.id SET d.phone_number=CONCAT('@',LEFT(h.id,20)) WHERE h.id=? AND d.phone_number=?",values={oldHandset,sim.phone_number}},
                    {query='UPDATE phone_sims SET handset_id=NULL WHERE id=?',values={sim.id}}
                })
                if not detached then return fail('Could not reconcile SIM removal') end
                for owner,id in pairs(H.selected) do if id==oldHandset and owner~=src then H.revoke(owner,'sim_removed') end end
            end
            request.simSlot=item.slot; request.simId=sim.id
        end
        KoraPhone.Services.Calling.disconnect(src,'sim_changed')
        local returnedInfo=op=='removeSim' and handset.info.phoneSimInfo or nil
        local ok,reason=inv(src,request)
        if not ok then return fail(tostring(reason)) end
        if Config.ConsumeSimOnInstall~=false then
            local settled,problem=H.settleSimItem(src,op,request,returnedInfo)
            if not settled then return fail(problem) end
        end
        H.current(src,false); KoraPhone.Sessions.close(src); return PhoneResult(true)
    elseif op=='registerCloud' then
        if d.accountId then return fail('An account is already signed in') end
        if not H.online(src,d) then return fail('An internet connection is required') end
        local id,code=random(),exports[GetCurrentResourceName()]:randomHex(32)
        local initial=snapshot(d)
        if not H.stillHeld(src,d) then return fail('Handset is no longer held') end
        if not MySQL.transaction.await({
            {query='INSERT INTO phone_cloud_accounts(id,owner_citizenid,recovery_hash,snapshot_json) VALUES(?,?,SHA2(?,256),?)',values={id,cid(src),code,json.encode(initial)}},
            {query='UPDATE phone_handsets SET account_id=?,cloud_revision=0,is_reset=0 WHERE id=?',values={id,d.handsetId}}
        }) then return fail('Account registration failed') end
        for _,m in ipairs(initial.media) do update('INSERT IGNORE INTO phone_cloud_media(account_id,media_id) VALUES(?,?)',{id,m.id}) end
        return PhoneResult({accountId=id,recoveryCode=code})
    elseif op=='backup' then return H.backup(src)
    elseif op=='restoreCloud' then
        if not H.online(src,d) then return fail('An internet connection is required') end
        if type(p.accountId)~='string' or type(p.code)~='string' or #p.code>128 then return fail('Invalid recovery details') end
        return H.accountLock(p.accountId,function()
            local account=row('SELECT * FROM phone_cloud_accounts WHERE id=? AND recovery_hash=SHA2(?,256)',{p.accountId,p.code})
            if not account then return fail('Invalid recovery details') end
            return restore(src,d,account)
        end)
    elseif op=='reset' then
        if d.sim then return fail('Remove the SIM before resetting for resale') end
        local statements=clearContent(d.id)
        statements[#statements+1]={query="UPDATE phone_devices SET settings_json='{}',pin_hash=NULL,pin_salt=NULL,pin_failed_attempts=0,pin_locked_until=NULL WHERE id=?",values={d.id}}
        statements[#statements+1]={query='UPDATE phone_handsets SET account_id=NULL,face_citizenid=NULL,pin_kdf=NULL,is_reset=1,cloud_revision=0 WHERE id=?',values={d.handsetId}}
        if not MySQL.transaction.await(statements) then return fail('Reset failed') end
        H.revoke(src,'factory_reset'); return PhoneResult(true)
    end
    return fail('Unknown handset action')
end
function H.locked(src,handler,payload)
    if H.busy[src] then return fail('Another phone operation is in progress') end
    H.busy[src]=true
    local ok,result=xpcall(function() return handler(src,payload) end,debug.traceback)
    H.busy[src]=nil
    if not ok then print('[kora_phone] handset operation failed: '..tostring(result)); return fail('Phone operation failed') end
    return result
end

-- Existing services continue using device IDs, now resolved from the held handset.
KoraPhone.Permissions.requireDevice=H.require
KoraPhone.Services.Phone.getOrCreate=function(citizenId)
    for _,src in ipairs(GetPlayers()) do if cid(tonumber(src))==citizenId then return H.current(tonumber(src),true) end end
end
KoraPhone.Repositories.Phones.findByNumber=function(number)
    return row([[SELECT d.id,d.owner_citizenid AS ownerCitizenId,s.phone_number AS phoneNumber,1 AS isActive
        FROM phone_sims s JOIN phone_handsets h ON h.id=s.handset_id JOIN phone_devices d ON d.id=h.device_id
        WHERE s.phone_number=? AND s.status='active' LIMIT 1]],{number})
end
local baseBootstrap=KoraPhone.Services.Phone.bootstrap
KoraPhone.Services.Phone.bootstrap=function(src)
    local d=H.current(src,true); if not d then return fail('No handset available') end
    local result=baseBootstrap(src)
    if result.ok then
        result.data.device.model=d.model; result.data.device.handsetId=d.handsetId
        if not d.cellular then result.data.device.phoneNumber='' end
        result.data.device.settings.phoneStyle=d.model
        result.data.device.settings.name=result.data.device.settings.name or ({standard='Orchard One',flip='Circuit Flip',fold='Atlas Fold'})[d.model]
        if result.data.features and result.data.features.video then
            local servers={}; for _,ice in ipairs(Config.Calls.Video.IceServers or {}) do servers[#servers+1]=ice end
            local turn=exports[GetCurrentResourceName()]:turnCredentials(src)
            local urls=GetConvar('kora_phone_turn_urls','')
            if turn and urls~='' then servers[#servers+1]={urls=urls,username=turn.username,credential=turn.credential} end
            result.data.features.video.iceServers=servers
        end
    end
    return result
end
function H.start()
    local gateway=pcall(function() exports.kora_inventory:PhoneItemTransaction(0,{op='probe'}) end)
    if not gateway then error('Install the kora_inventory PhoneItemTransaction companion before starting kora_phone') end
    for name,model in pairs(Config.Handsets) do
        exports.kora_core:registerShared('items',name,{name=name,label=({standard='Orchard One',flip='Circuit Flip',fold='Atlas Fold'})[model],weight=250,type='item',image='phone.png',unique=true,useable=true,shouldClose=true,description='Personal handset'})
        exports.kora_core:createUseable(name,function(src,item)
            H.locked(src,H.action,{op='select',slot=item.slot})
            TriggerClientEvent('kora_phone:client:useHandset',src)
        end)
    end
    exports.kora_core:registerShared('items',Config.SimItem,{name=Config.SimItem,label='Mobile SIM',weight=1,type='item',image='phone.png',unique=true,useable=false,description='Removable mobile subscription'})
    for id,s in pairs(Config.PhoneServices.shops) do
        local items={}; for name,price in pairs(s.prices) do items[#items+1]={name=name,price=price,amount=100,info={},type='item',slot=#items+1} end
        exports.kora_inventory:RegisterShop('kora_phone:'..id,{label=s.label,items=items,slots=64,coords=s.coords,distance=s.distance,currency='bank',
            access=function(src) return H.shopStockAccess(src,id) end})
    end
    H.subscription=exports.kora_core:onChange({'items'},function(src)
        local id=H.selected[src]
        if id and not itemFor(src,id) then H.revoke(src,'possession_lost') end
    end)
    H.deathSubscription=exports.kora_core:onChange({'metadata'},function(src)
        local p=KoraPhone.GetPlayer(src); local m=p and p.metadata or {}
        if H.selected[src] and (m.isdead or m.inlaststand) then H.revoke(src,'player_dead') end
    end)
    H.ready=true
    TriggerClientEvent('kora_phone:client:ready',-1)
end
AddEventHandler('playerDropped',function() H.selected[source]=nil; H.wifi[source]=nil end)
AddEventHandler('onResourceStop',function(resource)
    if resource==GetCurrentResourceName() and H.subscription then exports.kora_core:offChange(H.subscription) end
    if resource==GetCurrentResourceName() and H.deathSubscription then exports.kora_core:offChange(H.deathSubscription) end
end)
exports('CanResellHandset',function(src,slot)
    local item=exports.kora_core:getItemBySlot(src,slot)
    local d=item and item.info and item.info.handsetId and phoneRow(item.info.handsetId)
    if not d or d.isReset~=1 or item.info.phoneSimId or d.accountId or d.pinKdf or d.faceCitizenId then return false end
    local content=tonumber(MySQL.scalar.await([[SELECT
        (SELECT COUNT(*) FROM phone_contacts WHERE owner_device_id=?) +
        (SELECT COUNT(*) FROM phone_items WHERE device_id=?) +
        (SELECT COUNT(*) FROM phone_mailboxes WHERE device_id=?) +
        (SELECT COUNT(*) FROM phone_media WHERE owner_device_id=? AND deleted_at IS NULL) +
        (SELECT COUNT(*) FROM phone_gallery_links WHERE device_id=?) +
        (SELECT COUNT(*) FROM phone_calls c WHERE (c.caller_device_id=? OR c.callee_device_id=?)
            AND NOT EXISTS(SELECT 1 FROM phone_call_hidden h WHERE h.device_id=? AND h.call_id=c.id))]],{d.id,d.id,d.id,d.id,d.id,d.id,d.id,d.id})) or 0
    return content==0
end)
