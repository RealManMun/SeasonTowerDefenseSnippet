-- Server handler for enemies, will not display more than this for the enemy system - to make it impossible to replicate unless you'd rewrite your own system. Feel free to learn from this code tho.

-- @RealManMun 27th August 2025

local Enemy = {}
Enemy.Priority = 2
Enemy.FarthestEnemy = nil
Enemy.FinalBossName = "IceboundKrampus"
Enemy.MarkedBosses = {}

--// Types
type EnemyData = {
	Name: string,
	UniqueId: string,
	Speed: number,
	OriginalSpeed: number,
	Health: number,
	CurrentWaypoint: Instance,
	SpawnTime: number,
	ParentSpawnTime: number | nil,

	FixedElapsed: number,
	ElapsedDelay: number,

	Distance: number, -- distance travelled along path
	ExtraDistance: number,
	Position: Vector3,
	Orientation: Vector3, -- yaw in degrees
	PathIndex: number,

	summonTime: number | nil,
	summonDelayTime: number | nil,
	summonAnimationLength: number | nil,
	enemyToSummon: string | { string } | nil,
	previousSummonTime: number | nil,

	fat: number,
	enemyStats: {any},
	enemyValues: {string},
	died: boolean,
	
	Attacks: { [number]: { string | number | {number} } } | nil,
	activeAttacks: { { string | number | {number} } } | nil,
	currentAttack: { string | number | {number} },
	lastAttackTime: number | nil,
	Phase: number | nil,
	CashPerHit: number,
	GodMode: boolean,

	state: string?
}
type EnemyPool = { [string]: EnemyData }

--// Variables
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage") 
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage:WaitForChild("Packet"))
local PathModule = require(ReplicatedStorage:WaitForChild("PathModule"))
local NetworkUtilityModule = require(ReplicatedStorage:WaitForChild("NetworkUtility"))

local ReplicateEnemyEvent = Packet("ReplicateEnemy", Packet.NumberU8, Packet.NumberU16 , Packet.NumberU16)
local SummonEnemyEvent = Packet("SummonEnemyEvent", Packet.NumberU8, Packet.NumberU16, Packet.NumberU16, Packet.NumberF32, Packet.NumberU32)

local SummonerEnemyEvent = Packet("SummonerEnemyEvent", Packet.NumberU8, Packet.NumberU16, Packet.NumberU16)
local RemoveEnemyEvent = Packet("RemoveEnemy", Packet.NumberU16)
local UpdateEnemyHealthEvent = Packet("UpdateEnemyHealth", Packet.NumberU16, Packet.NumberU32)
local FreezeEnemyEvent = Packet("FreezeEnemyEvent", Packet.NumberU16, Packet.NumberU16)
local UnfreezeEnemyEvent = Packet("UnfreezeEnemyEvent", Packet.NumberU16, Packet.NumberU16)
local UpdateBaseHPEvent = Packet("UpdateBaseHP", Packet.NumberU8)
local EnemyAttackEvent = Packet("EnemyAttack", Packet.NumberU16, Packet.NumberU8)
local TrackEnemyHealthbarEvent = Packet("TrackEnemyHealthbar", Packet.NumberU16)
local NewPhaseEvent = Packet("NewPhase", Packet.NumberU16, Packet.NumberU8)
local SyncToServerTimeEvent = Packet("SyncToServerTimeEvent", Packet.NumberU16)
local GameEndPacket = Packet("GameEnd", Packet.NumberU8)
local PlayMusicPacket = Packet("PlayMusic", Packet.NumberU8)
local StopMusicPacket = Packet("StopMusic", Packet.NumberU8)
local PlaySoundPacket = Packet("PlaySound", Packet.NumberU8)
local KrampusMessagePacket = Packet("KrampusMessage", Packet.NumberU8)

local Assets = ReplicatedStorage:WaitForChild("Assets")
local EnemyModels = Assets:WaitForChild("EnemyModels")
local waypointsFolder = workspace:WaitForChild("Waypoints")

local BaseModule: ModuleScript = nil

local Data = ReplicatedStorage:WaitForChild("Data")
local PlaceIds = require(Data:WaitForChild("PlaceIds"))
local EnemyStatsData = require(Data:WaitForChild("EnemyStats"))

local GAMESTARTED = ServerStorage:WaitForChild("GAMESTARTED")
local GAME = ServerStorage:WaitForChild("GAME")

local BaseHP = ServerStorage:WaitForChild("BaseHP")

