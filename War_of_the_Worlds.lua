--[[
    War of the Worlds — Auto Farm Tripods + Gun Mods v1.0
    Jeu : Guerre des mondes (PlaceId 84987799649901)

    Fonctionnalités :
      • Auto farm des tripods : cible le plus proche, se téléporte à bonne distance,
        suit les tripods qui avancent, vise automatiquement et tire en continu.
      • Mods d'armes : munitions infinies, cadence de tir rapide, rechargement rapide,
        aucun recul, aucune dispersion, rechargement automatique.
      • ESP tripods (nom, classe, bouclier, PV, distance) + ESP joueurs optionnel.
      • Interface NextUI (thème Crimson + glass) avec UI de secours pour petits executors.
      • Compatible PC / mobile (Delta, Volcano, Xeno, Solara, ...).

    Note : les dégâts et l'EXP sont calculés côté serveur. Modifier Damage côté client
    ne fonctionne pas ; en revanche la cadence, les munitions et le rechargement
    côté client sont bien pris en compte par le jeu.
]]

--=====================================================================
-- 1. SERVICES
--=====================================================================
local Players            = game:GetService("Players")
local Workspace          = game:GetService("Workspace")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local StarterGui         = game:GetService("StarterGui")

local LP = Players.LocalPlayer

local IS_TOUCH  = UserInputService.TouchEnabled
local IS_MOBILE = IS_TOUCH and not UserInputService.KeyboardEnabled
local LOW_END   = IS_MOBILE

--=====================================================================
-- 2. HELPERS SÉCURISÉS
--=====================================================================
local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function waitFor(parent, name, timeout)
    if not parent then return nil end
    local ok, v = pcall(function() return parent:WaitForChild(name, timeout or 5) end)
    return ok and v or nil
end

local function getChar()
    return LP.Character
end

local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function childOf(parent, ...)
    local cur = parent
    for _, name in ipairs({ ... }) do
        if not cur then return nil end
        cur = cur:FindFirstChild(name)
    end
    return cur
end

-- Certains executors ont gethui(), d'autres get_hidden_gui(), d'autres rien.
local function getGuiParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui end
    local ok2, hg = pcall(function() return get_hidden_gui and get_hidden_gui() end)
    if ok2 and hg then return hg end
    local pg = LP:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok3, cg = pcall(function() return game:GetService("CoreGui") end)
    return ok3 and cg or nil
end

local GUI_TAG = tostring(os.time() % 100000) .. tostring(math.random(100, 999))

local function uiName(base)
    return base .. "_" .. GUI_TAG
end

local ownedGuis = {}
local function ownGui(g)
    if not g then return nil end
    if not table.find(ownedGuis, g) then
        ownedGuis[#ownedGuis + 1] = g
        safe(function() if syn and syn.protect_gui then syn.protect_gui(g) end end)
        safe(function() if protect_gui then protect_gui(g) end end)
    end
    return g
end

local function restoreRobloxUI()
    safe(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, true) end)
    safe(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true) end)
end
restoreRobloxUI()

-- Esc : si une TextBox a le focus, on le rend pour que le menu Roblox s'ouvre.
local escConn = UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.Escape then
        local box = safe(function() return UserInputService:GetFocusedTextBox() end)
        if box then safe(function() box:ReleaseFocus() end) end
    end
end)

--=====================================================================
-- 3. MODULES DU JEU
--=====================================================================
local Rep = waitFor(ReplicatedStorage, "Replicated", 20)

local function tryRequire(inst)
    if not inst then return nil end
    local ok, mod = pcall(require, inst)
    if ok then return mod end
    return nil
end

local GunController = tryRequire(childOf(Rep, "Controllers", "Character", "Equipment", "GunController"))
local GunData       = tryRequire(childOf(Rep, "Data", "GunData"))
local GunShared     = tryRequire(childOf(Rep, "Packages", "GunShared"))
local SurvivalShared = tryRequire(childOf(Rep, "Packages", "SurvivalShared"))
local TeamLevelData  = tryRequire(childOf(Rep, "Data", "TeamLevelData"))

-- Valeurs d'origine des armes.
-- GunData est un ModuleScript mis en cache : si une ancienne exécution du
-- script l'a modifié (cadence, chargeur, recul...), require() renvoie la
-- version modifiée et on ne peut plus jamais revenir aux vraies valeurs.
-- On clone donc le ModuleScript pour obtenir une copie neuve et intacte.
local function pristineGunTable()
    local mod = childOf(Rep, "Data", "GunData")
    if not mod or not mod:IsA("ModuleScript") then return nil end
    local ok, clone = pcall(function() return mod:Clone() end)
    if not ok or not clone then return nil end
    local okParent = pcall(function() clone.Parent = mod.Parent end)
    if not okParent then
        pcall(function() clone:Destroy() end)
        return nil
    end
    local okReq, fresh = pcall(require, clone)
    pcall(function() clone:Destroy() end)
    if okReq and type(fresh) == "table" then return fresh end
    return nil
end

local PRISTINE_GUNS = pristineGunTable()

-- Répare immédiatement les valeurs si un run précédent les avait abîmées.
if PRISTINE_GUNS and type(GunData) == "table" then
    for name, o in pairs(PRISTINE_GUNS) do
        local d = GunData[name]
        if type(d) == "table" and type(o) == "table" then
            d.Cooldown        = o.Cooldown
            d.RecoveryTime    = o.RecoveryTime
            d.ReloadTime      = o.ReloadTime
            d.EmptyReloadTime = o.EmptyReloadTime
            d.ReloadStartTime = o.ReloadStartTime
            d.ReloadEndTime   = o.ReloadEndTime
            d.Recoil          = o.Recoil
            d.Spread          = o.Spread
            d.Capacity        = o.Capacity
            d.MaxAmmo         = o.MaxAmmo
        end
    end
end

--=====================================================================
-- 4. ÉTAT
--=====================================================================
local S = {
    running = true,

    -- farm
    autoFarm        = false,
    targetClass     = "all",       -- all | tripod | uberpod
    maxTargetDist   = 20000,
    standDistance   = 520,
    safeDistance    = true,        -- ne jamais entrer dans la portée des tentacules
    harvestRange    = 450,         -- portée réelle du tripode (TripodShared)
    follow          = false,
    followMode      = "smooth",    -- smooth | teleport
    followSpeed     = 1.0,         -- multiplicateur de la poursuite fluide
    behindTarget    = false,       -- rester dans le dos du tripode
    behindArcSpeed  = 1.6,         -- rad/s : vitesse de contournement du tripode
    behindMaxAngle  = 55,          -- degrés d'écart avant téléportation de secours
    hoverHeight     = 3,
    autoAim         = false,
    autoFire        = false,
    useTeleport     = false,
    retreat         = false,
    retreatHP       = 40,

    -- joueur
    speedHack       = false,
    walkSpeed       = 8,
    jumpBoost       = false,
    jumpPower       = 100,
    godMode         = false,
    godHealth       = 5000,
    infStamina      = false,
    noStarve        = false,
    autoEat         = false,
    autoRespawn     = false,
    hunger          = nil,
    thirst          = nil,

    -- armes
    infAmmo         = false,
    fastFire        = false,
    fireCooldown    = 0.02,
    fastReload      = false,
    noRecoil        = false,
    noSpread        = false,
    autoReload      = false,

    -- esp
    espTripods      = false,
    espPlayers      = false,
    espShowStats    = false,
    espMaxDist      = 6000,

    -- interface
    keybind         = Enum.KeyCode.RightShift,
    mobileButtonPos = "right",
    mobileButtonSize = 48,
    glass           = true,
    lowEnd          = LOW_END,

    -- runtime
    target          = nil,
    safePos         = nil,
    lastTeleport    = 0,
    nextFire        = 0,
}

local COLORS = {
    tripod  = Color3.fromRGB(255, 85, 85),
    uberpod = Color3.fromRGB(200, 120, 255),
    player  = Color3.fromRGB(255, 200, 60),
}

-- Lecture des valeurs de faim / soif envoyées par le serveur (lecture seule).
-- Elles servent à afficher les jauges et à déclencher l'auto-manger.
if SurvivalShared and SurvivalShared.packets and SurvivalShared.packets.survivalStats then
    safe(function()
        SurvivalShared.packets.survivalStats.listen(function(data)
            if type(data) == "table" then
                S.hunger = tonumber(data.hunger)
                S.thirst = tonumber(data.thirst)
            end
        end)
    end)
end

-- Équipe et progression. Le jeu a trois compteurs d'EXP séparés :
-- TeamExp_Military, TeamExp_Survivor, TeamExp_Tripod. Afficher toujours le
-- bon, sinon on croit à tort que l'EXP ne monte pas.
local function currentTeam()
    local team = LP.Team
    local n = team and string.lower(tostring(team.Name)) or ""
    if string.find(n, "surviv") then return "Survivor" end
    if string.find(n, "tripod") then return "Tripod" end
    if string.find(n, "milit") then return "Military" end
    return "Survivor"
end

local function teamExpValue(team)
    return tonumber(LP:GetAttribute("TeamExp_" .. (team or currentTeam()))) or 0
end

local function teamLevelValue(team)
    local exp = teamExpValue(team)
    if TeamLevelData and TeamLevelData.GetLevel then
        local lvl = TeamLevelData.GetLevel(exp)
        if type(lvl) == "number" and lvl > 0 then return lvl end
    end
    return 1
end

--=====================================================================
-- 5. CAMÉRA
--=====================================================================
local camState = nil

local function setCameraScriptable(on)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    if on then
        if not camState then
            camState = {
                type    = cam.CameraType,
                cf      = cam.CFrame,
                subject = cam.CameraSubject,
            }
        end
        safe(function() cam.CameraType = Enum.CameraType.Scriptable end)
    elseif camState then
        safe(function() cam.CameraType = camState.type end)
        safe(function() cam.CFrame = camState.cf end)
        safe(function() cam.CameraSubject = camState.subject end)
        camState = nil
    end
end

local function aimCameraAt(point)
    local cam = Workspace.CurrentCamera
    local hrp = getHRP()
    if not cam then return end
    -- Caméra légèrement au-dessus de la tête : évite qu'elle rentre dans le
    -- sol ou dans le personnage quand on vise un tripode lointain.
    local origin = (hrp and hrp.Position or cam.CFrame.Position) + Vector3.new(0, 8, 0)
    safe(function() cam.CFrame = CFrame.lookAt(origin, point) end)
end

--=====================================================================
-- 6. ARMES
--=====================================================================
local origGunData = {}

local function getCurrentGun()
    local c = GunController and GunController.current
    local gun = c and c.Gun
    if gun and gun.Parent then return gun, c end
    local char = LP.Character
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") and t:GetAttribute("Gun") then
                return t, c
            end
        end
    end
    return nil, c
end

