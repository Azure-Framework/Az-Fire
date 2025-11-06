-- az_fire client.lua

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local activeFires   = {}  -- [fireId] = fire table from server
local incidents     = {}  -- [incidentId] = incident table from server

local scbaActive    = false
local scbaAir       = 0
local scbaMaxAir    = Config.Smoke.SCBAAirSeconds
local scbaLowWarn   = false
local smokeEffectOn = false

local hose = {
    active     = false,
    sourceEnt  = nil,
    sourceType = nil, -- 'hydrant' or 'pumper'
    fxHandle   = nil,
    debug      = nil,
}
local hoseLastSprayTick = 0
-- use minigun for a heavy 2-hand stance; gun itself is hidden
local HOSE_WEAPON       = `WEAPON_HOSE`

local inIDLH        = false
local lastMoveTime  = 0
local passPreAlert  = false
local passFullAlert = false

local incidentAssignment = {
    incidentId = 0,
    division   = "Unassigned",
    role       = "FF",
}

local incidentMarkers = {}
local stationBlips   = {}
local hydrantBlips   = {}
local markerBlips    = { command=nil, rehab=nil, staging=nil, rit=nil }
local incidentBlips  = {}  -- blip per incident

local incidentProgress = { active=false, pct=0 }
local guideActive      = false

---------------------------------------------------------------------
-- UTIL / UI
---------------------------------------------------------------------

local function ui(msg) SendNUIMessage(msg) end

local function uiNotify(kind, text)
    ui({ action = 'notify', kind = kind or 'info', text = text or '' })
end