local mapWaypoints: { [number]: Instance } = {}
local freezeTimes: { [string]: number } = {}
local enemyPool: EnemyPool = {}
local uniqueIdCounter = 0
local enemyPoolCount = 0

local healthbarEnemies = {
	["FrostShade"] = false,
	["FrostReaver"] = false,
	["FrostSpirit"] = false,
	["RoboSanta"] = false,
	["IceboundKrampus"] = false,
}

local HEALTH_SCALE = 0.35
local HEALTH_SCALE_TARGETS = {"RoboSanta", "FrostVanguard", "IceboundKrampus", "FrostSpirit", "FrostNecromancer", "FrostbiteRevenant", "CryingSpirit"}

local wTowers = workspace:WaitForChild("Towers")

--// Load map waypoints & precompute
for _, child in waypointsFolder:GetChildren() do
	local i = tonumber(child.Name)
	if i then mapWaypoints[i] = child end
end
PathModule.precomputePath(1, mapWaypoints) -- 1 path for now


--// Utilities
local function fireAllClients(packet: Packet.Packet, ...)
	for _, player in Players:GetPlayers() do
		packet:FireClient(player, ...)
	end
end

local function _len(dictionary: { [any]: any }): number
	local c = 0
	for _, __ in dictionary do
		c += 1
	end
	return c
end

local function getTowersInRange(position: Vector3, range: number): { Model }
	local towersInRange = {}
	
	for _, tower: Model in wTowers:GetChildren() do
		local offset = tower.Position - position
		local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude
		if dist <= range then
			table.insert(towersInRange, tower)
		end
	end
	
	return towersInRange
end

local function getScaledHealth(baseHealth: number): number
	local playerCount = #Players:GetPlayers()
	if playerCount <= 1 then
		return baseHealth
	end
	return math.floor(
		baseHealth * (1 + HEALTH_SCALE * (playerCount - 1))
	)
end

local function spawnEnemy(name: string, isSummoned: boolean, params: { Vector3 | Instance | number })
	local id = uniqueIdCounter
	local uniqueId = name .. "_" .. id
	uniqueIdCounter += 1

	local stats = EnemyStatsData[name]
	params = params or {}
	
	if stats and stats.SoundData and stats.SoundData.SpawnLineID then
		fireAllClients(PlaySoundPacket, stats.SoundData.SpawnLineID)
	end

	local summonData = stats.summonData or {}
	local fakeModel = EnemyModels[name]
	local settingsFolder = fakeModel.Settings

	local now = workspace:GetServerTimeNow()
	local enemy: EnemyData = {
		Name = name,
		UniqueId = uniqueId,
		NumId = id,
		Speed = stats.WalkSpeed,
		OriginalSpeed = stats.WalkSpeed,
		Health = stats.Health,
		CurrentWaypoint = params[3] or nil,
		SpawnTime = now,

		FixedElapsed = nil,
		ElapsedDelay = 0,

		Distance = 0,
		ExtraDistance = params[4] or 0,
		Position =  params[1] or Vector3.zero,
		Orientation = params[2] or Vector3.zero,
		PathIndex = 1,

		summonTime = summonData[1] or nil,
		summonDelayTime = summonData[2] or nil,
		summonAnimationLength = summonData[3] or nil,
		enemyToSummon = summonData[4] or nil,
		isSummonRandom = summonData[5] or nil,
		previousSummonTime = now,

		fat = 0,
		enemyStats = stats,
		enemyValues = {},
		died = false,
		state = nil,
		Attacks = {},
		activeAttacks = nil,
		lastAttackTime = nil,
		Phase = nil,
		CashPerHit = stats.CashPerHit,
		GodMode = false,
		
		--[[
		PART = (function()
			local part = Instance.new("Part")
			part.Name = uniqueId
			part.Anchored = true
			part.CanCollide = false
			part.CastShadow = false
			part.Transparency = .5
			part.Color = Color3.fromRGB(255, 0, 0)
			part.Size = Vector3.new(2,2,2)
			part.Parent = workspace
			return part
		end)()
		--]]
	}
	
	enemy.Health = getScaledHealth(enemy.Health)

	for _, settingValue in settingsFolder:GetChildren() do
		table.insert(enemy.enemyValues, settingValue.Name)
	end
	settingsFolder = nil
	
	if stats.attacksData then
		enemy.activeAttacks = {}
		enemy.lastAttackTime = now
		for attackId: number, data: {any} in stats.attacksData do
			local currentAttackTable = { 
				lastAttackTime = now, 
				range = data.attackRange, 
				duration = data.attackDuration, 
				animationEventLength = data.animationEventLength, 
				attackFrequency = data.attackFrequency, 
				freezeEnemyForSeconds = data.freezeEnemyForSeconds, 
				actualFrequency = nil,
				phase = data.phase,
				attackId = attackId,
			}
			
			enemy.Attacks[attackId] = currentAttackTable
			if not data.phase then
				table.insert(enemy.activeAttacks, currentAttackTable)
			end
		end
		
		enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]
	end
	
	if stats.PhaseTwoData then
		enemy.Phase = 1
	end
	
	if _len(enemy.Attacks) == 0 then enemy.Attacks = nil end

	enemyPool[uniqueId] = enemy
	enemyPoolCount += 1

	local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(enemy.SpawnTime)

	if isSummoned then

		local elapsed = now - enemy.SpawnTime
		local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

		fireAllClients(SummonEnemyEvent, stats.EnemyIndex, id, encrypted, distanceTravelled, enemy.Health)
	else
		fireAllClients(ReplicateEnemyEvent, stats.EnemyIndex, encrypted, id)
	end
	
	if healthbarEnemies[name] == false then
		healthbarEnemies[name] = true
		if stats.SoundData then
			fireAllClients(PlayMusicPacket, stats.SoundData.ThemeSongID)
		end
		
		if name == Enemy.FinalBossName then
			print("Krampus spawn detected, playing voice lines!")
			task.spawn(function()
				fireAllClients(KrampusMessagePacket, 1)
				task.wait(13)
				fireAllClients(KrampusMessagePacket, 2)
				task.wait(10)
				fireAllClients(KrampusMessagePacket, 3)
			end)
		end
		
		fireAllClients(TrackEnemyHealthbarEvent, id)
		enemy.SOUND_MARKED = true
	end
	
	Enemy.UpdateHP(uniqueId, enemy.Health)
