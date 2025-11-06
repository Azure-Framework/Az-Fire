Config = {}

---------------------------------------------------------------------
-- FRAMEWORK INTEGRATION  (ADAPT THESE TO YOUR FRAMEWORK)
---------------------------------------------------------------------

-- Jobs that count as fire
Config.FireJobs = {
    fire = true,
    safd = true,
    lsfd = true,
}

-- Return job name for a player (STUB – replace with your framework)
Config.GetPlayerJob = function(src)
    -- TODO: replace with Az-Framework / ESX / QB, etc.
    return "fire"
end

-- Can this player act as Incident Command?
Config.IsIncidentCommand = function(src)
    local job = Config.GetPlayerJob(src)
    return Config.FireJobs[job] == true
end

-- Does this player have an SCBA pack?
Config.PlayerHasSCBA = function(src)
    -- TODO: check inventory if needed
    return true
end

-- Consume 1 SCBA use (stub)
Config.ConsumeSCBAUse = function(src)
    -- noop for now
end

---------------------------------------------------------------------
-- FEATURE TOGGLES
---------------------------------------------------------------------
Config.Features = {
    SCBA          = true,
    Smoke         = true,
    Hose          = true,
    FireSpread    = true,
    Rekindle      = true,
    SafetySystems = true,  -- PASS, Mayday, PAR
}

---------------------------------------------------------------------
-- SMOKE / SCBA
---------------------------------------------------------------------
Config.Smoke = {
    SCBAAirSeconds  = 1800,   -- 30 minutes of air
    LowAirThreshold = 0.25,   -- 25% = low air
    TickInterval    = 1500,   -- ms between smoke checks
    DamagePerTick   = 4,      -- HP damage when in smoke without SCBA
}

---------------------------------------------------------------------
-- SAFETY SYSTEMS
---------------------------------------------------------------------
Config.Safety = {
    PASS = {
        Enabled         = true,
        PreAlertSeconds = 15,
        FullAlertSeconds= 25,
    },
    Mayday = {
        Enabled = true,
    },
    PAR = {
        Enabled = true,
    },
}

---------------------------------------------------------------------
-- PERFORMANCE / RANDOM FIRES
---------------------------------------------------------------------
Config.Performance = {
    FireLODDistance      = 120.0,
    MaxSimultaneousFires = 25,
    RandomFiresEnabled   = true, -- background random fires
}

---------------------------------------------------------------------
-- RANDOM CALLOUT TIMER
---------------------------------------------------------------------
Config.RandomCallouts = {
    Enabled     = true,   -- master toggle for random callouts
    MinInterval = 60,    -- minimum seconds between callouts (10 min)
    MaxInterval = 60,   -- maximum seconds between callouts (30 min)
}

---------------------------------------------------------------------
-- FIRE BEHAVIOUR / SPOTS
---------------------------------------------------------------------
Config.Fire = {
    Intensity = {
        vehicle = 160,  -- starting “heat”
        wild    = 220,
        house   = 260,
    },

    AlarmForType = {
        vehicle = 1,  -- Level 1
        wild    = 2,  -- Level 2
        house   = 3,  -- Level 3
    },

    SpreadChance        = 0.25, -- per check if hot enough
    SpreadMaxDistance   = 12.0, -- meters from parent fire
    SpreadCheckInterval = 15,   -- seconds between spread checks

    RekindleWindow      = 300,  -- seconds after extinguish where rekindle is possible
    RekindleChance      = 0.30, -- chance of rekindle if not overhauled

    -- Example callout spots – REPLACE with your own
    CarSpots = {
        {x = 215.0,   y = -810.0, z = 30.0},
        {x = -70.0,   y = -1165.0,z = 26.0},
    },
    WildSpots = {
        {x = -550.0,  y = 5380.0, z = 70.0},
        {x = -450.0,  y = 5410.0, z = 75.0},
    },
    HouseSpots = {
        {x = -1045.0, y = -500.0, z = 36.0},
        {x = 120.0,   y = -1060.0,z = 29.0},
    },
}

---------------------------------------------------------------------
-- STATIONS / MAP OVERLAYS
---------------------------------------------------------------------
Config.Stations = {
    {x = 204.8,  y = -801.6,  z = 30.9, label = "Station 1"},
    {x = -633.4, y = -121.8,  z = 38.0, label = "Station 2"},
    {x = -629.0, y = -220.0,  z = 37.0, label = "Station 3"},
}

Config.Overlays = {
    ShowStationBlips = true,
}

---------------------------------------------------------------------
-- HOSE / PUMPER
---------------------------------------------------------------------
Config.Hose = {
    RopeLength        = 15.0,   -- no longer used for rope, kept for compat
    ExtinguishRadius  = 7.5,    -- distance from player that water will cool fires
    ExtinguishAmount  = 6,      -- “heat” removed per tick while spraying
    MaxDistanceSource = 15.0,   -- max distance from hydrant/pumper to connect
}

Config.Pumpers = {
    Models        = { `firetruk` }, -- add your pumpers here
    WaterCapacity = 5000,
}