local function ensureEquipped()
    local gun = getCurrentGun()
    if gun then return gun end

    local char = LP.Character
    if not char then return nil end

    local bp = LP:FindFirstChildOfClass("Backpack")
    local tool = nil
    for _, src in ipairs({ char, bp }) do
        if src then
            for _, t in ipairs(src:GetChildren()) do
                if t:IsA("Tool") and t:GetAttribute("Gun") then
                    tool = t
                    break
                end
            end
        end
        if tool then break end
    end

    if not tool then return nil end

    safe(function() tool.Parent = char end)
    task.wait(0.15)
    if GunController and GunController.Equip then
        safe(function() GunController.Equip(tool) end)
        task.wait(0.25)
    end
    return getCurrentGun()
end

local function saveOrigGun(name)
    if origGunData[name] then return end
    local d = (PRISTINE_GUNS and type(PRISTINE_GUNS[name]) == "table" and PRISTINE_GUNS[name])
        or (GunData and GunData[name])
    if type(d) ~= "table" then return end
    origGunData[name] = {
        Cooldown        = d.Cooldown,
        RecoveryTime    = d.RecoveryTime,
        ReloadTime      = d.ReloadTime,
        EmptyReloadTime = d.EmptyReloadTime,
        ReloadStartTime = d.ReloadStartTime,
        ReloadEndTime   = d.ReloadEndTime,
        Recoil          = d.Recoil,
        Spread          = d.Spread,
        Capacity        = d.Capacity,
        MaxAmmo         = d.MaxAmmo,
    }
end

local function applyGunMods()
    if type(GunData) ~= "table" then return end

    for name, d in pairs(GunData) do
        if type(d) == "table" then
            saveOrigGun(name)
            local o = origGunData[name] or {}

            -- La cadence réelle de l'arme est la vitesse maximale que le
            -- serveur accepte. Aller plus vite = tirs refusés (0 dégât, 0 EXP).
            -- "Fast fire" retire donc seulement le délai de récupération.
            if S.fastFire and not (d.Rocket or d.Grenade) then
                d.Cooldown = o.Cooldown
                d.RecoveryTime = 0
            else
                d.Cooldown = o.Cooldown
                d.RecoveryTime = o.RecoveryTime
            end

            if S.fastReload then
                d.ReloadTime = 0.1
                d.EmptyReloadTime = 0.1
                d.ReloadStartTime = 0
                d.ReloadEndTime = 0
            else
                d.ReloadTime = o.ReloadTime
                d.EmptyReloadTime = o.EmptyReloadTime
                d.ReloadStartTime = o.ReloadStartTime
                d.ReloadEndTime = o.ReloadEndTime
            end

            if S.noRecoil then d.Recoil = 0 else d.Recoil = o.Recoil end
            if S.noSpread then d.Spread = 0 else d.Spread = o.Spread end

            -- Les munitions sont gérées par le serveur : on ne touche jamais
            -- au chargeur, sinon le client tire dans le vide et le serveur
            -- rejette tout (plus de dégâts ni d'EXP).
            d.Capacity = o.Capacity
            d.MaxAmmo = o.MaxAmmo
        end
    end
end

local function restoreGunMods()
    if type(GunData) ~= "table" then return end
    for name, o in pairs(origGunData) do
        local d = GunData[name]
        if type(d) == "table" and type(o) == "table" then
            d.Cooldown        = o.Cooldown
            d.RecoveryTime    = o.RecoveryTime
            d.ReloadTime      = o.ReloadTime
            d.EmptyReloadTime = o.EmptyReloadTime
            d.ReloadStartTime = o.ReloadStartTime
            d.ReloadEndTime   = o.ReloadEndTime
            d.Recoil          = o.Recoil
            d.Spread          = o.Spread
            d.Capacity        = o.Capacity
            d.MaxAmmo         = o.MaxAmmo
        end
    end
end

local function rawFire(point)
    if not (GunShared and GunShared.packets and GunShared.packets.gunFire) then return end
    local hrp = getHRP()
    if not hrp then return end
    local cf = CFrame.lookAt(hrp.Position + Vector3.new(0, 3, 0), point)
    safe(function()
        GunShared.packets.gunFire.send({
            firePos = cf,
            seed = math.random(0, 255),
            locked = false,
            target = nil,
        })
    end)
end

local function fireAt(point)
    if GunController and GunController.current then
        local c = GunController.current
        c.SprintActive = false
        c.WallHolding = false
    end
    if GunController and GunController.Fire then
        local ok = pcall(GunController.Fire)
        if ok then return end
    end
    rawFire(point)
end

local function tickGun()
    if type(GunData) ~= "table" then return end

    if S.fastFire or S.fastReload or S.noRecoil or S.noSpread or S.infAmmo then
        applyGunMods()
    end

    local gun = getCurrentGun()
    if not gun and os.clock() - (S.lastEquip or 0) > 3 then
        S.lastEquip = os.clock()
        gun = ensureEquipped()
    end
    if not gun then return end

    if S.infAmmo then
        -- "Munitions infinies" côté serveur impossible : on recharge dès que
        -- le chargeur est presque vide, ce qui est une action légitime.
        local ammo = tonumber(gun:GetAttribute("Ammo")) or 0
        local reloading = gun:GetAttribute("Reloading")
        if ammo <= 1 and not reloading and GunController and GunController.Reload then
            safe(function() GunController.Reload() end)
        end
    end

    if S.autoReload then
        local ammo = tonumber(gun:GetAttribute("Ammo")) or 0
        local reloading = gun:GetAttribute("Reloading")
        if ammo <= 0 and not reloading and GunController and GunController.Reload then
            safe(function() GunController.Reload() end)
        end
    end
end

--=====================================================================
-- 6b. SURVIE (vitesse, stamina, faim / soif)
--=====================================================================
local FOOD_NAMES = {
    MRE = true, Apple = true, Peach = true, ["Bread Roll"] = true, Bread = true,
    Pizza = true, Fish = true, CookedMeat = true, ["Hot Dog"] = true,
    RawMeat = true, TripodCrunch = true,
}
local DRINK_NAMES = {
    Water = true, ["Soda Bottle"] = true, ["Energy Drink"] = true,
}

local function findSurvivalTool(set)
    local ch = LP.Character
    local bp = LP:FindFirstChildOfClass("Backpack")
    for _, src in ipairs({ ch, bp }) do
        if src then
            for _, t in ipairs(src:GetChildren()) do
                if t:IsA("Tool") and set[t.Name] then return t end
            end
        end
    end
    return nil
end

local function useSurvivalTool(tool)
    local hum = getHum()
    if not hum or not tool or not tool.Parent then return end
    safe(function() hum:EquipTool(tool) end)
    task.wait(0.25)
    safe(function() tool:Activate() end)
end

local function tickSurvival()
    local hum = getHum()
    if not hum then return end

    -- Vitesse choisie (le contrôleur du jeu la remet parfois, on la réapplique).
    if S.speedHack then
        local v = math.clamp(tonumber(S.walkSpeed) or 8, 8, 500)
        if math.abs(hum.WalkSpeed - v) > 0.5 then
            safe(function() hum.WalkSpeed = v end)
        end
    end

    -- Saut boosté : le jeu utilise JumpHeight, on force JumpPower et on
    -- réapplique la valeur comme pour la vitesse.
    if S.jumpBoost then
        local jp = math.clamp(tonumber(S.jumpPower) or 100, 50, 1000)
        if hum.UseJumpPower ~= true or math.abs((hum.JumpPower or 0) - jp) > 0.5 then
            safe(function()
                hum.UseJumpPower = true
                hum.JumpPower = jp
            end)
        end
        S.jumpApplied = true
    elseif S.jumpApplied then
        -- Restaure le saut d'origine même si l'option est coupée autrement
        -- que par le toggle (état modifié à la main, rechargement...).
        S.jumpApplied = false
        local o = S.origJump
        safe(function()
            if o then
                hum.UseJumpPower = o.use
                hum.JumpPower = o.power
                hum.JumpHeight = o.height
            else
                hum.UseJumpPower = false
                hum.JumpHeight = 7.2
            end
        end)
        S.origJump = nil
    end

    -- Stamina infinie (attribut utilisé par le sprint du jeu).
    if S.infStamina then
        local maxSt = tonumber(hum:GetAttribute("StaminaMax")) or 217.6
        if (tonumber(hum:GetAttribute("Stamina")) or 0) < maxSt then
            safe(function() hum:SetAttribute("Stamina", maxSt) end)
        end
    end

    -- God mode : PV maintenus au maximum choisi.
    if S.godMode then
        local maxHp = math.clamp(tonumber(S.godHealth) or 5000, 100, 1000000)
        if hum.MaxHealth ~= maxHp then safe(function() hum.MaxHealth = maxHp end) end
        if hum.Health < maxHp then safe(function() hum.Health = maxHp end) end
        safe(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false) end)
    end

    -- Faim / soif : empêche la mort par famine en remontant les PV.
    local h, th = S.hunger, S.thirst
    if S.noStarve and ((h and h < 25) or (th and th < 25)) then
        if hum.Health < hum.MaxHealth then
            safe(function() hum.Health = hum.MaxHealth end)
        end
    end

    -- Auto-manger / boire (uniquement les vrais outils présents dans le sac).
    if S.autoEat and os.clock() - (S.lastEat or 0) > 8 then
        if h and h < 35 then
            local food = findSurvivalTool(FOOD_NAMES)
            if food then
                S.lastEat = os.clock()
                task.spawn(function() useSurvivalTool(food) end)
            end
        elseif th and th < 35 then
            local drink = findSurvivalTool(DRINK_NAMES)
            if drink then
                S.lastEat = os.clock()
                task.spawn(function() useSurvivalTool(drink) end)
            end
        end
    end
end