end

local function summonEnemy(name: string, amount: number, ...): ()
	for i = 1, amount do
		local args = {...}
		args[5] += (0.3*(i - 1))
		spawnEnemy(name, true, args)
		task.wait(.3)
	end
end

function Enemy.new(name: string, amount: number, delayTime: number): EnemyData
	for i = 1, amount do
		spawnEnemy(name)
		task.wait(delayTime)
	end
end

function Enemy.GetActiveEnemies(): EnemyPool
	return enemyPool
end

local function beginFreeze(enemy, now, elapsed): number
	enemy.FixedElapsed = elapsed - enemy.ElapsedDelay
	return NetworkUtilityModule:EncryptNetworkServerTime(now)
end

local function endFreeze(enemy, now): ()
	enemy.ElapsedDelay += workspace:GetServerTimeNow() - now
	enemy.FixedElapsed = nil
end

local function unfreezeEnemy(enemy: EnemyData, now: number): ()
	if (enemy.FixedElapsed and freezeTimes[enemy.UniqueId]) then
		local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
		fireAllClients(UnfreezeEnemyEvent, enemy.NumId, encrypted)
		enemy.ElapsedDelay += workspace:GetServerTimeNow() - freezeTimes[enemy.UniqueId]
		enemy.FixedElapsed = nil
		freezeTimes[enemy.UniqueId] = nil
	end
end

function Enemy.Stop(now: number, elapsed: number, id: string, givenDuration: number)
	local enemy = enemyPool[id]
	beginFreeze(enemy, now, elapsed)

	task.wait(givenDuration)

	endFreeze(enemy, now)
end