local function loadAnim(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
end

local function uiIncidentOverlay()
    local show = (incidentAssignment.incidentId ~= 0)
        or inIDLH or scbaActive or passPreAlert or passFullAlert
        or incidentProgress.active

    if not show then
        ui({ action = 'incident_hide' })
        return
    end

    ui({
        action       = 'incident_update',
        assignment   = incidentAssignment,
        idlh         = inIDLH,
        passStatus   = { pre = passPreAlert, full = passFullAlert },
        scba         = { active = scbaActive, air = scbaAir, max = scbaMaxAir },
        fireProgress = incidentProgress
    })
end

---------------------------------------------------------------------
-- FIRE SYNC / INCIDENTS / BLIPS
---------------------------------------------------------------------

RegisterNetEvent('az_fire:syncFires', function(fires, incs)
    -- clear existing local fires
    for _, fire in pairs(activeFires) do
        if fire.handles then
            for _, h in ipairs(fire.handles) do
                RemoveScriptFire(h)
            end
        end
    end

    activeFires       = {}
    incidents         = incs or {}
    incidentProgress  = {active=false, pct=0}
    uiIncidentOverlay()

    local ped = PlayerPedId()
    local px, py, pz = table.unpack(GetEntityCoords(ped))

    for id, fire in pairs(fires or {}) do
        fire.handles = {}
        local fx, fy, fz = fire.coords.x, fire.coords.y, fire.coords.z
        local dx, dy, dz = px - fx, py - fy, pz - fz
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

        if dist <= Config.Performance.FireLODDistance then
            if fire.type == 'vehicle' and fire.vehNetId then
                local veh = NetToVeh(fire.vehNetId)
                if DoesEntityExist(veh) then
                    local h = StartEntityFire(veh)
                    fire.handles[#fire.handles+1] = h
                end
            else
                for _ = 1, math.random(3, 6) do
                    local ox = fx + math.random(-3, 3)
                    local oy = fy + math.random(-3, 3)
                    local oz = fz - 0.3 -- bring slightly down to ground
                    local h  = StartScriptFire(ox, oy, oz, 25, false)
                    fire.handles[#fire.handles+1] = h
                end
            end
        end

        activeFires[id] = fire
    end
end)

RegisterNetEvent('az_fire:fireStarted', function(fire)
    fire.handles = {}

    local ped = PlayerPedId()
    local px, py, pz = table.unpack(GetEntityCoords(ped))
    local fx, fy, fz = fire.coords.x, fire.coords.y, fire.coords.z
    local dx, dy, dz = px - fx, py - fy, pz - fz
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

    if dist <= Config.Performance.FireLODDistance then
        if fire.type == 'vehicle' and fire.vehNetId then
            local veh = NetToVeh(fire.vehNetId)
            if DoesEntityExist(veh) then
                local h = StartEntityFire(veh)
                fire.handles[#fire.handles+1] = h
            end
        else
            for _ = 1, math.random(3, 6) do
                local ox = fx + math.random(-3, 3)
                local oy = fy + math.random(-3, 3)
                local oz = fz - 0.3
                local h  = StartScriptFire(ox, oy, oz, 25, false)
                fire.handles[#fire.handles+1] = h
            end
        end
    end

    activeFires[fire.id] = fire
end)

RegisterNetEvent('az_fire:fireUpdated', function(fire)
    local existing = activeFires[fire.id]
    if existing then fire.handles = existing.handles end
    activeFires[fire.id] = fire
end)

RegisterNetEvent('az_fire:fireExtinguished', function(id)
    local fire = activeFires[id]
    if fire and fire.handles then
        for _, h in ipairs(fire.handles) do
            RemoveScriptFire(h)
        end
    end
    activeFires[id] = nil
end)

RegisterNetEvent('az_fire:incidentData', function(incs)
    incidents = incs or {}
end)

RegisterNetEvent('az_fire:incidentProgress', function(incId, pct)
    incidentProgress = { active = (pct or 0) > 0, pct = pct or 0 }
    uiIncidentOverlay()
end)

RegisterNetEvent('az_fire:incidentBlip', function(incId, data)
    if incidentBlips[incId] and DoesBlipExist(incidentBlips[incId]) then
        RemoveBlip(incidentBlips[incId])
        incidentBlips[incId] = nil
    end

    local sprite, colour, label
    if data.type == 'vehicle' then
        sprite = 436; colour = 1;  label  = 'Vehicle Fire'
    elseif data.type == 'wild' then
        sprite = 442; colour = 25; label  = 'Wildland Fire'
    else
        sprite = 436; colour = 3;  label  = 'Structure Fire'
    end

    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, colour)
    SetBlipScale(blip, 0.9)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(label)
    EndTextCommandSetBlipName(blip)

    incidentBlips[incId] = blip
end)

RegisterNetEvent('az_fire:incidentBlipRemove', function(incId)
    if incId == -1 then
        for k, bl in pairs(incidentBlips) do
            if DoesBlipExist(bl) then RemoveBlip(bl) end
            incidentBlips[k] = nil
        end
        return
    end
    local blip = incidentBlips[incId]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    incidentBlips[incId] = nil
end)

RegisterNetEvent('az_fire:incidentCompleted', function(incId, msg)
    ui({ action='incident_complete', msg = msg or 'Fire under control.' })
    incidentProgress = {active=true, pct=100}
    uiIncidentOverlay()
end)

RegisterNetEvent('az_fire:fireAlarm', function(data)
    ui({
        action  = 'alarm',
        id      = data.id,
        level   = data.alarmLevel,
        type    = data.type,
        message = data.message
    })
    ui({ action = 'alarm_sound' })
end)

RegisterNetEvent('az_fire:notify', function(data)
    uiNotify(data.type or 'info', data.text or '')
end)

---------------------------------------------------------------------
-- SIMPLE CALLOUT HANDLERS (RANDOM CALLOUTS)
---------------------------------------------------------------------

RegisterNetEvent('az_fire:newCallout', function(data)
    -- data.id, data.type, data.coords
    local label = (data.type == 'vehicle' and 'Vehicle Fire')
        or (data.type == 'wild' and 'Wildland Fire')
        or 'Structure Fire'

    uiNotify(
        'warning',
        ('New fire callout: %s (ID %d). Use /acceptfire %d to respond.')
            :format(label, data.id, data.id)
    )
end)

RegisterNetEvent('az_fire:calloutAccepted', function(info)
    -- info.id, info.acceptedBy, info.incidentId
    uiNotify(
        'success',
        ('Callout %d accepted. Incident #%d created.')
            :format(info.id or 0, info.incidentId or 0)
    )
end)

RegisterCommand('acceptfire', function(_, args)
    local id = tonumber(args[1] or '')
    if not id then
        uiNotify('error', 'Usage: /acceptfire <calloutId>')
        return
    end
    TriggerServerEvent('az_fire:acceptCallout', id)
end, false)

---------------------------------------------------------------------
-- CAR FIRE VEHICLE
---------------------------------------------------------------------

RegisterNetEvent('az_fire:spawnCarFireVehicle', function(fireId, coords)
    local model = `blista`
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(0) end

    local veh = CreateVehicle(model, coords.x, coords.y, coords.z, 0.0, true, true)
    SetVehicleEngineHealth(veh, 0.0)
    SetVehicleDoorsLocked(veh, 2)

    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetNetworkIdCanMigrate(netId, true)

    TriggerServerEvent('az_fire:registerCarFireVehicle', fireId, netId)
end)

---------------------------------------------------------------------
-- SCBA
---------------------------------------------------------------------

RegisterNetEvent('az_fire:clientToggleScba', function(seconds)
    if not Config.Features.SCBA then return end
    local ped = PlayerPedId()

    if scbaActive then
        scbaActive  = false
        scbaAir     = 0
        scbaLowWarn = false
        ui({ action='scba_air', value=0, max=scbaMaxAir })
        uiNotify('info', 'SCBA removed.')
        uiIncidentOverlay()
        return
    end

    scbaActive  = true
    scbaMaxAir  = seconds or Config.Smoke.SCBAAirSeconds
    scbaAir     = scbaMaxAir
    scbaLowWarn = false

    loadAnim('clothingtie')
    TaskPlayAnim(ped, 'clothingtie', 'try_tie_neutral_a', 8.0, -8.0, 3000, 48, 0.0, false, false, false)
    Wait(3000)
    ClearPedTasks(ped)

    ui({ action='scba_air', value=scbaAir, max=scbaMaxAir })
    uiNotify('success', 'SCBA on. Air supply started.')
    uiIncidentOverlay()
end)

RegisterCommand('scba', function()
    TriggerServerEvent('az_fire:toggleScba')
end)
RegisterKeyMapping('scba', 'Toggle SCBA', 'keyboard', 'F6')

CreateThread(function()
    while true do
        if scbaActive and scbaAir > 0 then
            Wait(1000)
            scbaAir = scbaAir - 1
            if scbaAir < 0 then scbaAir = 0 end
            ui({ action='scba_air', value=scbaAir, max=scbaMaxAir })

            if not scbaLowWarn and scbaAir <= scbaMaxAir * Config.Smoke.LowAirThreshold then
                scbaLowWarn = true
                ui({ action='scba_low' })
                uiNotify('warning', 'SCBA low air!')
            end

            if scbaAir == 0 then
                scbaActive = false
                uiNotify('error', 'SCBA air depleted!')
            end
            uiIncidentOverlay()
        else
            Wait(500)
        end
    end
end)

---------------------------------------------------------------------
-- SMOKE / IDLH
---------------------------------------------------------------------

local function enableSmokeEffect()
    if smokeEffectOn then return end
    smokeEffectOn = true
    SetTimecycleModifier('NG_filmic01')
    ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.2)
end

local function disableSmokeEffect()
    if not smokeEffectOn then return end
    smokeEffectOn = false
    ClearTimecycleModifier()
    StopGameplayCamShaking(true)
end

CreateThread(function()
    local realisticRadius = 8.0
    while true do
        Wait(Config.Smoke.TickInterval)
        if not Config.Features.Smoke then goto continue end

        local ped = PlayerPedId()
        if not DoesEntityExist(ped) then
            disableSmokeEffect()
            inIDLH = false
            uiIncidentOverlay()
        else
            local px, py, pz = table.unpack(GetEntityCoords(ped))
            local nearFire = false

            for _, fire in pairs(activeFires) do
                local fx, fy, fz = fire.coords.x, fire.coords.y, fire.coords.z
                local dx, dy, dz = px - fx, py - fy, pz - fz
                local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                if dist <= realisticRadius then
                    nearFire = true
                    break
                end
            end

            inIDLH = nearFire

            if nearFire then
                if scbaActive and scbaAir > 0 then
                    disableSmokeEffect()
                else
                    enableSmokeEffect()
                    local hp = GetEntityHealth(ped)
                    SetEntityHealth(ped, math.max(100, hp - Config.Smoke.DamagePerTick))
                    uiNotify('warning', 'Smoke inhalation! Use SCBA or back out.')
                end
            else
                disableSmokeEffect()
            end

            uiIncidentOverlay()
        end

        ::continue::
    end
end)

---------------------------------------------------------------------
-- PASS DEVICE
---------------------------------------------------------------------

CreateThread(function()
    lastMoveTime = GetGameTimer()
    while true do
        local ped = PlayerPedId()
        if DoesEntityExist(ped)
            and Config.Features.SafetySystems
            and Config.Safety.PASS.Enabled
        then
            local vx, vy, vz = table.unpack(GetEntityVelocity(ped))
            local speed = math.sqrt(vx*vx + vy*vy + vz*vz)

            if speed > 0.1 or IsPedInAnyVehicle(ped, false) then
                lastMoveTime = GetGameTimer()
                if passPreAlert or passFullAlert then
                    passPreAlert = false
                    passFullAlert = false
                    ui({ action='pass_reset' })
                    uiIncidentOverlay()
                end
            end

            if inIDLH and scbaActive then
                local idleMs = GetGameTimer() - lastMoveTime
                local preMs  = (Config.Safety.PASS.PreAlertSeconds or 15) * 1000
                local fullMs = (Config.Safety.PASS.FullAlertSeconds or 25) * 1000

                if idleMs >= preMs and idleMs < fullMs and not passPreAlert then
                    passPreAlert = true
                    ui({ action='pass_prealert' })
                    uiIncidentOverlay()
                elseif idleMs >= fullMs and not passFullAlert then
                    passFullAlert = true
                    ui({ action='pass_full' })
                    uiIncidentOverlay()

                    local name = GetPlayerName(PlayerId()) or ('FF#' .. tostring(GetPlayerServerId(PlayerId())))
                    local x, y, z = table.unpack(GetEntityCoords(ped))
                    TriggerServerEvent('az_fire:passTriggered', {
                        name   = name,
                        coords = {x=x,y=y,z=z},
                    })
                end
            end
        end
        Wait(500)
    end
end)

RegisterNetEvent('az_fire:passAlert', function(data)
    ui({ action='pass_alert', payload=data })
end)

---------------------------------------------------------------------
-- MAYDAY
---------------------------------------------------------------------

RegisterCommand('mayday', function()
    if not Config.Features.SafetySystems or not Config.Safety.Mayday.Enabled then return end
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped))
    local name = GetPlayerName(PlayerId()) or ('FF#' .. tostring(GetPlayerServerId(PlayerId())))
    TriggerServerEvent('az_fire:mayday', {
        name   = name,
        coords = {x=x,y=y,z=z},
        air    = scbaAir,
    })
end)
RegisterKeyMapping('mayday', 'Firefighter Mayday', 'keyboard', 'F9')

RegisterNetEvent('az_fire:maydayAlert', function(data)
    ui({ action='mayday_alert', payload=data })
end)

---------------------------------------------------------------------
-- PAR
---------------------------------------------------------------------

RegisterNetEvent('az_fire:parRequested', function(data)
    if not Config.Features.SafetySystems or not Config.Safety.PAR.Enabled then return end
    SetNuiFocus(true, true)
    ui({ action='par_request', id=data.id, started=data.started })
end)

RegisterNUICallback('par_confirm', function(_, cb)
    TriggerServerEvent('az_fire:parConfirm')
    SetNuiFocus(false, false)
    cb({})
end)

RegisterNUICallback('par_cancel', function(_, cb)
    SetNuiFocus(false, false)
    cb({})
end)

RegisterNUICallback('overhaul_done', function(data, cb)
    if data and data.targetId then
        TriggerServerEvent('az_fire:overhaulComplete', data.targetId)
    end
    cb({})
end)

RegisterNUICallback('overhaul_cancel', function(_, cb)
    cb({})
end)

---------------------------------------------------------------------
-- ASSIGNMENTS / MARKERS / STATIONS
---------------------------------------------------------------------

RegisterNetEvent('az_fire:assignmentUpdated', function(data)
    incidentAssignment = data or incidentAssignment
    uiIncidentOverlay()
end)

local function createBlipAt(coords, sprite, colour, text)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipAsShortRange(blip, true)
    SetBlipColour(blip, colour)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(text)
    EndTextCommandSetBlipName(blip)
    return blip
end

local function refreshStationBlips()
    if not Config.Overlays or not Config.Overlays.ShowStationBlips then return end
    for _, b in ipairs(stationBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    stationBlips = {}
    for _, s in ipairs(Config.Stations or {}) do
        local blip = createBlipAt(s, 60, 1, s.label or "Fire Station")
        stationBlips[#stationBlips+1] = blip
    end
end

RegisterNetEvent('az_fire:incidentMarkers', function(markers)
    incidentMarkers = markers or {}

    local function setMarkerBlip(kind, sprite, colour, label)
        if markerBlips[kind] and DoesBlipExist(markerBlips[kind]) then
            RemoveBlip(markerBlips[kind])
            markerBlips[kind] = nil
        end
        local coords = incidentMarkers[kind]
        if coords then
            markerBlips[kind] = createBlipAt(coords, sprite, colour, label)
        end
    end

    setMarkerBlip('command', 280, 1, "Command Post")
    setMarkerBlip('rehab',   153, 2, "Rehab")
    setMarkerBlip('staging', 280, 5, "Staging")
    setMarkerBlip('rit',     161, 1, "RIT")
end)

CreateThread(function()
    Wait(5000)
    refreshStationBlips()
end)

---------------------------------------------------------------------
-- HOSE (minigun stance + custom water FX)
---------------------------------------------------------------------

local function isPumperModel(model)
    for _, m in ipairs(Config.Pumpers.Models) do
        if m == model then return true end
    end
    return false
end

-- hydrants are now actual world props (no config list)
local HYDRANT_MODELS = {
    `prop_fire_hydrant_1`,
    `prop_fire_hydrant_2`,
    `prop_fire_hydrant_3`,
    `prop_fire_hydrant_4`,
}

local function isHydrantEntity(ent)
    if not DoesEntityExist(ent) then return false end
    local model = GetEntityModel(ent)
    for _, m in ipairs(HYDRANT_MODELS) do
        if model == m then return true end
    end
    return false
end

local function findNearestHydrant(coords)
    local handle, obj = FindFirstObject()
    local success
    local bestEnt, bestDist

    if not handle or handle == -1 then return nil end

    repeat
        if DoesEntityExist(obj) and isHydrantEntity(obj) then
            local ox, oy, oz = table.unpack(GetEntityCoords(obj))
            local dx, dy, dz = coords.x - ox, coords.y - oy, coords.z - oz
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist <= Config.Hose.MaxDistanceSource and (not bestDist or dist < bestDist) then
                bestDist = dist
                bestEnt  = obj
            end
        end
        success, obj = FindNextObject(handle)
    until not success

    EndFindObject(handle)
    return bestEnt
end

local function findNearestPumper(coords)
    local handle, veh = FindFirstVehicle()
    local success
    local best, bestDist

    if not handle or handle == -1 then return nil end

    repeat
        if DoesEntityExist(veh) then
            local model = GetEntityModel(veh)
            if isPumperModel(model) then
                local vx, vy, vz = table.unpack(GetEntityCoords(veh))
                local dx, dy, dz = coords.x - vx, coords.y - vy, coords.z - vz
                local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                if dist <= Config.Hose.MaxDistanceSource and (not bestDist or dist < bestDist) then
                    bestDist = dist
                    best     = veh
                end
            end
        end
        success, veh = FindNextVehicle(handle)
    until not success

    EndFindVehicle(handle)
    return best
end

local function giveHoseWeapon(ped)
    -- give minigun just for pose, hide model
    if not HasPedGotWeapon(ped, HOSE_WEAPON, false) then
        GiveWeaponToPed(ped, HOSE_WEAPON, 0, false, true)
    end
    SetCurrentPedWeapon(ped, HOSE_WEAPON, true)
    SetPedInfiniteAmmo(ped, true, HOSE_WEAPON)

    -- hide gun but keep heavy-weapon stance
    SetPedCurrentWeaponVisible(ped, false, true, true, true)
    SetPedCanSwitchWeapon(ped, false)
end

local function connectHose()
    if not Config.Features.Hose then
        uiNotify('error', 'Hose system disabled.')
        return
    end
    if hose.active then
        uiNotify('info', 'Hose already connected.')
        return
    end

    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local pos    = {x = coords.x, y = coords.y, z = coords.z}

    local hydrantEnt = findNearestHydrant(pos)
    local pumper     = findNearestPumper(pos)

    local sourceEnt, sourceType
    if hydrantEnt then
        sourceEnt  = hydrantEnt
        sourceType = 'hydrant'
    elseif pumper then
        sourceEnt  = pumper
        sourceType = 'pumper'
    else
        uiNotify('error', 'No hydrant or pumper nearby.')
        return
    end

    giveHoseWeapon(ped)

    hose.active        = true
    hose.sourceEnt     = sourceEnt
    hose.sourceType    = sourceType
    hose.fxHandle      = nil
    hose.debug         = nil
    hoseLastSprayTick  = 0

    uiNotify('success', 'Hose connected. Aim with mouse, hold LMB to spray.')
end

local function disconnectHose()
    if not hose.active then return end

    hose.sourceEnt  = nil
    hose.sourceType = nil
    hose.active     = false
    hose.debug      = nil

    if hose.fxHandle then
        StopParticleFxLooped(hose.fxHandle, false)
        hose.fxHandle = nil
    end

    local ped = PlayerPedId()
    SetPedCanSwitchWeapon(ped, true)
    if HasPedGotWeapon(ped, HOSE_WEAPON, false) then
        RemoveWeaponFromPed(ped, HOSE_WEAPON)
    end

    uiNotify('info', 'Hose disconnected.')
end

RegisterCommand('hose', function()
    if hose.active then disconnectHose() else connectHose() end
end)
RegisterKeyMapping('hose', 'Connect hose (toggle)', 'keyboard', 'F7')

-- ================== HYDRANT BLIPS (PROP-BASED) ==================

local function clearHydrantBlips()
    for ent, bl in pairs(hydrantBlips) do
        if bl and DoesBlipExist(bl) then RemoveBlip(bl) end
        hydrantBlips[ent] = nil
    end
end

local function updateHydrantBlips()
    if not Config.Overlays or Config.Overlays.ShowHydrantBlips == false then
        clearHydrantBlips()
        return
    end

    local ped = PlayerPedId()
    if not DoesEntityExist(ped) then
        clearHydrantBlips()
        return
    end

    local px, py, pz = table.unpack(GetEntityCoords(ped))
    local range = Config.Overlays.HydrantBlipRange or 80.0

    local seen = {}

    local handle, obj = FindFirstObject()
    local success
    if not handle or handle == -1 then return end

    repeat
        if DoesEntityExist(obj) and isHydrantEntity(obj) then
            local ox, oy, oz = table.unpack(GetEntityCoords(obj))
            local dx, dy, dz = px - ox, py - oy, pz - oz
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist <= range then
                seen[obj] = true
                if not hydrantBlips[obj] or not DoesBlipExist(hydrantBlips[obj]) then
                    local blip = AddBlipForEntity(obj)
                    SetBlipSprite(blip, 1)
                    SetBlipColour(blip, 3)
                    SetBlipScale(blip, 0.6)
                    SetBlipAsShortRange(blip, true)
                    BeginTextCommandSetBlipName("STRING")
                    AddTextComponentString("Hydrant")
                    EndTextCommandSetBlipName(blip)
                    hydrantBlips[obj] = blip
                end
            end
        end
        success, obj = FindNextObject(handle)
    until not success

    EndFindObject(handle)

    for ent, bl in pairs(hydrantBlips) do
        if (not seen[ent]) or (not DoesEntityExist(ent)) then
            if bl and DoesBlipExist(bl) then RemoveBlip(bl) end
            hydrantBlips[ent] = nil
        end
    end
end

CreateThread(function()
    while true do
        updateHydrantBlips()
        Wait(3000)
    end
end)

-- ================== HOSE DEBUG + DIRECTION HELPER ==================
local hoseDebug = false

local function RotationToDirection(xRot, yRot, zRot)
    -- Convert degrees to radians
    local rx = math.rad(xRot)
    local ry = math.rad(yRot)
    local rz = math.rad(zRot)

    -- GTA-style: zRot ~ yaw (left/right), xRot ~ pitch (up/down)
    local cosX = math.cos(rx)
    local sinX = math.sin(rx)
    local cosZ = math.cos(rz)
    local sinZ = math.sin(rz)

    local dirX = -sinZ * cosX
    local dirY =  cosZ * cosX
    local dirZ =  sinX

    return vector3(dirX, dirY, dirZ)
end

RegisterCommand('hose_debug', function()
    hoseDebug = not hoseDebug
    if hoseDebug then
        print('[az_fire] Hose debug ON')
    else
        print('[az_fire] Hose debug OFF')
    end
end, false)

-- Draw debug lines for offsets + direction
CreateThread(function()
    while true do
        if hoseDebug and hose.active and hose.debug then
            local ped = PlayerPedId()
            if DoesEntityExist(ped) then
                local d = hose.debug

                -- Approx origin of the fx using same offsets
                local origin = GetOffsetFromEntityInWorldCoords(
                    ped,
                    d.xOff, d.yOff, d.zOff
                )

                -- Local X axis (forward) - RED
                local xEnd = GetOffsetFromEntityInWorldCoords(
                    ped,
                    d.xOff + 0.5, d.yOff, d.zOff
                )
                DrawLine(origin.x, origin.y, origin.z, xEnd.x, xEnd.y, xEnd.z, 255, 0, 0, 255)

                -- Local Y axis (up) - GREEN
                local yEnd = GetOffsetFromEntityInWorldCoords(
                    ped,
                    d.xOff, d.yOff + 0.5, d.zOff
                )
                DrawLine(origin.x, origin.y, origin.z, yEnd.x, yEnd.y, yEnd.z, 0, 255, 0, 255)

                -- Local Z axis (left/right) - BLUE
                local zEnd = GetOffsetFromEntityInWorldCoords(
                    ped,
                    d.xOff, d.yOff, d.zOff + 0.5
                )
                DrawLine(origin.x, origin.y, origin.z, zEnd.x, zEnd.y, zEnd.z, 0, 0, 255, 255)

                -- Stream direction from xRot,yRot,zRot - WHITE
                local dir = RotationToDirection(d.xRot, d.yRot, d.zRot)
                local tip = vector3(
                    origin.x + dir.x * 4.0,
                    origin.y + dir.y * 4.0,
                    origin.z + dir.z * 4.0
                )

                DrawLine(origin.x, origin.y, origin.z, tip.x, tip.y, tip.z, 255, 255, 255, 255)
            end

            Wait(0) -- draw every frame
        else
            Wait(500)
        end
    end
end)

-- ================== HOSE LOOP (SPRAY + FX) ==================
CreateThread(function()
    while true do
        if hose.active then
            local ped = PlayerPedId()

            -- keep hose weapon selected
            if GetSelectedPedWeapon(ped) ~= HOSE_WEAPON then
                giveHoseWeapon(ped)
            end

            -- always face where camera looks (aim with mouse)
            if not IsPedInAnyVehicle(ped, false) then
                local camRot = GetGameplayCamRot(2)
                SetEntityHeading(ped, camRot.z)
            end

            -- block melee/normal fire but read disabled LMB
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisablePlayerFiring(PlayerId(), true)

            local spraying = IsDisabledControlPressed(0, 24)

            if spraying then
                if not hose.fxHandle then
                    -- ========== CREATE WATER FX ==========
                    RequestNamedPtfxAsset('core')
                    while not HasNamedPtfxAssetLoaded('core') do Wait(0) end
                    UseParticleFxAssetNextCall('core')

                    local bone = GetPedBoneIndex(ped, 57005) -- right hand

                    -- Position of the nozzle relative to the hand
                    -- tweak these if the origin isn't exactly at the nozzle
                    local xOff, yOff, zOff = 0.40, 0.10, -0.15

                    -- Rotations:
                    --  xRot: pitch (up/down)
                    --  yRot: roll  (twist around the stream)
                    --  zRot: yaw   (left/right around vertical)
                    --  tweak these to aim the stream
                    local xRot, yRot, zRot = 5.0, -180.0, -25.0

                    -- Save for debug drawing
                    hose.debug = {
                        bone = bone,
                        xOff = xOff, yOff = yOff, zOff = zOff,
                        xRot = xRot, yRot = yRot, zRot = zRot,
                    }

                    hose.fxHandle = StartParticleFxLoopedOnEntityBone(
                        'water_cannon_jet',
                        ped,
                        xOff, yOff, zOff,
                        xRot, yRot, zRot,
                        bone,
                        2.0,
                        false, false, false
                    )
                end

                -- Extinguish logic (same as before)
                local now = GetGameTimer()
                if now - hoseLastSprayTick > 250 then
                    hoseLastSprayTick = now

                    local px, py, pz = table.unpack(GetEntityCoords(ped))
                    local nearestId, nearestDist

                    for id, fire in pairs(activeFires) do
                        local fx, fy, fz = fire.coords.x, fire.coords.y, fire.coords.z
                        local dx, dy, dz = px - fx, py - fy, pz - fz
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if dist <= Config.Hose.ExtinguishRadius
                        and (not nearestDist or dist < nearestDist) then
                            nearestDist = dist
                            nearestId   = id
                        end
                    end

                    if nearestId then
                        TriggerServerEvent('az_fire:extinguishAttempt',
                            nearestId,
                            Config.Hose.ExtinguishAmount or 6
                        )

                        if hose.sourceType == 'pumper'
                        and hose.sourceEnt
                        and DoesEntityExist(hose.sourceEnt) then
                            local netId = NetworkGetNetworkIdFromEntity(hose.sourceEnt)
                            TriggerServerEvent('az_fire:consumePumperWater', netId, 1)
                        end
                    end
                end
            else
                -- stop FX when not spraying
                if hose.fxHandle then
                    StopParticleFxLooped(hose.fxHandle, false)
                    hose.fxHandle = nil
                end
            end

            Wait(0)
        else
            Wait(500)
        end
    end
end)


---------------------------------------------------------------------
-- AUTO-DETECT EXTINGUISHED AREAS (truck cannon / extinguisher)
---------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(3000)

        if next(activeFires) ~= nil then
            for id, fire in pairs(activeFires) do
                if not fire._goneSent then
                    local fx, fy, fz = fire.coords.x, fire.coords.y, fire.coords.z
                    local count = GetNumberOfFiresInRange(fx, fy, fz, 4.0)
                    if count == 0 then
                        fire._goneSent = true
                        TriggerServerEvent('az_fire:forceExtinguish', id)
                    end
                end
            end
        end
    end
end)

---------------------------------------------------------------------
-- VEHICLE VENTILATION (CAR DOORS)
---------------------------------------------------------------------

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local px, py, pz = table.unpack(GetEntityCoords(ped))

        for id, fire in pairs(activeFires) do
            if fire.type == 'vehicle' and fire.vehNetId and not fire.ventReported then
                local veh = NetToVeh(fire.vehNetId)
                if DoesEntityExist(veh) then
                    local vx, vy, vz = table.unpack(GetEntityCoords(veh))
                    local dx, dy, dz = px - vx, py - vy, pz - vz
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist <= 40.0 then
                        local anyDoor = false
                        for d = 0, 5 do
                            if GetVehicleDoorAngleRatio(veh, d) > 0.1 then anyDoor = true break end
                        end
                        if anyDoor then
                            fire.ventReported = true
                            TriggerServerEvent('az_fire:vehicleVented', id)
                        end
                    end
                end
            end
        end

        Wait(2000)
    end
end)

---------------------------------------------------------------------
-- OVERHAUL / TIC
---------------------------------------------------------------------

RegisterCommand('overhaul', function()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped))
    TriggerServerEvent('az_fire:requestOverhaulStart', {x=x,y=y,z=z})
