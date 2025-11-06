local fires           = {}   -- [fireId] = fire
local incidents       = {}   -- [incidentId] = incident
local overhaulTargets = {}
local nextFireId      = 1
local nextIncidentId  = 1

local pumperWater     = {}
local assignments     = {}
local currentPAR      = nil

local incidentMarkers = {
    command = nil,
    rehab   = nil,
    staging = nil,
    rit     = nil,
}

local callouts        = {}
local nextCalloutId   = 1

---------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------

local function debugPrint(...)
    print(('[az_fire][S] %s'):format(table.concat({...}, ' ')))
end

local function countActiveFires()
    local c = 0
    for _ in pairs(fires) do c = c + 1 end
    return c
end

local function incidentHasFires(incidentId)
    local inc = incidents[incidentId]
    if not inc or not inc.fires then return false end
    for _ in pairs(inc.fires) do return true end
    return false
end

---------------------------------------------------------------------
-- INCIDENT HELPERS
---------------------------------------------------------------------

local function completeIncident(incidentId)
    local inc = incidents[incidentId]
    if not inc or not inc.active then return end
    inc.active = false

    TriggerClientEvent('az_fire:incidentBlipRemove', -1, incidentId)
    TriggerClientEvent('az_fire:incidentCompleted', -1, incidentId, 'Fire under control.')
    TriggerClientEvent('az_fire:incidentProgress', -1, incidentId, 100)

    debugPrint('Incident complete', incidentId)
end

local function updateIncidentProgress(incidentId)
    local inc = incidents[incidentId]
    if not inc then return end

    local totalMax, totalCur = 0, 0
    if inc.fires then
        for fireId in pairs(inc.fires) do
            local fire = fires[fireId]
            if fire then
                local maxInt = Config.Fire.Intensity[fire.type] or 100
                totalMax = totalMax + maxInt
                totalCur = totalCur + math.max(0, fire.intensity or 0)
            end
        end
    end

    local pct = 0
    if totalMax > 0 then
        pct = 100 - ((totalCur / totalMax) * 100)
    end
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))

    TriggerClientEvent('az_fire:incidentProgress', -1, incidentId, pct)

    if pct >= 99 or not incidentHasFires(incidentId) then
        -- force clear any straggler fires and finish the incident
        if inc.fires then
            for fireId in pairs(inc.fires) do
                fires[fireId] = nil
                inc.fires[fireId] = nil
                TriggerClientEvent('az_fire:fireExtinguished', -1, fireId)
            end
        end
        completeIncident(incidentId)
    end
end

local function createIncident(fType, coords)
    local id = nextIncidentId
    nextIncidentId = id + 1

    local alarmLevel = Config.Fire.AlarmForType[fType] or 1
    incidents[id] = {
        id         = id,
        type       = fType,
        coords     = coords,
        alarmLevel = alarmLevel,
        active     = true,
        fires      = {},
    }

    TriggerClientEvent('az_fire:incidentBlip', -1, id, {
        type   = fType,
        coords = coords,
    })

    local msg = ('Alarm Level %d - %s Fire'):format(
        alarmLevel,
        fType == 'vehicle' and 'Vehicle'
        or fType == 'wild' and 'Wildland'
        or 'Structure'
    )

    for _, src in ipairs(GetPlayers()) do
        local job = Config.GetPlayerJob(src)
        if Config.FireJobs[job] then
            TriggerClientEvent('az_fire:fireAlarm', src, {
                id         = id,
                alarmLevel = alarmLevel,
                type       = fType,
                coords     = coords,
                message    = msg
            })
        end
    end

    debugPrint('Incident created', id, fType, coords.x, coords.y, coords.z)
    return incidents[id]
end

local function addFireToIncident(incidentId, fType, coords, vehNetId)
    local inc = incidents[incidentId]
    if not inc then return end

    local id = nextFireId
    nextFireId = id + 1

    local intensity = Config.Fire.Intensity[fType] or 100
    local fire = {
        id         = id,
        incidentId = incidentId,
        type       = fType,
        coords     = coords,
        intensity  = intensity,
        alarmLevel = inc.alarmLevel,
        vehNetId   = vehNetId,
        createdAt  = os.time(),
        vented     = false,
    }

    fires[id]     = fire
    inc.fires[id] = true

    TriggerClientEvent('az_fire:fireStarted', -1, fire)
    return id