function Enemy.SummonerStop(now: number, elapsed: number, id: string)
	local enemy = enemyPool[id]
	local encrypted = beginFreeze(enemy, now, elapsed)

	fireAllClients(SummonerEnemyEvent, enemy.enemyStats.EnemyIndex, encrypted, tonumber(id:split("_")[2]))

	task.wait(enemy.summonDelayTime)

	local enemyToSummon = enemy.enemyToSummon
	if typeof(enemyToSummon) == "string" then
		task.spawn(summonEnemy, enemyToSummon, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
	elseif typeof(enemyToSummon) == "table" then
		if enemy.isSummonRandom then
			local chosen = enemyToSummon[math.random(1, #enemyToSummon)]
			task.spawn(summonEnemy, chosen, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
		else
			for _, enemyName in enemyToSummon do
				task.spawn(summonEnemy, enemyName, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
			end
		end
	end

	task.wait(enemy.summonAnimationLength - enemy.summonDelayTime)

	endFreeze(enemy, now)
	enemy.state = nil
end

function Enemy.GetFarthestEnemy(): EnemyData
	return Enemy.FarthestEnemy
end

function Enemy.UpdateHP(uniqueId: string, newhp: number, arg: string | nil) -- HP TO CHECK
	local enemy = enemyPool[uniqueId]
	if not enemy then return end
	local phaseTwoData = enemy.enemyStats.PhaseTwoData

	newhp = math.floor(newhp)
	if newhp < 0 then newhp = 0 end
	local numId = tonumber(uniqueId:split("_")[2])

	if newhp <= 0 then
		if enemy.died then return end
		
		if enemy.Phase and enemy.Phase == 1 then
			local now = workspace:GetServerTimeNow()
			local elapsed = now - enemy.SpawnTime
			local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
			enemy.FixedElapsed = elapsed - enemy.ElapsedDelay

			enemy.state = "ActionState"
			freezeTimes[enemy.UniqueId] = now
			fireAllClients(NewPhaseEvent, numId, 2) -- automatically choose second phase (default)
			fireAllClients(FreezeEnemyEvent, numId, encrypted)
			
			local phaseTwoHealth = phaseTwoData.PhaseTwoHealth
			phaseTwoHealth = getScaledHealth(phaseTwoHealth)
			enemy.Health = phaseTwoHealth

			enemy.GodMode = true
			
			local stats = enemy.enemyStats
			if stats.SoundData and stats.SoundData.PhaseTransitionID then
				fireAllClients(PlaySoundPacket, stats.SoundData.PhaseTransitionID)
			end
			
			fireAllClients(UpdateEnemyHealthEvent, numId, phaseTwoHealth)
			
			enemy.Phase += 1
			enemy.lastAttackTime = now
			enemy.activeAttacks = {}
			for actualIndex, attack in enemy.Attacks do
				if attack.phase == enemy.Phase then
					table.insert(enemy.activeAttacks, enemy.Attacks[actualIndex])
				end
			end
			enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]

			task.delay(phaseTwoData.PhaseTwoTransitionDuration, function()
				if enemy then
					unfreezeEnemy(enemy, workspace:GetServerTimeNow())
					enemy.state = nil
					
					local extraValues = phaseTwoData.PhaseEnemyValues
					for _, value: string? in extraValues do
						if typeof(value) == "string" then
							table.insert(enemy.enemyValues, value)
						end
					end
					enemy.GodMode = false
				end
			end)

			enemy.Phase = 2
			return
		end

		local deathPosition, deathOrientation, deathCurrentWaypoint, deathDistanceReached = enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance

		enemy.Health = 0
		if enemy.SOUND_MARKED and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.ThemeSongID then
			fireAllClients(StopMusicPacket, enemy.enemyStats.SoundData.ThemeSongID)
		end
		enemy.died = true
		if arg ~= "autoclear" then
			if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.DeathSoundID then
				fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.DeathSoundID)
			end
		end
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)

		local stats = enemy.enemyStats
		if stats.summonType == "OnDeath" then
			local summonData = stats.summonData
			local summonedEntityName = summonData.summonedEntityName
			local summonedEntityAmount = summonData.summonedEntityAmount

			local toSummonEnemyName
			if type(summonedEntityName) == "table" then
				local chosen = math.random(1, #summonedEntityName)
				toSummonEnemyName = summonedEntityName[chosen]
			else
				toSummonEnemyName = summonedEntityName
			end

			local now = workspace:GetServerTimeNow()
			task.spawn(summonEnemy, toSummonEnemyName, summonedEntityAmount, deathPosition, deathOrientation, deathCurrentWaypoint, deathDistanceReached, enemy.SpawnTime, enemy.Speed)
		end
		fireAllClients(RemoveEnemyEvent, numId)
		enemyPool[uniqueId] = nil
		enemyPoolCount -= 1
	else
		enemy.Health = newhp
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)
	end
	
	if arg == "autoclear" then
		print("Autocleared.")
		--
	else
		if enemy.Health == 0 and enemy.Name == Enemy.FinalBossName then
			print("Game cleared succesfully!")
			fireAllClients(PlaySoundPacket, 2)
			task.wait(1)
			fireAllClients(KrampusMessagePacket, 4)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 5)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 6)
			task.wait(8)
			GAME.Value = false
			local awarded = {}
			for _, player: Player in Players:GetPlayers() do
				if not table.find(awarded, player) then
					table.insert(awarded, player)
					player:WaitForChild("Stats"):WaitForChild("Wins").Value += 1
				end
			end
			
			fireAllClients(GameEndPacket, 1)
			fireAllClients(PlayMusicPacket, 102)
			task.delay(60, function()
				print("Teleporting remaining players..")
				for _, player: Player in Players:GetPlayers() do
					TeleportService:Teleport(PlaceIds.Lobby, player)
				end
			end)
		end
	end
