--//  Server handler for enemies, will not display more than this for the enemy system - to make it impossible to replicate unless you'd rewrite your own system. Feel free to learn from this code tho.

--[[

note note here

For a submission, this script pretty much covers an entiry enemy lifecycle, how it moves, some typechecking, some scheduling for attacks, summons, usual things you'd be finding in tower defense games - as well as
some cool little phase/state transitions.

that thing about the comments being ai did hit pretty hard - so I won't waste time on grammar and describe in detail what the code does, but with my own way of commenting, which is NOT against the rules,
I am not trolling, I probably am better than you at programming junior (you get who I am mimicking?)
I have read those guidelines like 10 times so cut me some slack, how was I supposed to know using proper grammar counts as AI now?? 

any questions about how this code works? I can hop in a voicechat and easily explain any part, from the deltaTime maths for delaying and syncing client-server, bulk movements, anything, although that won't be necessary.
nobody even reads this part anyway

--]]

--//  @RealManMun 27th August 2025

local Enemy = {}
Enemy.Priority = 2
Enemy.FarthestEnemy = nil
Enemy.FinalBossName = "IceboundKrampus"
Enemy.MarkedBosses = {}

--// Types
--// enemydata type, what more could you ask, also I am not exporting all of this data meaninglessly, just used typechecking because I fancy it here
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

	Distance: number,
	ExtraDistance: number,
	Position: Vector3,
	Orientation: Vector3, -- just for reference, this is the yaw in degrees, not just normal orientation
	PathIndex: number,

	--// bad boy summoners, on a serious note - this is pretty important for functionality
	summonTime: number | nil,
	summonDelayTime: number | nil,
	summonAnimationLength: number | nil,
	enemyToSummon: string | { string } | nil,
	previousSummonTime: number | nil,

	fat: number, -- listen, I get it sounds weird, okay? it's just, well, accurate, for calculating offsets
	enemyStats: {any},
	enemyValues: {string},      -- practically just a check to see if the enemy is hidden/flying or not, special type of enemies, play TDS for reference, cool game - get me a job there while you're at it
	died: boolean,
	
	--// enemies have to attack, don't they? they have a set of attacks, the ones that are currently active for their phase (rare case), the attack they are focused in this attack cycle, the last time they've attacked for
	-- time calculation (on my monitor the text was going off screen, thus me inserting a new line)
	Attacks: { [number]: { string | number | {number} } } | nil,
	activeAttacks: { { string | number | {number} } } | nil,
	currentAttack: { string | number | {number} },
	lastAttackTime: number | nil,
	Phase: number | nil, -- I've mentioned phases before, haven't I?
	CashPerHit: number,
	GodMode: boolean, -- big boy FrostSpirit goes from standing to flying and smashing all your towers to pieces - boom boom, anyway, getting hit by towers without flying detection during a transition was cutting off like
	-- half of its hp, you can tell why this is here

	state: string? -- no fancy state manager, is this enemy loser attacking / summoning or something? ask yourself that when you see state being mentioned, and you'll be good to go
}
type EnemyPool = { [string]: EnemyData }

--// Variables
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage") 
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Networking - using Packet for buffering, you should too 
local Packet = require(ReplicatedStorage:WaitForChild("Packet"))
local PathModule = require(ReplicatedStorage:WaitForChild("PathModule"))
local NetworkUtilityModule = require(ReplicatedStorage:WaitForChild("NetworkUtility"))

-- I mean, it does quite literally replace remote events through its own custom system, for more reference google it or just use some cheap ai
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

-- see, I try to optimize my code (give it a shot) | so all enemies are neatly defined in the enemypool, they all have uniqueids, not randomly generated just increasingly being counted, I wanted to do something with
-- fancy buffering (my monitor is average, okay?) but scrapped it, tho I still believe my approach was the best here
local mapWaypoints: { [number]: Instance } = {}
local freezeTimes: { [string]: number } = {}
local enemyPool: EnemyPool = {} 
local uniqueIdCounter = 0 
local enemyPoolCount = 0

