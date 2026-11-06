--!nolint
if getgenv().fragStop then getgenv().fragStop() end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local plr = Players.LocalPlayer
local pickups = workspace:WaitForChild("Pickups")

local MAX_DIST = 1000        -- only target fragments within this distance of home
local TWEEN_SPEED = 350      -- studs per second when gliding
local MIN_TWEEN_TIME = 0.08  -- fastest tween duration (for nearby fragments)
local MAX_TWEEN_TIME = 0.45  -- cap on tween duration (so far fragments are still fast)
local HOLD_TIME = 0.40       -- seconds spent touching each fragment on arrival
local MAX_ATTEMPTS = 5       -- retries per fragment (handles spawn immunity)
local RETRY_COOLDOWN = 0.5   -- seconds to wait before retrying a stubborn fragment
local SINK = 1.5             -- how far below standing height to sink feet into floor fragments
local LIFT = 6               -- smooth hop height to reset TouchTransmitter
local DEBUG = true           -- set to false to silence F9 console prints

local alive = true
local busy = false
local activeTween = nil
local picked = setmetatable({}, { __mode = "k" })
local attempts = setmetatable({}, { __mode = "k" })
local skipUntil = setmetatable({}, { __mode = "k" })
local hadTouch = setmetatable({}, { __mode = "k" })
local unknownNames = {}
local conns = {}

local function log(...)
	if DEBUG then
		print("[Fragments]", ...)
	end
end

local function fmtVec(v)
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function cancelTween()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
end

local function getRoot()
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 and hum.RootPart then
		return hum.RootPart, hum
	end
	return nil, nil
end

local function standHeight(hum, hrp)
	if hum.RigType == Enum.HumanoidRigType.R15 then
		return hum.HipHeight + hrp.Size.Y / 2
	end
	local leg = hum.Parent:FindFirstChild("Left Leg")
	return hrp.Size.Y / 2 + (leg and leg.Size.Y or 2)
end

local function getPart(v)
	if v:IsA("BasePart") then return v end
	local ti = v:FindFirstChildWhichIsA("TouchTransmitter", true)
	if ti and ti.Parent:IsA("BasePart") then return ti.Parent end
	if v:IsA("Model") and v.PrimaryPart then return v.PrimaryPart end
	return v:FindFirstChildWhichIsA("BasePart", true)
end

local function isCollectable(v, part)
	if not v or not part then return false, "missing_part" end
	if picked[v] then return false, "already_marked" end
	if not v:IsDescendantOf(pickups) or not part:IsDescendantOf(workspace) then
		return false, "removed"
	end
	if part.Transparency >= 0.95 then
		return false, "transparent_picked"
	end
	local hasTI = (part:FindFirstChildOfClass("TouchTransmitter") ~= nil)
		or (v:FindFirstChildWhichIsA("TouchTransmitter", true) ~= nil)
	if hasTI then
		hadTouch[v] = true
	elseif hadTouch[v] then
		return false, "touch_removed"
	end
	return true
end

local function checkDistance(partPos, originPos)
	local dist = (partPos - originPos).Magnitude
	return dist <= MAX_DIST, dist
end

local function pin(hrp, pos, rot)
	hrp.CFrame = CFrame.new(pos) * rot
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

-- Smoothly tween hrp to a target position; cancels early if checkFn() returns false
local function tweenTo(hrp, targetPos, rot, checkFn)
	cancelTween()

	local dist = (targetPos - hrp.Position).Magnitude
	if dist < 1 then
		pin(hrp, targetPos, rot)
		return true
	end

	local duration = .1
	local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local tween = TweenService:Create(hrp, info, { CFrame = CFrame.new(targetPos) * rot })
	activeTween = tween
	tween:Play()

	while alive and tween.PlaybackState == Enum.PlaybackState.Playing do
		if getRoot() ~= hrp then
			cancelTween()
			return false, "respawned"
		end
		if checkFn then
			local ok, reason = checkFn()
			if not ok then
				cancelTween()
				return false, reason
			end
		end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
	end

	if activeTween == tween then
		activeTween = nil
	end
	return true
end

-- Find nearest valid fragment within MAX_DIST of homePos
local function getNext(hrpPos, homePos)
	local now = os.clock()
	local best, bestPart, bestAtt, bestDist, bestHomeDist

	for _, v in pickups:GetChildren() do
		if v.Name ~= "Fragment" then
			if DEBUG and not unknownNames[v.Name] then
				unknownNames[v.Name] = true
				log("Note: Found non-'Fragment' item in Pickups:", v.Name, v.ClassName)
			end
			continue
		end
		if picked[v] then continue end
		if (skipUntil[v] or 0) > now then continue end

		local part = getPart(v)
		if not part then continue end

		local ok, reason = isCollectable(v, part)
		if not ok then
			picked[v] = true
			log("Marking dead fragment during scan:", v:GetFullName(), "| Reason:", reason)
			continue
		end

		local withinMax, homeDist = checkDistance(part.Position, homePos)
		if not withinMax then continue end

		local att = attempts[v] or 0
		local curDist = (part.Position - hrpPos).Magnitude

		if not best or att < bestAtt or (att == bestAtt and curDist < bestDist) then
			best, bestPart, bestAtt, bestDist, bestHomeDist = v, part, att, curDist, homeDist
		end
	end

	return best, bestPart, bestDist, bestHomeDist
end