end

local function ensureIncident(fType, coords)
    local inc = createIncident(fType, coords)
    return inc.id
end

local function createInitialFire(fType, coords)
    local incId = ensureIncident(fType, coords)
    local fireId = addFireToIncident(incId, fType, coords, nil)
    updateIncidentProgress(incId)
    return fireId, incId
end

---------------------------------------------------------------------
-- FIRE CREATION / RANDOM HELPERS
---------------------------------------------------------------------

local function spawnCarFireAtCoords(coords)
    local fireId, incId = createInitialFire('vehicle', coords)
    TriggerClientEvent('az_fire:spawnCarFireVehicle', -1, fireId, coords)
end

local function spawnWildFireAtCoords(coords)
    createInitialFire('wild', coords)
end

local function spawnHouseFireAtCoords(coords)
    createInitialFire('house', coords)
end

local function randomFrom(list)
    return list[math.random(1, #list)]
end

local function spawnCarFireRandom()
    if #Config.Fire.CarSpots == 0 then return end
    local pos = randomFrom(Config.Fire.CarSpots)
    spawnCarFireAtCoords({ x = pos.x, y = pos.y, z = pos.z })
end

local function spawnWildFireRandom()
    if #Config.Fire.WildSpots == 0 then return end
    local pos = randomFrom(Config.Fire.WildSpots)
    spawnWildFireAtCoords({ x = pos.x, y = pos.y, z = pos.z })
end

local function spawnHouseFireRandom()
    if #Config.Fire.HouseSpots == 0 then return end
    local pos = randomFrom(Config.Fire.HouseSpots)
    spawnHouseFireAtCoords({ x = pos.x, y = pos.y, z = pos.z })
end

local function spawnRandomFireRandom()
    local r = math.random()
    if r < 0.4 then
        spawnCarFireRandom()
    elseif r < 0.75 then
        spawnWildFireRandom()
    else
        spawnHouseFireRandom()
    end
end

RegisterNetEvent('az_fire:registerCarFireVehicle', function(fireId, vehNetId)
    local fire = fires[fireId]
    if not fire then return end
    fire.vehNetId = vehNetId
    TriggerClientEvent('az_fire:fireUpdated', -1, fire)
end)

---------------------------------------------------------------------
-- RANDOM CALLOUTS (E ACCEPT)
---------------------------------------------------------------------

local function startRandomCallout()
    local fType, coords

    local r = math.random()
    if r < 0.4 and #Config.Fire.CarSpots > 0 then
        local pos = randomFrom(Config.Fire.CarSpots)
        fType = 'vehicle'
        coords = {x=pos.x,y=pos.y,z=pos.z}
    elseif r < 0.75 and #Config.Fire.WildSpots > 0 then
        local pos = randomFrom(Config.Fire.WildSpots)
        fType = 'wild'
        coords = {x=pos.x,y=pos.y,z=pos.z}
    elseif #Config.Fire.HouseSpots > 0 then
        local pos = randomFrom(Config.Fire.HouseSpots)
        fType = 'house'
        coords = {x=pos.x,y=pos.y,z=pos.z}
    else
        return
    end

    local id = nextCalloutId
    nextCalloutId = id + 1

    callouts[id] = {
        id        = id,
        type      = fType,
        coords    = coords,
        createdAt = os.time(),
        accepted  = false,
    }

    for _, src in ipairs(GetPlayers()) do
        local job = Config.GetPlayerJob(src)
        if Config.FireJobs[job] then
            TriggerClientEvent('az_fire:newCallout', src, {
                id     = id,
                type   = fType,
                coords = coords,
            })
        end
    end

    debugPrint('Random callout', id, fType, coords.x, coords.y, coords.z)
end

RegisterNetEvent('az_fire:acceptCallout', function(calloutId)
    local src = source
    local c = callouts[calloutId]
    if not c or c.accepted then return end
    c.accepted = true

    local fireId, incId = createInitialFire(c.type, c.coords)

    for _, ply in ipairs(GetPlayers()) do
        local job = Config.GetPlayerJob(ply)
        if Config.FireJobs[job] then
            TriggerClientEvent('az_fire:calloutAccepted', ply, {
                id         = calloutId,
                acceptedBy = src,
                incidentId = incId
            })
        end
    end

    assignments[src] = { incidentId = incId, division = 'Attack 1', role = 'FF' }
    TriggerClientEvent('az_fire:assignmentUpdated', src, assignments[src])

    callouts[calloutId] = nil
end)

---------------------------------------------------------------------
-- SPREAD / REKINDLE
---------------------------------------------------------------------

local function trySpread()
    if not Config.Features.FireSpread then return end
    local maxFires = Config.Performance.MaxSimultaneousFires or 10
    local active   = countActiveFires()
    if active >= maxFires then return end

    for _, fire in pairs(fires) do
        if fire.intensity and fire.intensity > 50 then
            if math.random() < Config.Fire.SpreadChance then
                if active >= maxFires then return end
                local radius = Config.Fire.SpreadMaxDistance
                local angle  = math.random() * math.pi * 2
                local dist   = math.random() * radius
                local nx     = fire.coords.x + math.cos(angle) * dist
                local ny     = fire.coords.y + math.sin(angle) * dist
                local nz     = fire.coords.z

                local id = addFireToIncident(fire.incidentId, fire.type, {x=nx,y=ny,z=nz}, nil)
                active = active + 1
                updateIncidentProgress(fire.incidentId)
            end
        end
    end
end

local function tryRekindle()
    if not Config.Features.Rekindle then return end
    local now = os.time()

    for id, tgt in pairs(overhaulTargets) do
        if not tgt.overhauled then
            local age = now - tgt.timeExtinguished
            if age > 0 and age <= Config.Fire.RekindleWindow then
                if math.random() < Config.Fire.RekindleChance then
                    addFireToIncident(tgt.incidentId, tgt.type, tgt.coords, nil)
                    updateIncidentProgress(tgt.incidentId)
                    tgt.overhauled = true
                end
            elseif age > Config.Fire.RekindleWindow then
                overhaulTargets[id] = nil
            end
        else
            overhaulTargets[id] = nil
        end
    end
end

---------------------------------------------------------------------
-- EXTINGUISH / OVERHAUL
---------------------------------------------------------------------

RegisterNetEvent('az_fire:extinguishAttempt', function(fireId, amount)
    local fire = fires[fireId]
    if not fire then return end

    fire.intensity = (fire.intensity or 0) - (amount or 0)
    local incId = fire.incidentId

    if fire.intensity <= 0 then
        fires[fireId] = nil

        local inc = incidents[incId]
        if inc and inc.fires then inc.fires[fireId] = nil end

        TriggerClientEvent('az_fire:fireExtinguished', -1, fireId)

        overhaulTargets[fireId] = {
            id               = fireId,
            incidentId       = incId,
            type             = fire.type,
            coords           = fire.coords,
            timeExtinguished = os.time(),
            overhauled       = false,
        }

        debugPrint('Fire', fireId, 'extinguished')
    else
        TriggerClientEvent('az_fire:fireUpdated', -1, fire)
    end

    if incId then
        if not incidentHasFires(incId) then
            completeIncident(incId)
        else
            updateIncidentProgress(incId)
        end
    end
end)

RegisterNetEvent('az_fire:forceExtinguish', function(fireId)
    local fire = fires[fireId]
    if not fire then return end
    local incId = fire.incidentId

    fires[fireId] = nil
    local inc = incidents[incId]
    if inc and inc.fires then inc.fires[fireId] = nil end

    TriggerClientEvent('az_fire:fireExtinguished', -1, fireId)

    if incId then
        if not incidentHasFires(incId) then
            completeIncident(incId)
        else
            updateIncidentProgress(incId)
        end
    end
end)

RegisterNetEvent('az_fire:vehicleVented', function(fireId)
    local fire = fires[fireId]
    if not fire or fire.type ~= 'vehicle' or fire.vented then return end
    fire.vented    = true
    fire.intensity = math.floor((fire.intensity or 100) * 1.35)
    TriggerClientEvent('az_fire:fireUpdated', -1, fire)
end)

RegisterNetEvent('az_fire:requestOverhaulStart', function(coords)
    if not Config.Features.Rekindle then return end
    local src = source
    if type(coords) ~= 'table' then return end

    local closestId, closestDist
    for id, tgt in pairs(overhaulTargets) do
        if not tgt.overhauled then
            local dx = coords.x - tgt.coords.x
            local dy = coords.y - tgt.coords.y
            local dz = coords.z - tgt.coords.z
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist < 10.0 and (not closestDist or dist < closestDist) then
                closestId  = id
                closestDist= dist
            end
        end
    end

    if closestId then
        TriggerClientEvent('az_fire:overhaulStart', src, closestId)
    else
        TriggerClientEvent('az_fire:notify', src, { type='info', text='No hotspots here.' })
    end
end)

RegisterNetEvent('az_fire:overhaulComplete', function(targetId)
    local src = source
    local tgt = overhaulTargets[targetId]
    if not tgt or tgt.overhauled then return end
    tgt.overhauled = true
    TriggerClientEvent('az_fire:notify', src, { type='success', text='Overhaul complete. Rekindle unlikely.' })
end)

---------------------------------------------------------------------
-- SCBA
---------------------------------------------------------------------

RegisterNetEvent('az_fire:toggleScba', function()
    local src = source
    local job = Config.GetPlayerJob(src)
    if not Config.Features.SCBA or not Config.FireJobs[job] then
        TriggerClientEvent('az_fire:notify', src, { type='error', text='You are not authorised for SCBA.' })
        return
    end

    if not Config.PlayerHasSCBA(src) then
        TriggerClientEvent('az_fire:notify', src, { type='error', text='You do not have an SCBA pack.' })
        return
    end

    TriggerClientEvent('az_fire:clientToggleScba', src, Config.Smoke.SCBAAirSeconds)
    Config.ConsumeSCBAUse(src)
end)

---------------------------------------------------------------------
-- PUMPER WATER
---------------------------------------------------------------------

RegisterNetEvent('az_fire:consumePumperWater', function(vehNetId, amount)
    if not vehNetId then return end
    local cur = pumperWater[vehNetId] or Config.Pumpers.WaterCapacity
    cur = cur - (amount or 1)
    if cur < 0 then cur = 0 end
    pumperWater[vehNetId] = cur
end)

---------------------------------------------------------------------
-- SAFETY SYSTEMS (PASS / MAYDAY / PAR)
---------------------------------------------------------------------

RegisterNetEvent('az_fire:passTriggered', function(info)
    if not Config.Features.SafetySystems or not Config.Safety.PASS.Enabled then return end
    local src = source
    local job = Config.GetPlayerJob(src)
    if not Config.FireJobs[job] then return end

    local assign    = assignments[src]
    local division  = assign and assign.division or 'Unknown'
    local incidentId= assign and assign.incidentId or 0

    local payload = {
        src        = src,
        name       = info and info.name or ('FF#' .. tostring(src)),
        division   = division,
        incidentId = incidentId,
        coords     = info and info.coords or nil,
    }

    for _, id in ipairs(GetPlayers()) do
        local j = Config.GetPlayerJob(id)
        if Config.FireJobs[j] then
            TriggerClientEvent('az_fire:passAlert', id, payload)
        end
    end
end)

RegisterNetEvent('az_fire:mayday', function(info)
    if not Config.Features.SafetySystems or not Config.Safety.Mayday.Enabled then return end
    local src = source
    local job = Config.GetPlayerJob(src)
    if not Config.FireJobs[job] then return end

    local assign    = assignments[src]
    local division  = assign and assign.division or 'Unknown'
    local incidentId= assign and assign.incidentId or 0

    local payload = {
        src        = src,
        name       = info and info.name or ('FF#' .. tostring(src)),
        division   = division,
        incidentId = incidentId,
        coords     = info and info.coords or nil,
        air        = info and info.air or 0,
    }

    for _, id in ipairs(GetPlayers()) do
        local j = Config.GetPlayerJob(id)
        if Config.FireJobs[j] then
            TriggerClientEvent('az_fire:maydayAlert', id, payload)
        end
    end
end)

local function startPAR(src)
    if not Config.Features.SafetySystems or not Config.Safety.PAR.Enabled then return end
    if not Config.IsIncidentCommand(src) then return end

    local id = (currentPAR and currentPAR.id or 0) + 1
    currentPAR = {
        id         = id,
        startedAt  = os.time(),
        requestedBy= src,
        responses  = {},
    }

    for _, ply in ipairs(GetPlayers()) do
        local j = Config.GetPlayerJob(ply)
        if Config.FireJobs[j] then
            TriggerClientEvent('az_fire:parRequested', ply, {
                id      = id,
                started = currentPAR.startedAt,
            })
        end
    end
end

RegisterNetEvent('az_fire:parConfirm', function()
    local src = source
    if not currentPAR then return end
    currentPAR.responses[src] = true
end)

RegisterCommand('ic_par', function(src)
    if src == 0 then return end
    startPAR(src)
end, false)

---------------------------------------------------------------------
-- ASSIGNMENTS / MARKERS
---------------------------------------------------------------------

RegisterNetEvent('az_fire:setAssignment', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    assignments[src] = data
    TriggerClientEvent('az_fire:assignmentUpdated', src, data)
end)

AddEventHandler('playerDropped', function()
    local src = source
    assignments[src] = nil
end)

local function broadcastMarkers()
    TriggerClientEvent('az_fire:incidentMarkers', -1, incidentMarkers)
end

local function setMarkerPoint(kind, coords)
    incidentMarkers[kind] = coords
    broadcastMarkers()
end

RegisterCommand('ic_cp', function(src)
    if src == 0 then return end
    if not Config.IsIncidentCommand(src) then return end
    local ped = GetPlayerPed(src)
    local x, y, z = table.unpack(GetEntityCoords(ped))
    setMarkerPoint('command', {x=x,y=y,z=z})
end, false)

RegisterCommand('ic_rehab', function(src)
    if src == 0 then return end
    if not Config.IsIncidentCommand(src) then return end
    local ped = GetPlayerPed(src)
    local x, y, z = table.unpack(GetEntityCoords(ped))
    setMarkerPoint('rehab', {x=x,y=y,z=z})
end, false)

RegisterCommand('ic_staging', function(src)
    if src == 0 then return end
    if not Config.IsIncidentCommand(src) then return end
    local ped = GetPlayerPed(src)
    local x, y, z = table.unpack(GetEntityCoords(ped))
    setMarkerPoint('staging', {x=x,y=y,z=z})
end, false)

RegisterCommand('ic_rit', function(src)
    if src == 0 then return end
    if not Config.IsIncidentCommand(src) then return end
    local ped = GetPlayerPed(src)
    local x, y, z = table.unpack(GetEntityCoords(ped))
    setMarkerPoint('rit', {x=x,y=y,z=z})
end, false)

---------------------------------------------------------------------
-- TEST FIRE COMMANDS
---------------------------------------------------------------------

RegisterCommand('testfire', function(src, args)
    local t   = (args[1] or 'random'):lower()
    local job = Config.GetPlayerJob(src)

    if src ~= 0 and not Config.FireJobs[job] then
        TriggerClientEvent('az_fire:notify', src, { type='error', text='You are not fire.' })
        return
    end

    if src ~= 0 then
        local ped = GetPlayerPed(src)
        local x, y, z = table.unpack(GetEntityCoords(ped))
        local coords = {x=x, y=y, z=z}

        if t == 'car' or t == 'vehicle' then
            spawnCarFireAtCoords(coords)
        elseif t == 'wild' or t == 'brush' then
            spawnWildFireAtCoords(coords)
        elseif t == 'house' or t == 'struct' or t == 'structure' then
            spawnHouseFireAtCoords(coords)
        else
            spawnCarFireAtCoords(coords)
        end
    else
        if t == 'car' or t == 'vehicle' then
            spawnCarFireRandom()
        elseif t == 'wild' or t == 'brush' then
            spawnWildFireRandom()
        elseif t == 'house' or t == 'struct' or t == 'structure' then
            spawnHouseFireRandom()
        else
            spawnRandomFireRandom()
        end
    end
end, false)

RegisterCommand('clearfires', function(src)
    if src ~= 0 and not Config.IsIncidentCommand(src) then return end
    fires           = {}
    incidents       = {}
    overhaulTargets = {}
    callouts        = {}
    TriggerClientEvent('az_fire:syncFires', -1, {}, {})
    TriggerClientEvent('az_fire:incidentBlipRemove', -1, -1)
end, false)

---------------------------------------------------------------------
-- BACKGROUND THREADS
---------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(Config.Fire.SpreadCheckInterval * 1000)
        trySpread()
        tryRekindle()
    end
end)

CreateThread(function()
    while true do
        if Config.Performance.RandomFiresEnabled then
            Wait(600000) -- 10 min
            startRandomCallout()
        else
            Wait(60000)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        for id, c in pairs(callouts) do
            if not c.accepted and now - c.createdAt > 300 then
                callouts[id] = nil
            end
        end
    end
end)