-- what do you think? | bosses have healthbars, they should appear once tho not every time or it would lowkey piss me off
local healthbarEnemies = {
	["FrostShade"] = false,
	["FrostReaver"] = false,
	["FrostSpirit"] = false,
	["RoboSanta"] = false,
	["IceboundKrampus"] = false,
}

--// I mean, if you have 10 players or something it does get unfair doesn't it? should make it scale like a proper game dev, you can learn from this, seriously
local HEALTH_SCALE = 0.35
local HEALTH_SCALE_TARGETS = {"RoboSanta", "FrostVanguard", "IceboundKrampus", "FrostSpirit", "FrostNecromancer", "FrostbiteRevenant", "CryingSpirit"}

local wTowers = workspace:WaitForChild("Towers")

-- you wanna check the pathmodule to see if I'm better than you at programming concepts? go for it, same github | precomputes a path, no point in recreating it any time, just use time as a source of movement silly!
for _, child in waypointsFolder:GetChildren() do
	local i = tonumber(child.Name)
	if i then mapWaypoints[i] = child end
end
PathModule.precomputePath(1, mapWaypoints) -- 1 path for now


--// Utilities

--// packet needs a fireallclients feature, doesn't it? maybe I just missed it
local function fireAllClients(packet: Packet.Packet, ...)
	for _, player in Players:GetPlayers() do
		packet:FireClient(player, ...)
	end
end

--// if you think of adding a different module for this - you're probably right, but hey, does it really matter?
local function _len(dictionary: { [any]: any }): number
	local c = 0
	for _, __ in dictionary do
		c += 1
	end
	return c
end

--// we have to get the enemies in range of the aforementioned big strong attacks from those bad enemies, so what do we do? use a basic function to get them, obviously.
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

--// quickly apply the scaling of hp that I just mentioned before
local function getScaledHealth(baseHealth: number): number
	local playerCount = #Players:GetPlayers()
	if playerCount <= 1 then
		return baseHealth
	end
	return math.floor(
		baseHealth * (1 + HEALTH_SCALE * (playerCount - 1))
	)
end