end)
RegisterKeyMapping('overhaul', 'Overhaul / TIC Scan', 'keyboard', 'F8')

RegisterNetEvent('az_fire:overhaulStart', function(targetId)
    ui({ action='thermal_scan', targetId = targetId })
end)

---------------------------------------------------------------------
-- HELP / GUIDE & CLEAR FX
---------------------------------------------------------------------

RegisterCommand('firehelp', function()
    uiNotify('info', 'Use /guidefire for on-screen guide. Keys: SCBA F6, Hose F7, Overhaul F8, Mayday F9.')
end)
RegisterKeyMapping('firehelp', 'Fire system help', 'keyboard', 'F10')

RegisterCommand('guidefire', function()
    guideActive = not guideActive
    if guideActive then
        uiNotify('success', 'Fire guide ON. Use /guidefire again to hide.')
    else
        uiNotify('info', 'Fire guide OFF.')
    end
end)

CreateThread(function()
    while true do
        if guideActive then
            BeginTextCommandDisplayHelp("STRING")
            AddTextComponentSubstringPlayerName(
                "~b~FIRE GUIDE~s~\n" ..
                "1) /testfire car/wild/house or accept a callout.\n" ..
                "2) /scba or F6 before entering smoke.\n" ..
                "3) Park pumper or go to hydrant (blip).\n" ..
                "4) /hose or F7 near source to connect.\n" ..
                "5) Aim with mouse, hold LMB to flow water.\n" ..
                "6) Watch FIRE% on HUD – 100% = under control.\n" ..
                "7) /overhaul or F8 for hotspots.\n" ..
                "8) IC: /ic_par, /ic_cp, /ic_rehab, /ic_staging, /ic_rit."
            )
            EndTextCommandDisplayHelp(0, false, false, -1)
            Wait(0)
        else
            Wait(500)
        end
    end
end)