end

function Enemy.GetActiveEnemyCount(): number
	return enemyPoolCount
end

function Enemy.ClearAllEnemies(): ()
	for id, enemy in enemyPool do
		Enemy.UpdateHP(id, 0, "autoclear")
		enemyPool[id] = nil
	end
	enemyPoolCount = 0
end

function Enemy.Init(serverModules)
	print("SERVER Enemy system initialized")

	BaseModule = serverModules["Base"]
	task.wait(5)
	
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()
		
		accumulator += dt
		if accumulator >= 1/20 then
			accumulator = 0
			fireAllClients(SyncToServerTimeEvent,  NetworkUtilityModule:EncryptNetworkServerTime(now))		
		end
		
		local farthestDistance = 0
		local farthestEnemy = nil

		if enemyPoolCount == 0 then
			if Enemy.FarthestEnemy ~= nil then
				Enemy.FarthestEnemy = nil
			end
		end

		for id, enemy in enemyPool do
			if enemy.Health <= 0 then continue end

			local elapsed = now - enemy.SpawnTime
			local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

			enemy.Distance = distanceTravelled
			if distanceTravelled > farthestDistance then farthestDistance = distanceTravelled farthestEnemy = enemy end
			local path = PathModule.getPathByIndex(enemy.PathIndex)
			if path then
				if enemy.Distance >= path.totalLength then

					BaseModule.ServerUpdateHP(enemy.Health)
					Enemy.UpdateHP(enemy.UniqueId, 0, "autoclear")
					
					enemyPool[id] = nil

					--[[
					if enemy.PART then
						enemy.PART:Destroy()
					end
					--]]
					
					continue
				end
			end

			local pos, forward, waypoint = PathModule.getPathPositionFromDistance(enemy.PathIndex, enemy.Distance)
			if pos then
				enemy.Position = pos
				local yaw = math.deg(math.atan2(forward.X, forward.Z))
				enemy.Orientation = Vector3.new(0, yaw, 0)

				if enemy.CurrentWaypoint ~= waypoint then
					enemy.CurrentWaypoint = waypoint
				end

				--[[
				if enemy.PART then
					enemy.PART.Position = pos
					enemy.PART.Orientation = enemy.Orientation
				end
				--]]
				

				if enemy.summonTime and not (enemy.state == "ActionState") then
					local timeSinceSpawn = now - enemy.previousSummonTime
					if timeSinceSpawn >= enemy.summonTime then
						enemy.state = "ActionState"
						enemy.previousSummonTime = now
						if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.SummonLinesID then
							fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.SummonLinesID)
						end
						task.spawn(Enemy.SummonerStop, now, elapsed, id)
					end
				end
			end

			if farthestEnemy then
				Enemy.FarthestEnemy = farthestEnemy
			end
			
			local attacksData = enemy.Attacks
			if attacksData and enemy.currentAttack then
				if enemy.state == "ActionState" then continue end
				
				local data = enemy.currentAttack
				if not data.actualFrequency then
					data.actualFrequency = math.random(data.attackFrequency[1], data.attackFrequency[2])
				end
				
				if now - enemy.lastAttackTime >= data.actualFrequency then
					enemy.state = "ActionState"
					enemy.lastAttackTime = now
					local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
					enemy.FixedElapsed = elapsed - enemy.ElapsedDelay
					freezeTimes[enemy.UniqueId] = now
					fireAllClients(FreezeEnemyEvent, enemy.NumId, encrypted)

					local towersInRange = getTowersInRange(enemy.Position, data.range)
					if enemy and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.AttackLinesID then
						fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.AttackLinesID)
					end
					fireAllClients(EnemyAttackEvent, enemy.NumId, enemy.currentAttack.attackId)
					task.spawn(function()

						task.wait(data.animationEventLength)
						for _, tower: Model in towersInRange do
							tower:SetAttribute("Stunned", true)
						end
						local diff1 = data.duration - data.animationEventLength
						task.wait(diff1)

						unfreezeEnemy(enemy, workspace:GetServerTimeNow())
						enemy.state = nil
						data.actualFrequency = nil

						task.wait(data.freezeEnemyForSeconds - diff1)
						for _, tower: Model in towersInRange do
							if not tower then continue end
							tower:SetAttribute("Stunned", nil)
						end
						
						enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]
					end)
				end
			end
		end
	end)
end

return Enemy