--// let's create the enemy object, nothing visual unless you want a part to track bezier accuracy for orientation transitions
local function spawnEnemy(name: string, isSummoned: boolean, params: { Vector3 | Instance | number })
	local id = uniqueIdCounter
	local uniqueId = name .. "_" .. id
	uniqueIdCounter += 1

	local stats = EnemyStatsData[name]
	params = params or {}
	
	--// we play a voiceline if sounddata has an id marked to it, the id isn't the sound id, it's a buffering custom id each individual sound is assigned, I told you I'm probably better, didn't I?
	if stats and stats.SoundData and stats.SoundData.SpawnLineID then
		fireAllClients(PlaySoundPacket, stats.SoundData.SpawnLineID)
	end

	local summonData = stats.summonData or {}
	local fakeModel = EnemyModels[name]
	local settingsFolder = fakeModel.Settings

	--// we created that huge type, now we need to configure it
	local now = workspace:GetServerTimeNow() -- timebased movements proved to be more accurate, you know? also only losers actually use tick nowadays from what I've heard
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
		ExtraDistance = params[4] or 0,  -- easiest way to do this: summoned enemies need to get their parent's traveled distance as an addon for their overall distance on the precomputed path, you can apply some fancy
		-- speed scaling math instead, but I'd rather not bother with that, simplicity makes the genius after all (I'm no genius so don't ask me)
		Position =  params[1] or Vector3.zero,
		Orientation = params[2] or Vector3.zero,
		PathIndex = 1,

		summonTime = summonData[1] or nil,
		summonDelayTime = summonData[2] or nil,
		summonAnimationLength = summonData[3] or nil,
		enemyToSummon = summonData[4] or nil,
		isSummonRandom = summonData[5] or nil,
		previousSummonTime = now,

		fat = 0, -- shut up about this naming already
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
		
		--// wanna track how it moves on the server and see that dt issues when pausing the studio and accounting for delays is entirely removed from my timebased system? use this part, and give it a shot, hehe.
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
	
	--// apply the actual health scale
	enemy.Health = getScaledHealth(enemy.Health)

	--// visually, it's more pleasant to just see values inside of enemies so you can add Flying and Hidden enemies, but practically, why copy the same thing millions of times? just remove it entirely
	-- roblox handles memory for such things alone, so I won't bother going into that
	for _, settingValue in settingsFolder:GetChildren() do
		table.insert(enemy.enemyValues, settingValue.Name)
	end
	settingsFolder = nil
	
	--// we got some of those attacks mentioned before?? let's configure them
	if stats.attacksData then
		enemy.activeAttacks = {}
		enemy.lastAttackTime = now
		-- self explanatory 
		for attackId: number, data: {any} in stats.attacksData do
			local currentAttackTable = { 
				lastAttackTime = now, 
				range = data.attackRange, 
				duration = data.attackDuration, 
				animationEventLength = data.animationEventLength, 
				attackFrequency = data.attackFrequency, 
				freezeEnemyForSeconds = data.freezeEnemyForSeconds, 
				actualFrequency = nil,       -- randomized each cycle from attackFrequency range
				phase = data.phase,
				attackId = attackId,
			}
			
			enemy.Attacks[attackId] = currentAttackTable
			--// is the attack locked to a respective phase? (FrostSpirit phase 2 can maul the ground from its flying animation, but this should never happen on phase 1, phase-locking persay)
			if not data.phase then
				table.insert(enemy.activeAttacks, currentAttackTable)
			end
		end
		
		--// actually picking the attack (what if I use perlin noise? could make the attacks *smoother*?) | jokes, but seriously, you can learn about it
		enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)] -- not gonna use Random instead, math.random always seemed good unless we are talking about a weighted chance system by comparison
	end
	
	--// we got phases? start at the first one
	if stats.PhaseTwoData then
		enemy.Phase = 1
	end
	
	if _len(enemy.Attacks) == 0 then enemy.Attacks = nil end

	enemyPool[uniqueId] = enemy
	enemyPoolCount += 1

	--// you can convert time by using only a degree of accuracy from 6 digits, without having to account for offbyones, very convenient, we can also precompute time values for even more accuracy, and choose our own
	-- number of digits, however, by default I made it choose 6 respectively, with an equal ration of 3:3, you can try this in your projects, I love client-server communication and how Roblox handles it
	local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(enemy.SpawnTime)

	--// summoned enemies have extra data, but since Packet is very precise, we need two different packets for summoned enemies - after all, we have to pass the distance just like I mentioned
	if isSummoned then

		local elapsed = now - enemy.SpawnTime
		local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

		fireAllClients(SummonEnemyEvent, stats.EnemyIndex, id, encrypted, distanceTravelled, enemy.Health)
	else
		fireAllClients(ReplicateEnemyEvent, stats.EnemyIndex, encrypted, id)
	end
	
	--// track healthbars properly once the bosses finally spawn for the first time, as well as the theme music for them (fire songs btw, listen to them if you have the time)
	if healthbarEnemies[name] == false then
		healthbarEnemies[name] = true
		-- yes, the ThemeSongID is also properly buffered
		if stats.SoundData then
			fireAllClients(PlayMusicPacket, stats.SoundData.ThemeSongID)
		end
		
		--// Krampus is a big boy, he has a long voiceline, but why not cramp it all up in one sound? my friend was lazy and so was I to go into editing the sound, so I just made them play in a hardcoded manner
		-- just for the final boss, although making this better wouldn't take me more than a few minutes, I don't find the need to do it for this project of mine.
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

-- let's summon some enemies, shaln't we? when requested by the client later on and accounted for properly, we just get the amount and add a slight .3 second delay so they don't stack, the delay can scale based on
-- mass, an idea of mine - since it would determine speed based on size, however, who would have thought some of those big bosses were actually fast? so then, just make it based on their speed regardless, why complicate it?
-- nah, not worth it
local function summonEnemy(name: string, amount: number, ...): ()
	for i = 1, amount do
		local args = {...}
		args[5] += (0.3*(i - 1))
		spawnEnemy(name, true, args)
		task.wait(.3)
	end