RegisterCommand('clearfx', function()
    smokeEffectOn = false
    ClearTimecycleModifier()
    ClearExtraTimecycleModifier()
    StopGameplayCamShaking(true)
    AnimpostfxStopAll()
    uiNotify('success', 'Screen effects cleared.')
end, false)




-- client.lua — test custom blip icon from URL via command
-- Usage in-game:
--   /testurlblip
--   /testurlblip https://your.cdn/icon.png

local CUSTOM_TXD_NAME = 'customblips'
local CUSTOM_TEX_NAME = 'custom_blip'

-- The base minimap texture we’re overriding
local REPLACE_TXD = 'minimap'
local REPLACE_TEX = 'radar_garage'   -- see FiveM blip docs

-- Sprite ID that uses radar_garage
local BLIP_SPRITE_ID = 357           -- garage sprite ID

-- Default URL if you don’t pass one in the command
local DEFAULT_ICON_URL = 'https://i.imgur.com/youricon.png' -- change this

local runtimeTxd = nil
local currentDui = nil
local hasReplace = false

local function loadBlipTextureFromUrl(url)
    -- Create runtime TXD once
    if not runtimeTxd then
        runtimeTxd = CreateRuntimeTxd(CUSTOM_TXD_NAME)
    end

    -- Clean up old Dui if we had one
    if currentDui then
        DestroyDui(currentDui)
        currentDui = nil
    end

    -- Create Dui from URL (64x64 works well)
    currentDui = CreateDui(url, 64, 64)
    local duiHandle = GetDuiHandle(currentDui)

    -- Make a runtime texture from the Dui handle
    CreateRuntimeTextureFromDuiHandle(runtimeTxd, CUSTOM_TEX_NAME, duiHandle)

    -- Replace the garage radar texture with our runtime texture
    AddReplaceTexture(REPLACE_TXD, REPLACE_TEX, CUSTOM_TXD_NAME, CUSTOM_TEX_NAME)
    hasReplace = true

    print(('[custom_blip] Loaded icon from URL: %s'):format(url))
end

local function createTestBlip()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)

    -- Use the garage sprite; its texture is now replaced by our URL image
    SetBlipSprite(blip, BLIP_SPRITE_ID)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.9)
    SetBlipColour(blip, 1)
    SetBlipAsShortRange(blip, false)

    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("Custom URL Blip")
    EndTextCommandSetBlipName(blip)

    print('[custom_blip] Test blip created at your position.')
end

RegisterCommand('testurlblip', function(_, args)
    local url = args[1] or DEFAULT_ICON_URL

    if not url or url == '' then
        print('[custom_blip] Usage: /testurlblip https://your.cdn/icon.png')
        return
    end

    loadBlipTextureFromUrl(url)
    createTestBlip()
end, false)

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resName)
    if resName ~= GetCurrentResourceName() then return end

    if hasReplace then
        -- Reset back to original texture
        RemoveReplaceTexture(REPLACE_TXD, REPLACE_TEX)
    end

    if currentDui then
        DestroyDui(currentDui)
        currentDui = nil
    end
end)