--=====================================================================
-- 7. TRIPODS
--=====================================================================
local function getTripods()
    local list = {}
    local folder = Workspace:FindFirstChild("Tripods")
    if not folder then return list end
    local hrp = getHRP()
    local myPos = hrp and hrp.Position or Vector3.zero

    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and m:GetAttribute("Tripod") == true then
            local hum = m:FindFirstChildOfClass("Humanoid")
            local shield = m:FindFirstChild("Shield")
            local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
            if hum and hum.Health > 0 and (shield or root) then
                local pos = (shield and shield.Position) or root.Position
                list[#list + 1] = {
                    model     = m,
                    hum       = hum,
                    shield    = shield,
                    root      = root,
                    class     = tostring(m:GetAttribute("TripodClass") or "Tripod"),
                    shieldHP  = tonumber(m:GetAttribute("ShieldHealth")) or 0,
                    shieldMax = tonumber(m:GetAttribute("ShieldMaxHealth")) or 0,
                    pos       = pos,
                    dist      = (pos - myPos).Magnitude,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

local function matchesClass(t)
    if S.targetClass == "tripod" then return t.class == "Tripod" end
    if S.targetClass == "uberpod" then return t.class == "Uberpod" end
    return true
end

local function pickTarget()
    local list = getTripods()

    if S.target then
        for _, t in ipairs(list) do
            if t.model == S.target and t.dist <= S.maxTargetDist and matchesClass(t) then
                return t
            end
        end
    end

    for _, t in ipairs(list) do
        if t.dist <= S.maxTargetDist and matchesClass(t) then
            return t
        end
    end
    return nil
end

local function aimPoint(t)
    if t.shieldHP > 0 and t.shield and t.shield.Parent then
        return t.shield.Position
    end
    if t.root and t.root.Parent then return t.root.Position end
    return t.model:GetPivot().Position
end

-- Anticipation : à longue distance la balle met du temps à arriver, on vise
-- donc légèrement devant un tripod qui avance.
local function leadPoint(t, point)
    local hrp = getHRP()
    if not hrp then return point end
    local dist = (point - hrp.Position).Magnitude

    local speed = 3000
    if type(GunData) == "table" then
        local gun = getCurrentGun()
        local d = gun and GunData[gun.Name]
        if type(d) == "table" and tonumber(d.BulletSpeed) then
            speed = tonumber(d.BulletSpeed)
        end
    end

    local root = t.root
    local vel = (root and root.Parent) and root.AssemblyLinearVelocity or Vector3.zero
    if vel.Magnitude < 1 then return point end

    local tof = dist / math.max(speed, 1)
    return point + vel * tof
end

local function hasLOS(t, point)
    local cam = Workspace.CurrentCamera
    local hrp = getHRP()
    local origin = (cam and cam.CFrame.Position) or (hrp and hrp.Position)
    if not origin then return false end

    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {
        LP.Character,
        Workspace:FindFirstChild("CosmeticBulletFolder"),
    }

    local res = Workspace:Raycast(origin, (point - origin).Unit * 5000, rp)
    if not res then return true end
    if res.Instance and res.Instance:IsDescendantOf(t.model) then return true end
    return false
end

-- Position au sol du tripod (le bouclier est très haut dans les airs, il ne
-- faut donc surtout pas calculer la distance horizontale depuis le bouclier).
local function targetBase(t)
    if t.root and t.root.Parent then return t.root.Position end
    return t.model:GetPivot().Position
end

-- Vecteur horizontal unitaire, ou nil si le vecteur est (quasi) vertical.
local function flatVec(v)
    if v == nil or typeof(v) ~= "Vector3" then return nil end
    local f = Vector3.new(v.X, 0, v.Z)
    if f.Magnitude < 1e-3 then return nil end
    return f.Unit
end

-- Direction "avant" du tripode : celle vers laquelle il regarde et marche.
-- On prend l'orientation du corps (HumanoidRootPart), puis en secours son
-- déplacement réel, puis les caméras du modèle.
local function tripodForward(t)
    local f
    if t.root and t.root.Parent then
        f = flatVec(t.root.CFrame.LookVector)
    end
    if not f and t.hum then
        f = flatVec(t.hum.MoveDirection)
    end
    if not f and t.model then
        local cams = t.model:FindFirstChild("Cameras")
        if cams then
            local fp = cams:FindFirstChild("FirstPerson") or cams:FindFirstChild("ThirdPerson")
            if fp and fp:IsA("BasePart") then
                f = flatVec(fp.CFrame.LookVector)
            end
        end
    end
    return f
end

-- Direction idéale : exactement à l'opposé du regard du tripode.
local function behindDirExact(t)
    local f = tripodForward(t)
    if not f then return nil end
    return -f
end

-- Écart (en degrés) entre le joueur et la position idéale dans le dos.
-- 0 = parfaitement derrière, 180 = juste devant le tripode.
local function behindError(t)
    local f = tripodForward(t)
    local hrp = getHRP()
    if not f or not hrp then return nil end
    local d = flatVec(hrp.Position - targetBase(t))
    if not d then return nil end
    local dot = math.clamp(d:Dot(-f), -1, 1)
    return math.deg(math.acos(dot))
end

-- Direction horizontale stable autour du tripod. Si le joueur est presque
-- au-dessus du tripod, on garde le dernier angle connu au lieu de partir
-- vers (0,0,1) et de se retrouver sous le tripod.
local function flatDirFrom(t, fromPos)
    local base = targetBase(t)
    local d = Vector3.new(fromPos.X - base.X, 0, fromPos.Z - base.Z)
    if d.Magnitude < 8 then
        local stored = S.bearing and S.bearing[t.model]
        if not stored then
            local a = math.random() * math.pi * 2
            stored = Vector3.new(math.cos(a), 0, math.sin(a))
            S.bearing = S.bearing or {}
            S.bearing[t.model] = stored
        end
        return stored
    end
    d = d.Unit
    S.bearing = S.bearing or {}
    S.bearing[t.model] = d
    return d
end

local function groundYAt(x, z, refY, t)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { LP.Character, t.model }
    local res = Workspace:Raycast(
        Vector3.new(x, refY + 250, z),
        Vector3.new(0, -1500, 0),
        rp
    )
    if res then
        -- Sécurité : on refuse un sol aberrant (sous la carte, toit lointain)
        -- qui ferait tomber le personnage dans le vide.
        local dy = res.Position.Y - refY
        if dy > -700 and dy < 400 then return res.Position.Y end
    end
    return nil
end

-- Distance réellement gardée : jamais dans la portée des tentacules.
-- HARVEST_RANGE du jeu = 450 studs, on garde 30 studs de marge.
local function effectiveStand()
    local stand = math.clamp(tonumber(S.standDistance) or 520, 20, 2000)
    if S.safeDistance then
        local minSafe = (tonumber(S.harvestRange) or 450) + 30
        if stand < minSafe then stand = minSafe end
    end
    return stand
end

-- Point d'arrivée souhaité : à `standDistance` du tripod, sur un cercle
-- stable, à hauteur du sol (avec une petite marge).
-- Si `behindTarget` est actif, le point est placé dans le dos du tripode.
local function desiredPos(t, hrp, noClamp, exactBehind)
    local base = targetBase(t)
    local dir

    if S.behindTarget then
        dir = behindDirExact(t)
    end

    if not dir then
        dir = flatDirFrom(t, hrp.Position)
    end

    local stand = effectiveStand()
    local x = base.X + dir.X * stand
    local z = base.Z + dir.Z * stand
    local curY = hrp.Position.Y
    local y = groundYAt(x, z, base.Y, t)
    if y then
        y = y + (tonumber(S.hoverHeight) or 3)
        -- On ne descend jamais brutalement : évite de traverser le sol quand
        -- le raycast accroche une surface plus basse. Même une téléportation
        -- reste bornée (250 studs) pour ne jamais finir sous la carte.
        local maxDrop = noClamp and 250 or 25
        y = math.clamp(y, curY - maxDrop, curY + maxDrop)
    else
        y = curY
    end
    return Vector3.new(x, y, z)
end

local function teleportNear(t, exactBehind, force)
    if not (S.useTeleport or force) then return false end
    local hrp = getHRP()
    if not hrp then return false end

    local pos = desiredPos(t, hrp, true, exactBehind)
    local point = aimPoint(t)

    local ok = pcall(function()
        hrp.CFrame = CFrame.lookAt(pos, Vector3.new(point.X, pos.Y, point.Z))
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)

    if ok then
        S.lastTeleport = os.clock()
        S.nextFire = os.clock() + 0.15
    end
    return ok
end

-- Poursuite fluide : on déplace le personnage par petits pas vers le point
-- d'arrivée, sans jamais couper le tir.
-- En mode « dans le dos », on tourne autour du tripode le long du cercle :
-- jamais de ligne droite à travers lui (ce qui rentrerait dans sa portée).
local function moveSmooth(t, hrp, dt)
    local speed = math.clamp(tonumber(S.followSpeed) or 1, 0.1, 4)
    local stand = effectiveStand()
    local maxStep = math.min(250 + stand, 320) * dt * speed

    local want = S.behindTarget and behindDirExact(t) or nil
    if want then
        local base = targetBase(t)
        local off = Vector3.new(hrp.Position.X - base.X, 0, hrp.Position.Z - base.Z)
        local radius = off.Magnitude
        local curAng = radius > 1 and math.atan2(off.Z, off.X) or math.atan2(want.Z, want.X)
        local wantAng = math.atan2(want.Z, want.X)
        local diff = (wantAng - curAng + math.pi) % (math.pi * 2) - math.pi

        local maxAng = maxStep / math.max(radius, stand, 20)
        local newAng = curAng + math.clamp(diff, -maxAng, maxAng)

        -- Correction radiale douce pour rester à la bonne distance.
        local radialStep = math.clamp(stand - radius, -maxStep, maxStep)
        local newRadius = math.max(radius + radialStep, 20)

        local dir = Vector3.new(math.cos(newAng), 0, math.sin(newAng))
        local np = Vector3.new(base.X, hrp.Position.Y, base.Z) + dir * newRadius

        local y = groundYAt(np.X, np.Z, base.Y, t)
        if y then
            y = y + (tonumber(S.hoverHeight) or 3)
            y = math.clamp(y, hrp.Position.Y - 25, hrp.Position.Y + 25)
        else
            y = hrp.Position.Y
        end
        np = Vector3.new(np.X, y, np.Z)

        if (np - hrp.Position).Magnitude < 1.0 then return end
        pcall(function()
            hrp.CFrame = CFrame.new(np) * hrp.CFrame.Rotation
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
        return
    end

    local dest = desiredPos(t, hrp)
    local cur = hrp.Position
    local delta = dest - cur
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local err = flat.Magnitude

    -- Zone morte : on ne bouge plus quand on est déjà bien placé.
    if err < 1.5 and math.abs(delta.Y) < 1.5 then return end

    local alpha = math.clamp(dt * 5 * speed, 0, 0.35)
    local step = flat * alpha
    if step.Magnitude > maxStep then
        step = step.Unit * maxStep
    end

    local dy = math.clamp(delta.Y, -5, 5) * math.clamp(dt * 8, 0, 1)
    local np = cur + step + Vector3.new(0, dy, 0)

    pcall(function()
        hrp.CFrame = CFrame.new(np) * hrp.CFrame.Rotation
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function shouldTeleport(t)
    if not S.useTeleport then return false end
    if os.clock() - S.lastTeleport < 1.5 then return false end

    local hrp = getHRP()
    if not hrp then return false end

    local dist = (desiredPos(t, hrp) - hrp.Position).Magnitude
    local stand = effectiveStand()

    -- Uniquement pour rattraper un gros décrochage (tripod très loin ou
    -- passage derrière un obstacle). Sinon c'est moveSmooth qui gère.
    if dist > math.max(700, stand * 6) then return true end
    if not hasLOS(t, aimPoint(t)) and dist > stand * 1.5 then return true end
    return false
end

local statusUpdater = nil

local function tickFarm()
    if not S.autoFarm then return end

    local hum = getHum()
    local hrp = getHRP()
    if not hum or not hrp or hum.Health <= 0 then
        setCameraScriptable(false)
        return
    end

    -- En véhicule, on ne peut pas se déplacer à pied : on attend.
    if hum.SeatPart then return end

    local now = os.clock()
    local dt = math.clamp(now - (S.lastTick or now), 0.001, 0.1)
    S.lastTick = now

    if not S.safePos then S.safePos = hrp.Position end

    -- Retraite si PV bas : on monte un peu au-dessus du sol, on ne part pas
    -- à 600 studs (c'était ce qui envoyait le joueur « à la sortie »).
    if S.retreat and hum.Health < S.retreatHP then
        if not S.retreating then
            S.retreating = true
            safe(function()
                hrp.CFrame = hrp.CFrame + Vector3.new(0, 60, 0)
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        setCameraScriptable(false)
        return
    elseif S.retreating then
        S.retreating = false
    end

    local t = pickTarget()
    if not t then
        S.target = nil
        if statusUpdater and now - (S.lastStatus or 0) > 1.0 then
            S.lastStatus = now
            statusUpdater("No tripod found. Move closer or raise Max target distance.")
        end
        return
    end

    -- Anti-chute : si le personnage est passé sous le décor ou dans le vide,
    -- on le remonte à la dernière position sûre (la caméra ne finit pas dans
    -- le sol et le farm reprend).
    local fell = hrp.Position.Y < -50
    if not fell and S.safePos and hrp.Position.Y < S.safePos.Y - 900 then
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.FilterDescendantsInstances = { LP.Character }
        local res = Workspace:Raycast(hrp.Position, Vector3.new(0, -2000, 0), rp)
        fell = (res == nil)
    end
    if fell then
        local base = targetBase(t)
        local p = S.safePos
        if not p or p.Y < -50 then
            p = Vector3.new(base.X, base.Y + 100, base.Z)
        end
        safe(function()
            hrp.CFrame = CFrame.new(p + Vector3.new(0, 30, 0))
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
        return
    end

    if statusUpdater and now - (S.lastStatus or 0) > 0.7 then
        S.lastStatus = now
        local sh = tonumber(t.model:GetAttribute("ShieldHealth")) or 0
        local shMax = tonumber(t.model:GetAttribute("ShieldMaxHealth")) or 0
        local pct = shMax > 0 and math.floor(sh / shMax * 100) or 0
        local base = targetBase(t)
        local flat = math.floor(Vector3.new(
            base.X - hrp.Position.X, 0, base.Z - hrp.Position.Z
        ).Magnitude)
        local danger = (flat < (tonumber(S.harvestRange) or 450) + 20) and " | GRAB RISK" or ""

        local behindTag = ""
        if S.behindTarget then
            local be = behindError(t)
            if be then
                behindTag = be <= 60
                    and " | BEHIND"
                    or string.format(" | EXPOSED %ddeg", math.floor(be))
            end
        end

        -- Le jeu a un compteur d'EXP par équipe : on affiche celui du joueur.
        local team = currentTeam()
        local gun = getCurrentGun()
        local testGun = (S.testWeapon and gun == S.testWeapon) and " | TEST GUN (no EXP)" or ""

        -- EXP gagnée depuis le début de ce farm (le serveur l'attribue).
        if S.expTeam ~= team then
            S.expTeam = team
            S.expBase = teamExpValue(team)
        end
        local gained = teamExpValue(team) - (S.expBase or 0)
        if gained < 0 then S.expBase = teamExpValue(team); gained = 0 end

        statusUpdater(string.format(
            "%s | Shield %d%% | HP %d/%d | %dm%s%s | %s Lv %s | %s EXP | +%d EXP%s",
            t.class, pct,
            math.floor(t.hum.Health), math.floor(t.hum.MaxHealth),
            flat, danger, behindTag,
            team, tostring(teamLevelValue(team)),
            tostring(teamExpValue(team)),
            gained,
            testGun
        ))
    end

    setCameraScriptable(true)

    -- Sécurité « dans le dos » : si le tripode a pivoté plus vite que la
    -- marche, on se replace immédiatement derrière lui au lieu de rester
    -- exposé à ses lasers / à ses tentacules.
    if S.behindTarget then
        local be = behindError(t)
        if be and be > (tonumber(S.behindMaxAngle) or 55)
            and now - (S.lastTeleport or 0) > 0.5 then
            -- Toujours autorisé : c'est la seule façon de garantir qu'on ne
            -- reste pas face au tripode quand il pivote plus vite qu'on court.
            teleportNear(t, true, true)
        end
    end

    -- Déplacement.
    if S.target ~= t.model then
        S.target = t.model
        local d = (desiredPos(t, hrp) - hrp.Position).Magnitude
        if S.followMode == "teleport" or d > 400 then
            teleportNear(t)
        end
    end

    if S.followMode == "smooth" then
        if S.follow then
            if shouldTeleport(t) then
                teleportNear(t)
            else
                moveSmooth(t, hrp, dt)
            end
        elseif shouldTeleport(t) then
            teleportNear(t)
        end
    elseif S.follow and shouldTeleport(t) then
        teleportNear(t)
    end

    local gun = getCurrentGun()
    if not gun and now - (S.lastEquip or 0) > 3 then
        S.lastEquip = now
        gun = ensureEquipped()
    end
    if not gun then return end

    if S.infAmmo then
        local ammo = tonumber(gun:GetAttribute("Ammo")) or 0
        local reloading = gun:GetAttribute("Reloading")
        if ammo <= 1 and not reloading and GunController and GunController.Reload then
            safe(function() GunController.Reload() end)
        end
    end

    -- Un cooldown bloqué = le serveur a refusé le tir. Insister ne sert à
    -- rien (0 dégât, 0 EXP) : on recharge proprement pour repartir.
    if gun:GetAttribute("Cooldown") == true then
        S.cooldownSince = S.cooldownSince or now
        if now - S.cooldownSince > 1.5 then
            if GunController and GunController.Reload then
                safe(function() GunController.Reload() end)
            end
            safe(function() gun:SetAttribute("Cooldown", false) end)
            S.cooldownSince = nil
        end
    else
        S.cooldownSince = nil
    end

    local point = leadPoint(t, aimPoint(t))

    if S.autoAim then
        aimCameraAt(point)
    end

    -- Tir continu : Fire() gère lui-même sa cadence interne.
    if S.autoFire and now >= (S.nextFire or 0) then
        fireAt(point)
    end
end

--=====================================================================
-- 8. ESP
--=====================================================================
local espGui = nil
local espCache = {}
local espTracers = {}

local function getEspGui()
    if espGui and espGui.Parent then return espGui end
    local g = Instance.new("ScreenGui")
    g.Name = uiName("WotW_ESP")
    g.ResetOnSpawn = false
    g.IgnoreGuiInset = true
    g.DisplayOrder = 999
    g.Parent = getGuiParent()
    ownGui(g)
    espGui = g
    return g
end

local function clearEsp()
    for inst, info in pairs(espCache) do
        if info.hl then safe(function() info.hl:Destroy() end) end
        if info.bb then safe(function() info.bb:Destroy() end) end
        espCache[inst] = nil
    end
    for inst, line in pairs(espTracers) do
        safe(function() line:Remove() end)
        espTracers[inst] = nil
    end
    if espGui then
        for _, c in ipairs(espGui:GetChildren()) do
            if c:IsA("Highlight") or c:IsA("BillboardGui") then
                safe(function() c:Destroy() end)
            end
        end
    end
end

local function espAdd(keep, count, inst, part, color, label)
    if count >= (S.lowEnd and 25 or 60) then return count end
    if not inst or not inst.Parent then return count end
    keep[inst] = true
    count = count + 1

    local info = espCache[inst]
    if not info or not info.hl or not info.hl.Parent then
        local gui = getEspGui()
        local hl = Instance.new("Highlight")
        hl.Name = "WotWHL"
        hl.Adornee = inst
        hl.FillColor = color
        hl.FillTransparency = 0.72
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
        safe(function() hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop end)
        hl.Parent = gui

        local bb
        if part then
            bb = Instance.new("BillboardGui")
            bb.Name = "WotWBB"
            bb.Adornee = part
            bb.Size = UDim2.fromOffset(190, 30)
            bb.StudsOffset = Vector3.new(0, 4, 0)
            bb.AlwaysOnTop = true
            bb.MaxDistance = S.espMaxDist
            bb.Parent = gui

            local txt = Instance.new("TextLabel")
            txt.BackgroundTransparency = 1
            txt.Size = UDim2.fromScale(1, 1)
            txt.Font = Enum.Font.GothamBold
            txt.TextSize = S.lowEnd and 10 or 12
            txt.TextColor3 = color
            txt.TextStrokeTransparency = 0.35
            txt.Text = label
            txt.Parent = bb
        end

        info = { hl = hl, bb = bb }
        espCache[inst] = info
    else
        info.hl.FillColor = color
        info.hl.OutlineColor = color
        if info.bb then
            info.bb.MaxDistance = S.espMaxDist
            local txt = info.bb:FindFirstChildOfClass("TextLabel")
            if txt then
                txt.Text = label
                txt.TextColor3 = color
            end
        end
    end

    return count
end

local function espTick()
    if not (S.espTripods or S.espPlayers) then
        if espGui then clearEsp() end
        return
    end

    local hrp = getHRP()
    if not hrp then return end
    local myPos = hrp.Position
    local keep, count = {}, 0
    local candidates = {}

    if S.espTripods then
        local folder = Workspace:FindFirstChild("Tripods")
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") and m:GetAttribute("Tripod") == true then
                    local hum = m:FindFirstChildOfClass("Humanoid")
                    local shield = m:FindFirstChild("Shield")
                    local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                    if hum and hum.Health > 0 and (shield or root) then
                        local part = shield or root
                        local d = (part.Position - myPos).Magnitude
                        if d <= S.espMaxDist then
                            local cls = tostring(m:GetAttribute("TripodClass") or "Tripod")
                            local color = (cls == "Uberpod") and COLORS.uberpod or COLORS.tripod
                            local label = cls
                            if S.espShowStats then
                                local sh = tonumber(m:GetAttribute("ShieldHealth")) or 0
                                local shMax = tonumber(m:GetAttribute("ShieldMaxHealth")) or 0
                                local pct = shMax > 0 and math.floor(sh / shMax * 100) or 0
                                label = string.format(
                                    "%s | Shield %d%% | HP %d/%d | %dm",
                                    cls, pct,
                                    math.floor(hum.Health), math.floor(hum.MaxHealth),
                                    math.floor(d)
                                )
                            else
                                label = string.format("%s | %dm", cls, math.floor(d))
                            end
                            candidates[#candidates + 1] = { m, part, color, label, d }
                        end
                    end
                end
            end
        end
    end

    if S.espPlayers then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then
                local char = plr.Character
                local part = char and char:FindFirstChild("HumanoidRootPart")
                if part then
                    local d = (part.Position - myPos).Magnitude
                    if d <= S.espMaxDist then
                        local hum = char:FindFirstChildOfClass("Humanoid")
                        local hp = hum and math.max(0, math.floor(hum.Health)) or 0
                        local maxhp = hum and math.max(1, math.floor(hum.MaxHealth)) or 1
                        local label = string.format("%s | %d/%d | %dm", plr.Name, hp, maxhp, math.floor(d))
                        candidates[#candidates + 1] = { char, part, COLORS.player, label, d }
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a[5] < b[5] end)

    for i = 1, #candidates do
        local c = candidates[i]
        count = espAdd(keep, count, c[1], c[2], c[3], c[4])
    end

    for inst, info in pairs(espCache) do
        if not keep[inst] then
            if info.hl then safe(function() info.hl:Destroy() end) end
            if info.bb then safe(function() info.bb:Destroy() end) end
            espCache[inst] = nil
        end
    end

    -- Nettoyage des enfants orphelins.
    if espGui and espGui.Parent then
        local alive = {}
        for _, info in pairs(espCache) do
            if info.hl then alive[info.hl] = true end
            if info.bb then alive[info.bb] = true end
        end
        for _, c in ipairs(espGui:GetChildren()) do
            if not alive[c] then safe(function() c:Destroy() end) end
        end
    end
end

--=====================================================================
-- 8b. RESPAWN AUTOMATIQUE
--=====================================================================
-- Quand on meurt, le jeu affiche l'écran de mort et attend qu'on choisisse
-- un point de spawn. Sans ça, le personnage reste sans arme et l'auto farm
-- tourne dans le vide (aucun tir, aucune EXP).
local DeathShared = tryRequire(childOf(Rep, "Packages", "DeathShared"))

local function tickRespawn()
    if not S.autoRespawn then return end
    local ch = LP.Character
    if not ch then return end
    if ch:GetAttribute("DeathChoicePending") ~= true then return end
    if ch:GetAttribute("DeathRespawnReady") ~= true then return end
    if os.clock() - (S.lastRespawn or 0) < 3 then return end
    S.lastRespawn = os.clock()
    if DeathShared and DeathShared.packets and DeathShared.packets.request then
        safe(function()
            DeathShared.packets.request.send({
                character = ch,
                choice = "normal",
                point = "",
                baseSpawn = nil,
                baseId = nil,
            })
        end)
    end
end

--=====================================================================
-- 9. BOUCLES
--=====================================================================
local function loop(name, intervalFn, fn)
    task.spawn(function()
        while S.running do
            local ok, err = pcall(fn)
            if not ok then
                print("[WotW] " .. name .. " : " .. tostring(err))
            end
            task.wait(intervalFn())
        end
    end)
end

loop("farm", function() return S.lowEnd and 0.06 or 0.02 end, tickFarm)
loop("gun",  function() return S.lowEnd and 0.50 or 0.25 end, tickGun)
loop("survival", function() return S.lowEnd and 0.40 or 0.20 end, tickSurvival)
loop("esp",  function() return S.lowEnd and 0.90 or 0.45 end, espTick)
loop("respawn", function() return 1.0 end, tickRespawn)

--=====================================================================
-- 10. UI — NextUI + repli
--=====================================================================
local function loadNextUI()
    if type(loadstring) ~= "function" then return nil end
    local ok, src = pcall(function() return game:HttpGet("https://diser.me/nextui/source.lua") end)
    if not ok or type(src) ~= "string" or #src < 1000 then return nil end
    local fn = loadstring(src)
    if not fn then return nil end
    local ok2, lib = pcall(fn)
    if ok2 and type(lib) == "table" and lib.CreateWindow then return lib end
    return nil
end

local function fallbackWindow()
    local gui = Instance.new("ScreenGui")
    gui.Name = uiName("WotWUI")
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.DisplayOrder = 100
    gui.Parent = getGuiParent()
    ownGui(gui)

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(310, 420)
    main.Position = UDim2.new(0, 16, 0.5, -210)
    main.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = gui
    local mc = Instance.new("UICorner") mc.CornerRadius = UDim.new(0, 8) mc.Parent = main

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -40, 0, 32)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Text = "War of the Worlds"
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(28, 28)
    close.Position = UDim2.new(1, -34, 0, 4)
    close.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
    close.Text = "X"
    close.TextColor3 = Color3.new(1, 1, 1)
    close.Font = Enum.Font.GothamBold
    close.TextSize = 12
    close.Parent = main
    local cc = Instance.new("UICorner") cc.CornerRadius = UDim.new(0, 6) cc.Parent = close

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -44)
    scroll.Position = UDim2.fromOffset(8, 38)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = main

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroll
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
    end)

    local order = 0
    local function nextOrder() order = order + 1 return order end

    local function row(text, height)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, height or 34)
        b.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
        b.BorderSizePixel = 0
        b.Text = text
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 13
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.LayoutOrder = nextOrder()
        b.Parent = scroll
        local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 6) c.Parent = b
        local p = Instance.new("UIPadding") p.PaddingLeft = UDim.new(0, 10) p.Parent = b
        return b
    end

    local Win = {}
    function Win:AddCategory() end
    function Win:Toggle() main.Visible = not main.Visible end

    function Win:AddTab(name)
        local h = row("— " .. tostring(name) .. " —", 24)
        h.BackgroundTransparency = 1
        h.TextColor3 = Color3.fromRGB(160, 160, 175)
        h.Font = Enum.Font.GothamBold
        h.TextSize = 12

        local tab = {}
        function tab:AddSection(opts)
            local s = row("• " .. tostring(opts and opts.Title or "Section"), 24)
            s.BackgroundTransparency = 1
            s.TextColor3 = Color3.fromRGB(200, 200, 215)
            s.Font = Enum.Font.GothamBold
            s.TextSize = 12

            local sec = {}

            function sec:AddToggle(o)
                local on = o.Default and true or false
                local b = row((on and "[ON] " or "[OFF] ") .. tostring(o.Title), 34)
                b.BackgroundColor3 = on and Color3.fromRGB(48, 90, 60) or Color3.fromRGB(40, 40, 48)
                b.MouseButton1Click:Connect(function()
                    on = not on
                    b.Text = (on and "[ON] " or "[OFF] ") .. tostring(o.Title)
                    b.BackgroundColor3 = on and Color3.fromRGB(48, 90, 60) or Color3.fromRGB(40, 40, 48)
                    if o.Callback then pcall(o.Callback, on) end
                end)
                if o.Default and o.Callback then pcall(o.Callback, true) end
                return b
            end

            function sec:AddButton(o)
                local b = row(tostring(o.Title), 34)
                b.MouseButton1Click:Connect(function()
                    if o.Callback then pcall(o.Callback) end
                end)
                return b
            end

            function sec:AddDropdown(o)
                local values = o.Values or {}
                local idx = 1
                local b = row(tostring(o.Title) .. " : " .. tostring(values[1] or "All"), 34)
                b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
                b.MouseButton1Click:Connect(function()
                    if #values == 0 then return end
                    idx = idx % #values + 1
                    b.Text = tostring(o.Title) .. " : " .. tostring(values[idx])
                    if o.Callback then pcall(o.Callback, values[idx]) end
                end)
                if o.Default and o.Callback then pcall(o.Callback, o.Default) end
                return b
            end

            function sec:AddParagraph(o)
                local b = row(tostring(o.Title) .. "\n" .. tostring(o.Content or ""), 46)
                b.BackgroundTransparency = 1
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.TextYAlignment = Enum.TextYAlignment.Top
                b.TextWrapped = true
                b.TextColor3 = Color3.fromRGB(170, 170, 185)
                b.Font = Enum.Font.Gotham
                b.TextSize = 11
                return b
            end

            function sec:AddTextbox(o)
                local box = Instance.new("TextBox")
                box.Size = UDim2.new(1, 0, 0, 34)
                box.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
                box.BorderSizePixel = 0
                box.Text = tostring(o.Default or "")
                box.PlaceholderText = tostring(o.Title or "")
                box.TextColor3 = Color3.new(1, 1, 1)
                box.Font = Enum.Font.Gotham
                box.TextSize = 13
                box.ClearTextOnFocus = false
                box.LayoutOrder = nextOrder()
                box.Parent = scroll
                local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 6) c.Parent = box
                box.FocusLost:Connect(function()
                    if o.Callback then pcall(o.Callback, box.Text) end
                    task.defer(function() if box.Parent then box:ReleaseFocus() end end)
                end)
                return box
            end

            function sec:AddKeybind(o)
                local b = row(tostring(o.Title) .. " : " .. (o.Default and o.Default.Name or "None"), 34)
                b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
                local listening = false
                b.MouseButton1Click:Connect(function()
                    listening = true
                    b.Text = tostring(o.Title) .. " : press a key..."
                end)
                local conn
                conn = UserInputService.InputBegan:Connect(function(input)
                    if not listening then return end
                    if input.UserInputType == Enum.UserInputType.Keyboard then
                        listening = false
                        b.Text = tostring(o.Title) .. " : " .. input.KeyCode.Name
                        if o.ChangedCallback then pcall(o.ChangedCallback, input.KeyCode) end
                        conn:Disconnect()
                    end
                end)
                return b
            end

            function sec:AddColorPicker(o)
                local colors = {
                    Color3.fromRGB(255, 85, 85),
                    Color3.fromRGB(90, 220, 120),
                    Color3.fromRGB(80, 180, 255),
                    Color3.fromRGB(255, 200, 60),
                    Color3.fromRGB(200, 120, 255),
                    Color3.fromRGB(255, 255, 255),
                }
                local idx = 1
                local b = row(tostring(o.Title) .. " : color", 34)
                b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
                b.MouseButton1Click:Connect(function()
                    idx = idx % #colors + 1
                    if o.Callback then pcall(o.Callback, colors[idx]) end
                end)
                if o.Default and o.Callback then pcall(o.Callback, o.Default) end
                return b
            end

            return sec
        end
        return tab
    end

    close.MouseButton1Click:Connect(function() main.Visible = false end)

    local fab = Instance.new("TextButton")
    fab.Size = UDim2.fromOffset(46, 46)
    fab.Position = UDim2.new(0, 12, 0.5, 220)
    fab.BackgroundColor3 = Color3.fromRGB(70, 40, 120)
    fab.Text = "WW"
    fab.TextColor3 = Color3.new(1, 1, 1)
    fab.Font = Enum.Font.GothamBold
    fab.TextSize = 14
    fab.Parent = gui
    local fc = Instance.new("UICorner") fc.CornerRadius = UDim.new(1, 0) fc.Parent = fab
    fab.MouseButton1Click:Connect(function() main.Visible = not main.Visible end)

    return Win
end

local NextUI = loadNextUI()
local Window

local function guiSnapshot()
    local set = {}
    for _, root in ipairs({ getGuiParent(), LP:FindFirstChild("PlayerGui") }) do
        if root then
            for _, g in ipairs(root:GetChildren()) do
                set[g] = true
            end
        end
    end
    return set
end

local guisBefore = guiSnapshot()

if NextUI then
    Window = NextUI:CreateWindow({
        Title = "War of the Worlds",
        SubTitle = "v1.0",
        Theme = "Crimson",
        Glass = true,
        Size = IS_MOBILE and Vector2.new(340, 320) or Vector2.new(780, 500),
        Resizable = not IS_MOBILE,
        Search = false,
        ToggleKey = { Enum.KeyCode.Insert, S.keybind },
        MobileButton = IS_MOBILE
            and { Size = S.mobileButtonSize, Position = UDim2.new(1, -(S.mobileButtonSize / 2 + 14), 0.35, 0), Draggable = true }
            or true,
    })
else
    Window = fallbackWindow()
end

for _, root in ipairs({ getGuiParent(), LP:FindFirstChild("PlayerGui") }) do
    if root then
        for _, g in ipairs(root:GetChildren()) do
            if not guisBefore[g] and g:IsA("ScreenGui") then
                ownGui(g)
            end
        end
    end
end

local function fixNextUI()
    local roots = { getGuiParent(), LP:FindFirstChild("PlayerGui") }
    for _, root in ipairs(roots) do
        if root then
            for _, g in ipairs(root:GetChildren()) do
                if g.Name == "NextUI" or g.Name == "NextUIWindows" or g.Name == "NextUIWatermark" then
                    safe(function() g.IgnoreGuiInset = false end)
                end
            end
        end
    end
end
fixNextUI()
task.delay(1.5, function() safe(fixNextUI) end)

if NextUI then
    local okTheme = pcall(function() NextUI:SetTheme("Crimson", true) end)
    if not okTheme then safe(function() NextUI:SetTheme("Lagoon", true) end) end
    safe(function() NextUI:SetGlass(true) end)
    task.delay(1.0, function() safe(function() NextUI:SetGlass(true) end) end)
end

safe(function() Window:AddCategory("Main Features") end)

-- Bouton mobile : défini avant les onglets car les callbacks UI peuvent
-- l'appeler immédiatement (valeur par défaut des dropdowns).
local function findMobileButton()
    for _, g in ipairs(ownedGuis) do
        local ok, b = pcall(function() return g:FindFirstChild("MobileButton", true) end)
        if ok and b then return b end
    end
    return nil
end

local function applyMobileButton()
    local b = findMobileButton()
    if not b then return end
    local size = math.clamp(tonumber(S.mobileButtonSize) or 48, 32, 96)
    local pad = size / 2 + 14
    safe(function() b.AnchorPoint = Vector2.new(0.5, 0.5) end)
    safe(function() b.Size = UDim2.fromOffset(size, size) end)
    if S.mobileButtonPos == "hidden" then
        safe(function() b.Visible = false end)
        return
    end
    safe(function() b.Visible = true end)
    local pos
    if S.mobileButtonPos == "right-bottom" then
        pos = UDim2.new(1, -pad, 1, -pad)
    elseif S.mobileButtonPos == "left-bottom" then
        pos = UDim2.new(0, pad, 1, -pad)
    elseif S.mobileButtonPos == "left" then
        pos = UDim2.new(0, pad, 0.35, 0)
    elseif S.mobileButtonPos == "top-right" then
        pos = UDim2.new(1, -pad, 0, pad + 30)
    else
        pos = UDim2.new(1, -pad, 0.35, 0)
    end
    safe(function() b.Position = pos end)
end

--=====================================================================
-- 11. ONGLETS
--=====================================================================
local FarmTab = Window:AddTab("Hunter", "crosshair")
local PlayerTab = Window:AddTab("Player", "user")
local GunTab  = Window:AddTab("Gun Mods", "rocket")
local WeaponTab = Window:AddTab("Weapons", "crosshair")
local EspTab  = Window:AddTab("ESP", "eye")
local SetTab  = Window:AddTab("Settings", "settings")

--=====================================================================
-- 11a. HUNTER — AUTO FARM
--=====================================================================
local FarmSection = FarmTab:AddSection({ Title = "Auto Farm Tripods", Icon = "crosshair" })

local statusPara = FarmSection:AddParagraph({
    Title = "Status",
    Content = "Idle. Enable Auto Farm Tripods.",
})

local function setStatus(text)
    safe(function()
        if not statusPara then return end
        if statusPara.Set then
            statusPara:Set(text)
        elseif statusPara.Text ~= nil then
            statusPara.Text = "Status\n" .. tostring(text)
        end
    end)
end

statusUpdater = setStatus

-- Références aux toggles du farm : elles servent à activer le kit de farm
-- quand l'utilisateur coche « Auto Farm » (tout est désactivé au démarrage).
local farmToggles = {}

local function setToggleValue(toggle, on)
    if not toggle then return end
    pcall(function() toggle:SetValue(on) end)
    pcall(function() toggle:Set(on) end)
end

local function armFarmKit()
    if S.farmArmed then return end
    S.farmArmed = true

    -- Kit volontairement "safe" : tout ce qui touche à la cadence ou au
    -- chargeur est laissé de côté, sinon le serveur rejette les tirs
    -- (aucun dégât, aucune EXP).
    S.follow      = true
    S.autoAim     = true
    S.autoFire    = true
    S.useTeleport = true
    S.autoReload  = true
    S.autoRespawn = true
    S.behindTarget = true

    setToggleValue(farmToggles.follow, true)
    setToggleValue(farmToggles.aim, true)
    setToggleValue(farmToggles.fire, true)
    setToggleValue(farmToggles.teleport, true)
    setToggleValue(farmToggles.autoReload, true)
    setToggleValue(farmToggles.respawn, true)
    setToggleValue(farmToggles.behind, true)
end

FarmSection:AddToggle({
    Title = "Auto Farm Tripods",
    Description = "Tracks the nearest tripod, aims and shoots automatically",
    Default = false,
    Flag = "auto_farm_tripods",
    Callback = function(on)
        S.autoFarm = on and true or false
        S.target = nil
        S.lastTeleport = 0
        if S.autoFarm then
            armFarmKit()
            local hrp = getHRP()
            S.safePos = hrp and hrp.Position or nil
            setCameraScriptable(true)
            setStatus("Searching for a tripod...")
        else
            setCameraScriptable(false)
            setStatus("Idle.")
        end
    end,
})

farmToggles.respawn = FarmSection:AddToggle({
    Title = "Auto respawn",
    Description = "Sends the respawn choice automatically so the farm keeps its gun",
    Default = false,
    Flag = "auto_respawn",
    Callback = function(on) S.autoRespawn = on and true or false end,
})

FarmSection:AddDropdown({
    Title = "Target",
    Values = { "All", "Tripod", "Uberpod" },
    Default = "All",
    Search = false,
    Flag = "target_class",
    Callback = function(value)
        local v = string.lower(tostring(value))
        if v == "tripod" then S.targetClass = "tripod"
        elseif v == "uberpod" then S.targetClass = "uberpod"
        else S.targetClass = "all" end
        S.target = nil
    end,
})

FarmSection:AddTextbox({
    Title = "Stand distance (studs)",
    Description = "Distance kept from the tripod (tendrils reach 450)",
    Default = "520",
    Numeric = true,
    Finished = true,
    Flag = "stand_distance",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 20 and v <= 2000 then S.standDistance = v end
    end,
})

FarmSection:AddToggle({
    Title = "Avoid harvest range",
    Description = "Never stands closer than the tendril range + 30 studs",
    Default = true,
    Flag = "safe_distance",
    Callback = function(on) S.safeDistance = on and true or false end,
})

FarmSection:AddTextbox({
    Title = "Tendril range (studs)",
    Description = "The tripod can grab you inside this radius (450 in the game files)",
    Default = "450",
    Numeric = true,
    Finished = true,
    Flag = "harvest_range",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 50 and v <= 2000 then S.harvestRange = v end
    end,
})

FarmSection:AddTextbox({
    Title = "Max target distance (studs)",
    Default = "20000",
    Numeric = true,
    Finished = true,
    Flag = "max_target_dist",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 100 then S.maxTargetDist = v end
    end,
})

farmToggles.follow = FarmSection:AddToggle({
    Title = "Follow moving tripods",
    Description = "Repositions when the tripod advances or moves away",
    Default = false,
    Flag = "follow_tripods",
    Callback = function(on) S.follow = on and true or false end,
})

farmToggles.behind = FarmSection:AddToggle({
    Title = "Stay behind tripod",
    Description = "Always orbits to the tripod's back so it cannot turn and grab or laser you",
    Default = false,
    Flag = "behind_tripod",
    Callback = function(on)
        S.behindTarget = on and true or false
        if on then
            -- Repart d'une position connue : évite un saut au premier tick.
            S.behindAngle = nil
            S.behindDir = nil
        end
    end,
})

FarmSection:AddDropdown({
    Title = "Movement",
    Values = { "Smooth (fluid)", "Teleport" },
    Default = "Smooth (fluid)",
    Search = false,
    Flag = "follow_mode",
    Callback = function(value)
        if string.lower(tostring(value)):find("teleport") then
            S.followMode = "teleport"
        else
            S.followMode = "smooth"
        end
        S.target = nil
    end,
})

FarmSection:AddTextbox({
    Title = "Follow speed",
    Description = "1 = normal, 2 = faster catch-up",
    Default = "1",
    Numeric = true,
    Finished = true,
    Flag = "follow_speed",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 0.2 and v <= 4 then S.followSpeed = v end
    end,
})

farmToggles.aim = FarmSection:AddToggle({
    Title = "Auto aim",
    Default = false,
    Flag = "auto_aim",
    Callback = function(on) S.autoAim = on and true or false end,
})

farmToggles.fire = FarmSection:AddToggle({
    Title = "Auto fire",
    Default = false,
    Flag = "auto_fire",
    Callback = function(on) S.autoFire = on and true or false end,
})

farmToggles.teleport = FarmSection:AddToggle({
    Title = "Teleport fallback",
    Description = "Allows a hard teleport if the tripod is very far or behind cover",
    Default = false,
    Flag = "use_teleport",
    Callback = function(on) S.useTeleport = on and true or false end,
})

FarmSection:AddToggle({
    Title = "Retreat on low HP",
    Description = "Flies up when your health is low",
    Default = false,
    Flag = "retreat_low_hp",
    Callback = function(on) S.retreat = on and true or false end,
})

FarmSection:AddTextbox({
    Title = "Retreat HP",
    Default = "40",
    Numeric = true,
    Finished = true,
    Flag = "retreat_hp",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 10 and v <= 150 then S.retreatHP = v end
    end,
})

FarmSection:AddButton({
    Title = "Teleport to nearest tripod",
    Callback = function()
        local t = pickTarget()
        if t then
            teleportNear(t)
            setStatus("Teleported to " .. t.class .. ".")
        else
            setStatus("No tripod found.")
        end
    end,
})

--=====================================================================
-- 11b. GUN MODS
--=====================================================================
local GunSection = GunTab:AddSection({ Title = "Weapon Mods", Icon = "rocket" })

farmToggles.infAmmo = GunSection:AddToggle({
    Title = "Never run dry",
    Description = "Reloads automatically when the magazine is almost empty (server-safe)",
    Default = false,
    Flag = "inf_ammo",
    Callback = function(on) S.infAmmo = on and true or false; applyGunMods() end,
})

farmToggles.fastFire = GunSection:AddToggle({
    Title = "Remove recovery delay",
    Description = "Fires at the weapon's real max rate. Going faster gets your shots rejected",
    Default = false,
    Flag = "fast_fire",
    Callback = function(on) S.fastFire = on and true or false; applyGunMods() end,
})

GunSection:AddParagraph({
    Title = "Fire rate warning",
    Content = "The server only accepts the weapon's real fire rate. A client-side faster rate is silently rejected: no damage, no EXP. Keep this off if EXP matters to you.",
})

farmToggles.fastReload = GunSection:AddToggle({
    Title = "Fast Reload",
    Description = "Client-side reload speed. The server may still be reloading: keep off if EXP matters",
    Default = false,
    Flag = "fast_reload",
    Callback = function(on) S.fastReload = on and true or false; applyGunMods() end,
})

GunSection:AddToggle({
    Title = "No Recoil",
    Default = false,
    Flag = "no_recoil",
    Callback = function(on) S.noRecoil = on and true or false; applyGunMods() end,
})

GunSection:AddToggle({
    Title = "No Spread",
    Default = false,
    Flag = "no_spread",
    Callback = function(on) S.noSpread = on and true or false; applyGunMods() end,
})

farmToggles.autoReload = GunSection:AddToggle({
    Title = "Auto Reload",
    Default = false,
    Flag = "auto_reload",
    Callback = function(on) S.autoReload = on and true or false end,
})

GunSection:AddButton({
    Title = "Apply mods now",
    Callback = function() applyGunMods(); tickGun(); setStatus("Gun mods applied.") end,
})

GunSection:AddButton({
    Title = "Restore gun stats",
    Callback = function() restoreGunMods() end,
})

GunSection:AddParagraph({
    Title = "Note",
    Content = "Damage, ammo and EXP are calculated by the server. Recoil, spread and reload speed are client-side. Never force the magazine size or fire faster than the real weapon: the server rejects those shots and you earn nothing.",
})

--=====================================================================
-- 11c. ESP
--=====================================================================
local EspSection = EspTab:AddSection({ Title = "ESP", Icon = "eye" })

EspSection:AddToggle({
    Title = "Tripods ESP",
    Description = "Highlight tripods with shield / HP / distance",
    Default = false,
    Flag = "esp_tripods",
    Callback = function(on)
        S.espTripods = on and true or false
        if not on and not S.espPlayers then clearEsp() end
    end,
})

EspSection:AddToggle({
    Title = "Show shield / health",
    Default = false,
    Flag = "esp_show_stats",
    Callback = function(on) S.espShowStats = on and true or false end,
})

EspSection:AddToggle({
    Title = "Players ESP",
    Default = false,
    Flag = "esp_players",
    Callback = function(on)
        S.espPlayers = on and true or false
        if not on and not S.espTripods then clearEsp() end
    end,
})

EspSection:AddTextbox({
    Title = "Max ESP distance (studs)",
    Default = "6000",
    Numeric = true,
    Finished = true,
    Flag = "esp_max_dist",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 50 then S.espMaxDist = v end
    end,
})

local ColorSection = EspTab:AddSection({ Title = "ESP Colors", Icon = "palette", Collapsible = true })

local function addColorPicker(title, key, default)
    local ok, err = pcall(function()
        ColorSection:AddColorPicker({
            Title = title,
            Default = default,
            Flag = "esp_color_" .. key,
            Callback = function(color)
                if typeof(color) == "Color3" then COLORS[key] = color end
            end,
        })
    end)
    if ok then return end
    print("[WotW] color picker " .. key .. " indisponible (" .. tostring(err) .. "), fallback hex")
    ColorSection:AddTextbox({
        Title = title .. " (#RRGGBB)",
        Default = string.format("#%02X%02X%02X", math.floor(default.R * 255), math.floor(default.G * 255), math.floor(default.B * 255)),
        Finished = true,
        Flag = "esp_color_" .. key,
        Callback = function(text)
            local hex = tostring(text):gsub("#", "")
            if #hex == 6 then
                local r = tonumber(hex:sub(1, 2), 16)
                local g = tonumber(hex:sub(3, 4), 16)
                local b = tonumber(hex:sub(5, 6), 16)
                if r and g and b then COLORS[key] = Color3.fromRGB(r, g, b) end
            end
        end,
    })
end

addColorPicker("Tripod", "tripod", COLORS.tripod)
addColorPicker("Uberpod", "uberpod", COLORS.uberpod)
addColorPicker("Players", "player", COLORS.player)

--=====================================================================
-- 11d. PLAYER — VITESSE, VIE, SURVIE
--=====================================================================
local PlayerSection = PlayerTab:AddSection({ Title = "Speed & Health", Icon = "user" })

PlayerSection:AddToggle({
    Title = "Speed boost",
    Description = "Sets your walk speed every 0.2 s",
    Default = false,
    Flag = "speed_boost",
    Callback = function(on)
        S.speedHack = on and true or false
        local hum = getHum()
        if not S.speedHack and hum then
            safe(function() hum.WalkSpeed = 8 end)
        end
    end,
})

PlayerSection:AddTextbox({
    Title = "Walk speed",
    Description = "Default game speed is 8 (sprint 10)",
    Default = "8",
    Numeric = true,
    Finished = true,
    Flag = "walk_speed",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 8 and v <= 500 then
            S.walkSpeed = v
            local hum = getHum()
            if S.speedHack and hum then safe(function() hum.WalkSpeed = v end) end
        end
    end,
})

PlayerSection:AddToggle({
    Title = "Jump boost",
    Description = "Sets your jump power every 0.2 s",
    Default = false,
    Flag = "jump_boost",
    Callback = function(on)
        S.jumpBoost = on and true or false
        local hum = getHum()
        if not hum then return end
        if S.jumpBoost then
            S.origJump = S.origJump or {
                use    = hum.UseJumpPower,
                power  = hum.JumpPower,
                height = hum.JumpHeight,
            }
            safe(function()
                hum.UseJumpPower = true
                hum.JumpPower = math.clamp(tonumber(S.jumpPower) or 100, 50, 1000)
            end)
        else
            local o = S.origJump
            safe(function()
                if o then
                    hum.UseJumpPower = o.use
                    hum.JumpPower = o.power
                    hum.JumpHeight = o.height
                else
                    hum.UseJumpPower = false
                    hum.JumpHeight = 7.2
                end
            end)
            S.origJump = nil
        end
    end,
})

PlayerSection:AddTextbox({
    Title = "Jump power",
    Description = "Default is 50 (the game uses jump height 7.2)",
    Default = "100",
    Numeric = true,
    Finished = true,
    Flag = "jump_power",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 50 and v <= 1000 then
            S.jumpPower = v
            local hum = getHum()
            if S.jumpBoost and hum then
                safe(function()
                    hum.UseJumpPower = true
                    hum.JumpPower = v
                end)
            end
        end
    end,
})

PlayerSection:AddToggle({
    Title = "God mode (client)",
    Description = "Keeps your health at the chosen value. Server damage may still kill you",
    Default = false,
    Flag = "god_mode",
    Callback = function(on)
        S.godMode = on and true or false
        local hum = getHum()
        if hum then
            if S.godMode then
                S.origMaxHealth = hum.MaxHealth
            else
                safe(function()
                    if S.origMaxHealth then hum.MaxHealth = S.origMaxHealth end
                    if hum.Health > hum.MaxHealth then hum.Health = hum.MaxHealth end
                    hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
                end)
            end
        end
    end,
})

PlayerSection:AddTextbox({
    Title = "God mode health",
    Description = "Health value used by God mode",
    Default = "5000",
    Numeric = true,
    Finished = true,
    Flag = "god_health",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 100 and v <= 1000000 then S.godHealth = v end
    end,
})

local SurvivalSection = PlayerTab:AddSection({ Title = "Survival (stamina, food, water)", Icon = "heart" })

SurvivalSection:AddToggle({
    Title = "Infinite stamina",
    Description = "Keeps the stamina bar full so you can sprint forever",
    Default = false,
    Flag = "inf_stamina",
    Callback = function(on) S.infStamina = on and true or false end,
})

SurvivalSection:AddToggle({
    Title = "No starvation damage",
    Description = "Heals you when hunger or thirst gets low",
    Default = false,
    Flag = "no_starve",
    Callback = function(on) S.noStarve = on and true or false end,
})

SurvivalSection:AddToggle({
    Title = "Auto eat / drink",
    Description = "Uses food and water tools already in your backpack when needed",
    Default = false,
    Flag = "auto_eat",
    Callback = function(on) S.autoEat = on and true or false end,
})

SurvivalSection:AddParagraph({
    Title = "Note",
    Content = "Hunger and thirst are drained by the server. The script reads the values, keeps your stamina full and prevents starvation death. Auto eat/drink only works with real food items in your backpack.",
})

--=====================================================================
-- 11d. PROGRESSION — LECTURE DE L'EXP
--=====================================================================
local ProgressionSection = PlayerTab:AddSection({ Title = "Progression", Icon = "bar-chart-3" })

ProgressionSection:AddParagraph({
    Title = "Note",
    Content = "EXP is granted by the server. This section only reads your counters: the game keeps one counter per team (Military, Survivor, Tripod).",
})

local progPara = ProgressionSection:AddParagraph({
    Title = "My EXP",
    Content = "Click the button below.",
})

local function showProgression()
    local team = currentTeam()
    local lines = {}
    for _, name in ipairs({ "Military", "Survivor", "Tripod" }) do
        local exp = teamExpValue(name)
        local lvl = teamLevelValue(name)
        local rank = ""
        if TeamLevelData and TeamLevelData.GetRank then
            local ok, r = pcall(TeamLevelData.GetRank, name, lvl)
            if ok and type(r) == "string" and r ~= "" then rank = " " .. r end
        end
        local mark = (name == team) and "  <-- you" or ""
        lines[#lines + 1] = string.format("%s: %d EXP | Lv %d%s%s", name, exp, lvl, rank, mark)
    end
    local text = table.concat(lines, "\n")
    safe(function()
        if progPara and progPara.Set then
            -- NextUI : Set(titre, corps). On ne remplace que le corps.
            progPara:Set(nil, text)
        elseif progPara then
            progPara.Text = "My EXP\n" .. text
        end
    end)
    return text
end

ProgressionSection:AddButton({
    Title = "Show my EXP",
    Callback = showProgression,
})

--=====================================================================
-- 11e. WEAPONS — TEST DE DÉBLOCAGE
--=====================================================================
local gunNames = {}
local vmSet = nil
local vmFolder = childOf(Rep, "Assets", "Viewmodels")
if vmFolder then
    vmSet = {}
    for _, c in ipairs(vmFolder:GetChildren()) do
        vmSet[c.Name] = true
    end
end
if type(GunData) == "table" then
    for name, data in pairs(GunData) do
        if type(data) == "table" and type(data.Cooldown) == "number" then
            -- On ne garde que les armes à pied qui ont un viewmodel.
            if not vmSet or vmSet[name] then
                gunNames[#gunNames + 1] = name
            end
        end
    end
end
table.sort(gunNames)

local function createGunTool(name)
    local tool = Instance.new("Tool")
    tool.Name = name
    tool.CanBeDropped = false
    tool:SetAttribute("Gun", true)
    tool:SetAttribute("Ammo", 999)
    tool:SetAttribute("Cooldown", false)
    tool:SetAttribute("Reloading", false)

    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Transparency = 1
    handle.CanCollide = false
    handle.Massless = true
    handle.Size = Vector3.new(0.2, 0.2, 0.2)
    handle.Parent = tool

    return tool
end

local function tryEquipWeapon(name)
    local ch = LP.Character
    if not ch then return false, "No character." end

    if S.testWeapon and S.testWeapon.Parent then
        safe(function() S.testWeapon:Destroy() end)
    end

    -- On fabrique l'outil nous-mêmes : plus besoin d'avoir déjà une arme.
    local tool = createGunTool(name)
    tool.Parent = ch

    local function doEquip()
        if GunController and GunController.Equip then
            pcall(GunController.Equip, tool)
        end
        task.wait(0.5)
        return GunController and GunController.current and GunController.current.Gun == tool
    end

    task.wait(0.25)
    local ok = doEquip()
    if not ok then
        -- Parfois l'équipement précédent n'a pas fini : on réessaie.
        task.wait(0.5)
        ok = doEquip()
    end

    if ok then
        S.testWeapon = tool
        return true, "Equipped " .. name .. " (client test)"
    end

    if tool.Parent then safe(function() tool:Destroy() end) end
    return false, "Cannot equip " .. name .. " (no viewmodel / not allowed)"
end

local WeaponSection = WeaponTab:AddSection({ Title = "Weapon Unlock (client test)", Icon = "crosshair" })

local weaponChoice = "M14"
if #gunNames > 0 then
    weaponChoice = gunNames[1]
    for _, n in ipairs(gunNames) do
        if n == "M14" then weaponChoice = "M14" break end
    end
end

if #gunNames > 0 then
    WeaponSection:AddDropdown({
        Title = "Weapon",
        Values = gunNames,
        Default = weaponChoice,
        Search = true,
        Flag = "weapon_choice",
        Callback = function(value) weaponChoice = tostring(value) end,
    })
else
    WeaponSection:AddParagraph({
        Title = "Weapons",
        Content = "GunData not found. Weapon list unavailable.",
    })
end

WeaponSection:AddButton({
    Title = "Try equip selected weapon",
    Callback = function()
        local ok, msg = tryEquipWeapon(weaponChoice)
        setStatus(msg)
        if ok then applyGunMods() end
    end,
})

if #gunNames > 0 then
    WeaponSection:AddParagraph({
        Title = "Available models",
        Content = table.concat(gunNames, ", "),
    })
end

WeaponSection:AddButton({
    Title = "Restore my normal gun",
    Callback = function()
        if S.testWeapon and S.testWeapon.Parent then
            safe(function() S.testWeapon:Destroy() end)
        end
        local saved = tostring(LP:GetAttribute("SavedLoadout_Primary") or "M14")
        local ch = LP.Character
        local tool = nil
        local bp = LP:FindFirstChildOfClass("Backpack")
        for _, src in ipairs({ ch, bp }) do
            if src then
                for _, t in ipairs(src:GetChildren()) do
                    if t:IsA("Tool") and t.Name == saved then tool = t end
                end
            end
        end
        if tool and ch then
            tool.Parent = ch
            task.wait(0.2)
            if GunController and GunController.Equip then pcall(GunController.Equip, tool) end
            setStatus("Restored " .. saved)
        elseif ch then
            -- L'arme d'origine n'est pas dans le sac : on la recrée.
            local recreated = createGunTool(saved)
            recreated.Parent = ch
            task.wait(0.2)
            if GunController and GunController.Equip then pcall(GunController.Equip, recreated) end
            task.wait(0.4)
            if GunController and GunController.current and GunController.current.Gun == recreated then
                S.testWeapon = recreated
                setStatus("Recreated " .. saved)
            else
                if recreated.Parent then safe(function() recreated:Destroy() end) end
                setStatus("Original gun not found (" .. saved .. ")")
            end
        else
            setStatus("No character.")
        end
    end,
})

WeaponSection:AddParagraph({
    Title = "Important",
    Content = "The game gives weapons server-side. This button creates the selected weapon locally and equips it so you can test its model and stats. Damage may still be refused by the server if you do not own the weapon.",
})

WeaponSection:AddParagraph({
    Title = "EXP warning",
    Content = "A locally created weapon does damage but earns 0 EXP: the server only rewards hits from weapons you really own. To gain EXP, use a real gun from your loadout (the status bar shows TEST GUN when the local one is active).",
})

WeaponSection:AddParagraph({
    Title = "No EXP at all?",
    Content = "If the counter stops moving completely, the server may have stopped crediting you for this session (it happens after firing faster than the weapon allows). Try leaving and rejoining the game, then keep the fire-rate options off.",
})

--=====================================================================
-- 11f. SETTINGS
--=====================================================================
local InterfaceSection = SetTab:AddSection({ Title = "Interface (PC / Mobile)", Icon = "settings" })

InterfaceSection:AddKeybind({
    Title = "Menu toggle key (PC)",
    Description = "Press the button, then press the key you want",
    Default = S.keybind,
    MenuKey = NextUI ~= nil,
    Flag = "menu_key",
    ChangedCallback = function(key)
        if key then
            S.keybind = key
            if NextUI then safe(function() NextUI:SetMenuKey(key) end) end
        elseif NextUI then
            safe(function() NextUI:SetMenuKey(S.keybind) end)
        end
    end,
})

InterfaceSection:AddDropdown({
    Title = "Mobile button position",
    Values = { "Right", "Right bottom", "Left bottom", "Left", "Top right", "Hidden" },
    Default = "Right",
    Search = false,
    Flag = "mobile_btn_pos",
    Callback = function(value)
        local v = string.lower(tostring(value))
        if v == "right" then S.mobileButtonPos = "right"
        elseif v == "right bottom" then S.mobileButtonPos = "right-bottom"
        elseif v == "left bottom" then S.mobileButtonPos = "left-bottom"
        elseif v == "left" then S.mobileButtonPos = "left"
        elseif v == "top right" then S.mobileButtonPos = "top-right"
        elseif v == "hidden" then S.mobileButtonPos = "hidden" end
        applyMobileButton()
    end,
})

InterfaceSection:AddTextbox({
    Title = "Mobile button size (px)",
    Default = tostring(S.mobileButtonSize),
    Numeric = true,
    Finished = true,
    Flag = "mobile_btn_size",
    Callback = function(text)
        local v = tonumber(text)
        if v and v >= 32 and v <= 96 then
            S.mobileButtonSize = v
            applyMobileButton()
        end
    end,
})

local PerfSection = SetTab:AddSection({ Title = "Performance & Compatibility", Icon = "cpu" })

PerfSection:AddToggle({
    Title = "Low-end / Mobile mode",
    Description = "Slower loops, fewer ESP objects, less CPU",
    Default = LOW_END,
    Flag = "low_end",
    Callback = function(on) S.lowEnd = on and true or false end,
})

PerfSection:AddToggle({
    Title = "Glass effect",
    Description = "Frosted glass + blur on the UI (turn off if it lags)",
    Default = true,
    Flag = "glass_fx",
    Callback = function(on)
        S.glass = on and true or false
        if NextUI then safe(function() NextUI:SetGlass(S.glass) end) end
    end,
})

PerfSection:AddButton({
    Title = "Restore Roblox UI (chat / Esc)",
    Callback = function()
        restoreRobloxUI()
        safe(fixNextUI)
        local box = safe(function() return UserInputService:GetFocusedTextBox() end)
        if box then safe(function() box:ReleaseFocus() end) end
    end,
})

PerfSection:AddButton({
    Title = "Bring UI to front",
    Callback = function()
        for _, g in ipairs(ownedGuis) do
            if g ~= espGui then
                safe(function() g.DisplayOrder = 2147483000 end)
            end
        end
    end,
})

PerfSection:AddButton({
    Title = "Unload script",
    Callback = function() _G.WotW.Unload() end,
})

--=====================================================================
-- 12. BOUTON MOBILE + TOUCHE
--=====================================================================
if NextUI then
    safe(function() NextUI:SetMenuKey(S.keybind) end)
end

applyMobileButton()
task.delay(1.0, function() safe(applyMobileButton) end)

local keyConn = nil
if not NextUI then
    keyConn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == S.keybind and Window.Toggle then
            safe(function() Window:Toggle() end)
        end
    end)
end

--=====================================================================
-- 13. RESPAWN
--=====================================================================
local charConn = LP.CharacterAdded:Connect(function()
    S.target = nil
    S.lastTeleport = 0
    S.nextFire = 0
    S.safePos = nil
    camState = nil
    task.wait(1.2)
    if S.autoFarm then
        local hrp = getHRP()
        S.safePos = hrp and hrp.Position or nil
        setCameraScriptable(true)
    end
    applyGunMods()
end)

--=====================================================================
-- 14. API + UNLOAD
--=====================================================================
local function unload()
    if not S.running then return end
    S.running = false
    S.autoFarm = false

    safe(function() if keyConn then keyConn:Disconnect() end end)
    safe(function() if charConn then charConn:Disconnect() end end)
    safe(function() if escConn then escConn:Disconnect() end end)

    setCameraScriptable(false)
    restoreGunMods()
    clearEsp()
    restoreRobloxUI()

    -- Restaure la vitesse / les PV d'origine.
    local hum = getHum()
    if hum then
        safe(function() hum.WalkSpeed = 8 end)
        safe(function()
            if S.origMaxHealth then hum.MaxHealth = S.origMaxHealth end
            if hum.Health > hum.MaxHealth then hum.Health = hum.MaxHealth end
        end)
        safe(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
    end
    if S.testWeapon and S.testWeapon.Parent then
        safe(function() S.testWeapon:Destroy() end)
    end

    for i = #ownedGuis, 1, -1 do
        local g = ownedGuis[i]
        safe(function() if g then g:Destroy() end end)
        ownedGuis[i] = nil
    end
    _G.WotW = nil
end

_G.WotW = {
    State = S,
    Unload = unload,
    Toggle = function()
        if Window and Window.Toggle then safe(function() Window:Toggle() end) end
    end,
    Farm = function(on)
        S.autoFarm = on and true or false
        S.target = nil
        S.lastTeleport = 0
        S.expTeam = nil
        S.expBase = nil
        if S.autoFarm then
            armFarmKit()
            local hrp = getHRP()
            S.safePos = hrp and hrp.Position or nil
            setCameraScriptable(true)
        else
            setCameraScriptable(false)
        end
    end,
    Gun = { apply = applyGunMods, restore = restoreGunMods },
    Weapon = { equip = tryEquipWeapon },
    Progression = {
        show = showProgression,
        team = currentTeam,
        exp = teamExpValue,
        level = teamLevelValue,
    },
    ESP = { tick = espTick, clear = clearEsp },
    Move = function(t, dt)
        local hrp = getHRP()
        if hrp and t then moveSmooth(t, hrp, dt or 0.02) end
    end,
    Survival = SurvivalShared,
    FarmToggles = farmToggles,
    NextUI = NextUI,
}

applyGunMods()

print("[WotW] v1.0 chargé — mode " .. (S.lowEnd and "low-end/mobile" or "PC") .. " — NextUI " .. (NextUI and "OK" or "fallback"))