end

--// used by either wave system or just admin commands if I wanna play around with them - what's that, you want admin too? no.
function Enemy.new(name: string, amount: number, delayTime: number): EnemyData
	for i = 1, amount do
		spawnEnemy(name)
		task.wait(delayTime)
	end
end

function Enemy.GetActiveEnemies(): EnemyPool
	return enemyPool
end

--// freezing needs to stop deltaTime accounted for progressing overall, but then how would we make up for it? by substracing a specific deltatime that can be increased throughout the code every time if the aforementioned
-- enemy is frozen by any reason, such as summoning or attacking, this is probably the coolest feature I've come up with for this timescaled movement

local function beginFreeze(enemy, now, elapsed): number
	enemy.FixedElapsed = elapsed - enemy.ElapsedDelay -- called it ElapsedDelay, my naming is bewitching sometimes
	return NetworkUtilityModule:EncryptNetworkServerTime(now)
end

local function endFreeze(enemy, now): ()
	enemy.ElapsedDelay += workspace:GetServerTimeNow() - now
	enemy.FixedElapsed = nil
end

-- seems like two systems are merged into one another, two different ideas plastered onto one - but summoning is a fixed process, which can all be determined at once regardless of external matters other than the enemy's health
-- while on the other side, attacking is done based on towers around you by default, so it cannot be controlled - too far gone? I am insane.
local function unfreezeEnemy(enemy: EnemyData, now: number): ()
	if (enemy.FixedElapsed and freezeTimes[enemy.UniqueId]) then
		local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
		fireAllClients(UnfreezeEnemyEvent, enemy.NumId, encrypted)
		enemy.ElapsedDelay += workspace:GetServerTimeNow() - freezeTimes[enemy.UniqueId]
		enemy.FixedElapsed = nil
		freezeTimes[enemy.UniqueId] = nil
	end
end

--// freeze and unfreeze, for attacks
function Enemy.Stop(now: number, elapsed: number, id: string, givenDuration: number)
	local enemy = enemyPool[id]
	beginFreeze(enemy, now, elapsed)

	task.wait(givenDuration)

	endFreeze(enemy, now)
end