local function collect()
	local hrp, hum = getRoot()
	if not hrp or not hum then return end

	local startCF = hrp.CFrame
	local homePos = startCF.Position
	local rot = startCF.Rotation

	local v, part, curDist, homeDist = getNext(homePos, homePos)
	if not v then return end

	local footOffset = math.max(0, standHeight(hum, hrp) - SINK)
	log(string.format("Starting batch | Home locked at %s | StandOffset: %.1f", fmtVec(homePos), footOffset))
	local pickedCount = 0

	while alive and v and part do
		attempts[v] = (attempts[v] or 0) + 1
		log(string.format(
			"-> Tweening to: %s | Dist: %.1f | HomeDist: %.1f/%d | Attempt %d/%d",
			v:GetFullName(), curDist, homeDist, MAX_DIST, attempts[v], MAX_ATTEMPTS
		))

		local status = "timeout"

		-- 1. Smoothly tween to the fragment, aborting immediately if it's picked up or leaves MAX_DIST
		local goalPos = part.Position + Vector3.new(0, footOffset, 0)
		local reached, abortReason = tweenTo(hrp, goalPos, rot, function()
			local ok, r = isCollectable(v, part)
			if not ok then return false, r end
			local withinMax = checkDistance(part.Position, homePos)
			if not withinMax then return false, "out_of_range" end
			return true
		end)

		if not reached then
			if abortReason == "respawned" then
				log("Batch aborted: character changed/respawned")
				return
			end
			status = abortReason
		else
			-- 2. Hold on the fragment with a smooth sine wave vertical sweep to trigger .Touched
			local t = 0
			while alive and t < HOLD_TIME do
				if getRoot() ~= hrp then
					cancelTween()
					log("Batch aborted: character changed/respawned")
					return
				end

				local ok, reason = isCollectable(v, part)
				if not ok then
					status = reason
					break
				end

				local curPos = part.Position
				local withinMax, dHome = checkDistance(curPos, homePos)
				if not withinMax then
					status = "out_of_range"
					log(string.format("   [DIST STOP] Fragment at %.1f studs exceeds MAX_DIST (%d)", dHome, MAX_DIST))
					break
				end

				-- Smooth vertical wave between root-level (0) and lifted hop (footOffset + LIFT)
				local wave = (math.sin(t * 25) + 1) * 0.5
				local yOff = wave * (footOffset + LIFT)
				pin(hrp, curPos + Vector3.new(0, yOff, 0), rot)

				if firetouchinterest then
					pcall(firetouchinterest, hrp, part, false)
					pcall(firetouchinterest, hrp, part, true)
				end

				t += RunService.Heartbeat:Wait()
			end
		end

		-- Evaluate fragment state after visit
		local stillValid, endReason = isCollectable(v, part)
		if not stillValid then
			status = endReason
		end

		if status == "removed" or status == "transparent_picked" or status == "touch_removed" then
			picked[v] = true
			pickedCount += 1
			log(string.format("   [PICKED] Confirmed pickup (%s)", status))
		elseif status == "out_of_range" then
			skipUntil[v] = os.clock() + RETRY_COOLDOWN
		else
			if attempts[v] >= MAX_ATTEMPTS then
				picked[v] = true
				log(string.format("   [MARKED DONE] Reached %d attempts; marked so we stop visiting it", MAX_ATTEMPTS))
			else
				skipUntil[v] = os.clock() + RETRY_COOLDOWN
				log(string.format("   [RETRY] Still present (spawn delay/lag) -> retrying in %.1fs", RETRY_COOLDOWN))
			end
		end

		v, part, curDist, homeDist = getNext(hrp.Position, homePos)
	end

	-- Smoothly tween back to the exact starting position
	if getRoot() == hrp then
		log("Tweening back to home:", fmtVec(homePos))
		tweenTo(hrp, homePos, rot)
		pin(hrp, homePos, rot)
		log(string.format("Batch finished | Returned to %s | Picked up: %d", fmtVec(homePos), pickedCount))
	end
end

local function tryCollect()
	if busy or not alive then return end
	busy = true
	local ok, err = pcall(collect)
	cancelTween()
	if not ok then
		warn("[Fragments Error]", err)
	end
	busy = false
end

-- Instant trigger as soon as a fragment drops within MAX_DIST
table.insert(conns, pickups.ChildAdded:Connect(function(child)
	if not alive or child.Name ~= "Fragment" then return end
	task.spawn(function()
		local t = 0
		while alive and child.Parent == pickups and not getPart(child) and t < 1 do
			t += task.wait()
		end
		local part = getPart(child)
		local hrp = getRoot()
		if alive and part and hrp then
			local withinMax, dist = checkDistance(part.Position, hrp.Position)
			if withinMax then
				log(string.format("Drop detected in range (%.1f studs): %s", dist, child:GetFullName()))
				tryCollect()
			else
				log(string.format("Drop ignored (%.1f studs > MAX_DIST %d): %s", dist, MAX_DIST, child:GetFullName()))
			end
		end
	end)
end))

table.insert(conns, pickups.ChildRemoved:Connect(function(child)
	picked[child] = nil
	attempts[child] = nil
	skipUntil[child] = nil
	hadTouch[child] = nil
end))

getgenv().fragStop = function()
	alive = false
	cancelTween()
	for _, c in conns do
		c:Disconnect()
	end
	log("Stopped fragment collector.")
end

log("Fragment collector started (Tween mode) | MAX_DIST =", MAX_DIST)

task.spawn(function()
	while alive do
		tryCollect()
		task.wait(0.1)
	end
end)