--// freeze and unfreeze mechanic, but this time - for summoners, which have children to care for and deploy as puppets, reminds me of war games, ever played those?
function Enemy.SummonerStop(now: number, elapsed: number, id: string)
	local enemy = enemyPool[id]
	local encrypted = beginFreeze(enemy, now, elapsed)

	fireAllClients(SummonerEnemyEvent, enemy.enemyStats.EnemyIndex, encrypted, tonumber(id:split("_")[2]))

	--// basic math was done here, let's first wait for the animation so it looks badass
	task.wait(enemy.summonDelayTime)

	--// we can summon one enemy of one type, multiple enemies of one type or just multiple types of enemies, all with different numbers, if clause to handle it (thought it sounded cooler than statement)
	local enemyToSummon = enemy.enemyToSummon
	if typeof(enemyToSummon) == "string" then
		task.spawn(summonEnemy, enemyToSummon, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
	elseif typeof(enemyToSummon) == "table" then
		if enemy.isSummonRandom then
			local chosen = enemyToSummon[math.random(1, #enemyToSummon)]
			task.spawn(summonEnemy, chosen, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
		else
			-- here we give up, and summon everything we see in that accursed table!
			for _, enemyName in enemyToSummon do
				task.spawn(summonEnemy, enemyName, 1, enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance, enemy.SpawnTime, enemy.Speed)
			end
		end
	end

	--// we must wait for the cool animation my dear friend that I've enslaved made, then move forward.
	task.wait(enemy.summonAnimationLength - enemy.summonDelayTime)

	endFreeze(enemy, now)
	enemy.state = nil
end

function Enemy.GetFarthestEnemy(): EnemyData
	return Enemy.FarthestEnemy
end

--// updating hp, handles a bunch of stuff in here
function Enemy.UpdateHP(uniqueId: string, newhp: number, arg: string | nil) -- HP TO CHECK
	local enemy = enemyPool[uniqueId]
	if not enemy then return end
	local phaseTwoData = enemy.enemyStats.PhaseTwoData

	newhp = math.floor(newhp)
	if newhp < 0 then newhp = 0 end -- displaying needs to be accurate, can't be in the negatives, the healthbar transitions smoothly and even has a visual effect
	local numId = tonumber(uniqueId:split("_")[2]) -- let's get the id so we can get enemy data later on

	if newhp <= 0 then
		--// can't have multiple deaths at once or it might cause bugs, easy debouncer, in the truest sense tho - not just learned from a tutorial and then copy pasted the same trash debounce logic everywhere
		if enemy.died then return end
		
		--// phase 2? interesting, says the luau compiler, probably
		if enemy.Phase and enemy.Phase == 1 then
			local now = workspace:GetServerTimeNow()
			local elapsed = now - enemy.SpawnTime
			local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
			enemy.FixedElapsed = elapsed - enemy.ElapsedDelay

			--// lock the enemy in place during the transition animation
			enemy.state = "ActionState"
			freezeTimes[enemy.UniqueId] = now
			fireAllClients(NewPhaseEvent, numId, 2) -- automatically choose second phase (default)
			fireAllClients(FreezeEnemyEvent, numId, encrypted)
			
			-- phase 2 health is set
			local phaseTwoHealth = phaseTwoData.PhaseTwoHealth
			phaseTwoHealth = getScaledHealth(phaseTwoHealth)
			enemy.Health = phaseTwoHealth

			-- applying the actual godmode
			enemy.GodMode = true
			
			local stats = enemy.enemyStats
			if stats.SoundData and stats.SoundData.PhaseTransitionID then
				fireAllClients(PlaySoundPacket, stats.SoundData.PhaseTransitionID)
			end
			
			fireAllClients(UpdateEnemyHealthEvent, numId, phaseTwoHealth)
			
			--// we pull up the new attacks, after all - everything can be different
			enemy.Phase += 1
			enemy.lastAttackTime = now
			enemy.activeAttacks = {}
			for actualIndex, attack in enemy.Attacks do
				if attack.phase == enemy.Phase then
					table.insert(enemy.activeAttacks, enemy.Attacks[actualIndex])
				end
			end
			enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]

			--// does the phase include new values? we mentioned something like Hidden before, but here it's Flying usually
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

		-- ah, we need a bunch of stuff to fully kill this enemy
		local deathPosition, deathOrientation, deathCurrentWaypoint, deathDistanceReached = enemy.Position, enemy.Orientation, enemy.CurrentWaypoint, enemy.Distance

		enemy.Health = 0
		--// stop any theme song, once again properly buffered
		if enemy.SOUND_MARKED and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.ThemeSongID then
			fireAllClients(StopMusicPacket, enemy.enemyStats.SoundData.ThemeSongID)
		end
		enemy.died = true
		--// there's a /clears command that just murders all enemies at once for stress tests (handled 150,000 enemies at once after camera movement was involved, 30,000 with active models containing the bare minimum of verticies
		if arg ~= "autoclear" then
			if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.DeathSoundID then
				fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.DeathSoundID)
			end
		end
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)

		--// mystery type enemies have to spawn something on death; surprise! not only locked to them tho | if you are thinking of using this to actually handle something like a phase two transition, stop being so lazy, bad practice
		local stats = enemy.enemyStats
		if stats.summonType == "OnDeath" then
			local summonData = stats.summonData
			local summonedEntityName = summonData.summonedEntityName
			local summonedEntityAmount = summonData.summonedEntityAmount

			--// we can summon random enemies for mysteries, or just a specific one if it's just one type
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
		--// clients need to remove it, pools need to be updated
		fireAllClients(RemoveEnemyEvent, numId)
		enemyPool[uniqueId] = nil
		enemyPoolCount -= 1
	else
		-- update hp, send this new data to the client - tried many workarounds, they seemed to be innacurate tho, so I just decided to buffer my way through it
		enemy.Health = newhp
		fireAllClients(UpdateEnemyHealthEvent, tonumber(uniqueId:split("_")[2]), newhp)
	end
	
	--// has the final boss, somehow actually died? (the game is practically a joke in difficulty for people with common sense)
	if arg == "autoclear" then
		print("Autocleared.")
		--
	else
		if enemy.Health == 0 and enemy.Name == Enemy.FinalBossName then --// what happened with the voicelines had to happen with the displays, ignorance is truly a sin, no doubt - but is laziness not one as well?
			print("Game cleared succesfully!")
			fireAllClients(PlaySoundPacket, 2)
			task.wait(1)
			--// boom boom die
			fireAllClients(KrampusMessagePacket, 4)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 5)
			task.wait(8)
			fireAllClients(KrampusMessagePacket, 6)
			task.wait(8)
			GAME.Value = false
			--// add wins stat to an autoupdated ProfileStore that checks through a stats folder so an external influencer like Replica is not needed
			local awarded = {}
			for _, player: Player in Players:GetPlayers() do
				if not table.find(awarded, player) then
					table.insert(awarded, player)
					player:WaitForChild("Stats"):WaitForChild("Wins").Value += 1
				end
			end
			
			fireAllClients(GameEndPacket, 1)
			fireAllClients(PlayMusicPacket, 102)
			--// give my greatful players some time to enjoy the winning theme, then forcefully send them back
			task.delay(60, function()
				print("Teleporting remaining players..")
				for _, player: Player in Players:GetPlayers() do
					TeleportService:Teleport(PlaceIds.Lobby, player)
				end
			end)
		end
	end
end

--// obvious, returns an amount representing the enemies active
function Enemy.GetActiveEnemyCount(): number
	return enemyPoolCount
end

--// you lost or you won, regardless this is what happens:
function Enemy.ClearAllEnemies(): ()
	-- since the boss would already be dead in the case you won, use autoclear to skip the if block of code entirely
	for id, enemy in enemyPool do
		Enemy.UpdateHP(id, 0, "autoclear")
		enemyPool[id] = nil
	end
	enemyPoolCount = 0
end

--// this is where the movement is being tracked, called within a priority based framework written by me (told you I'm good)
function Enemy.Init(serverModules)
	print("SERVER Enemy system initialized")

	BaseModule = serverModules["Base"]
	task.wait(5)
	
	--// sync at 20hz using an accumulator based on deltatime, no need to worry about overshooting here since the client lag would cause delays fixed by the servers as soon as the game regulates itself, for extreme cases
	-- roblox handles them by removing you from the game, some games with valuable trade markets kick you on very low framerate, but I find that unfair, I always thought they are just not as good as me - turned out
	-- to be accurate, due to laziness
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()

		-- track the accumulator based on deltatime
		accumulator += dt
		if accumulator >= 1/20 then
			accumulator = 0
			fireAllClients(SyncToServerTimeEvent,  NetworkUtilityModule:EncryptNetworkServerTime(now))		
		end
		
		--// we must track the farthest enemy for summoner towers to not have to do a magnitude / fastcast (raycast through multiple objects, external module) constantly, they can receive this information easily
		-- summoner towers do exist in this game, all being completely simulated, check out the FrostLegion in the game, it's one of the more complex systems in the game and uses double-scaled deltaTime (2dimensional)
		local farthestDistance = 0
		local farthestEnemy = nil

		-- if there is no active enemy, the farthest enemy would naturally be nil
		if enemyPoolCount == 0 then
			if Enemy.FarthestEnemy ~= nil then
				Enemy.FarthestEnemy = nil
			end
		end

		for id, enemy in enemyPool do
			if enemy.Health <= 0 then continue end

			--// core formula: distance = speed * effectiveTime + extraDistance | makes sense, considering this is a timebased movement system
			-- fixed elapsed was already explained, here we just substract it from the elapsed to keep things accurate for intentional time delays
			local elapsed = now - enemy.SpawnTime
			local distanceTravelled = enemy.Speed * ( enemy.FixedElapsed or (elapsed - enemy.ElapsedDelay)) + enemy.ExtraDistance

			enemy.Distance = distanceTravelled
			if distanceTravelled > farthestDistance then farthestDistance = distanceTravelled farthestEnemy = enemy end
			
			--// if the enemy reached the end of the path, it reached the base - handled that case in the BaseModule, so we don't need to worry about it
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

			--// we need to keep the position in the world relative to that of the path, as well as minding orientation using yaw degrees precalculated using the pathmodule for beziers
			-- the bezier curves are also handled using time, but for this case: time is using speed for the distance on the path (distance = speed * time, no need to search it up yourself)
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
				
				--// we need to handle summoning, first by checking if the enemy can summon, and then checking its current action state
				if enemy.summonTime and not (enemy.state == "ActionState") then
					local timeSinceSpawn = now - enemy.previousSummonTime
					if timeSinceSpawn >= enemy.summonTime then
						enemy.state = "ActionState"
						enemy.previousSummonTime = now
						if enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.SummonLinesID then
							fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.SummonLinesID) -- even this can have a voiceline, once again - properly buffered.
						end
						task.spawn(Enemy.SummonerStop, now, elapsed, id)
					end
				end
			end

			if farthestEnemy then
				Enemy.FarthestEnemy = farthestEnemy
			end
			
			--// -> randomize frequency after choosing a random attack based on the current phase (or just 1, if there's no multiple phases)
			local attacksData = enemy.Attacks
			if attacksData and enemy.currentAttack then
				if enemy.state == "ActionState" then continue end
				
				local data = enemy.currentAttack
				--// we haven't been here in our current attack cycle? we need to have a frequency before moving forward, so we generate it randomly
				if not data.actualFrequency then
					data.actualFrequency = math.random(data.attackFrequency[1], data.attackFrequency[2]) -- now, what about perlin-noising it? I'm losing it.
				end
				
				--// attack, stun the towers, end my suffering.
				if now - enemy.lastAttackTime >= data.actualFrequency then
					enemy.state = "ActionState"
					enemy.lastAttackTime = now
					local encrypted = NetworkUtilityModule:EncryptNetworkServerTime(now)
					enemy.FixedElapsed = elapsed - enemy.ElapsedDelay
					freezeTimes[enemy.UniqueId] = now
					fireAllClients(FreezeEnemyEvent, enemy.NumId, encrypted)

					--// the utility section was not useless, as you can see: (grabbing the towers in range, acting based on them, and wait, attacks have voiceleines properly buffered too?? very cool.)
					local towersInRange = getTowersInRange(enemy.Position, data.range)
					if enemy and enemy.enemyStats and enemy.enemyStats.SoundData and enemy.enemyStats.SoundData.AttackLinesID then
						fireAllClients(PlaySoundPacket, enemy.enemyStats.SoundData.AttackLinesID)
					end
					fireAllClients(EnemyAttackEvent, enemy.NumId, enemy.currentAttack.attackId)
					task.spawn(function()

						--// all animations must reach a point before stunning, to have neat visuals
						task.wait(data.animationEventLength)
						for _, tower: Model in towersInRange do
							tower:SetAttribute("Stunned", true)
						end
						--// wait for the rest of the attack duration after the hit landed (makes it sound like a nuclear missle)
						local diff1 = data.duration - data.animationEventLength
						task.wait(diff1)

						--// unfreeze the enemy, reset the state, reset frequency for a reroll later on.
						unfreezeEnemy(enemy, workspace:GetServerTimeNow())
						enemy.state = nil
						data.actualFrequency = nil     -- will re-roll next cycle

						--// towers should stay stunned for their predetermined duration
						task.wait(data.freezeEnemyForSeconds - diff1)
						for _, tower: Model in towersInRange do
							if not tower then continue end
							tower:SetAttribute("Stunned", nil)
						end
						
						--// finally, we pick the next random attack
						enemy.currentAttack = enemy.activeAttacks[math.random(1, #enemy.activeAttacks)]
					end)
				end
			end
		end
	end)
end

return Enemy --// properly finish the work by returning
