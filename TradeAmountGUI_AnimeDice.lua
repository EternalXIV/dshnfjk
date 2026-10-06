--[[
    Anime Dice — Trade Amount GUI  (สคริปต์ที่ 1)
    ================================================================
    ปัญหาเดิม: จะส่งของจำนวนมากให้คนอื่น ต้องนั่งกดไอคอนเองทีละครั้ง
    เพราะ UI ของเกมยิง ChangeOffer(key, +1) ต่อ 1 คลิกเท่านั้น

    สคริปต์นี้ = GUI ให้ "กรอกจำนวนที่อยากส่ง" แล้วมันยิงให้เองจนครบ

    ── ข้อเท็จจริงจากซอร์สเกม (ReplicatedStorage.Framework.Features.Trading) ──
      ChangeOffer(key, amount) -> ส่งทีเดียวเต็มจำนวนได้ (เกม clamp ให้เท่าที่มีในกระเป๋า)
          ถ้าของไม่เข้า ให้ตั้ง CFG.OfferMode = "loop" (ยิงทีละ +1 ช้าแต่ชัวร์)
      DebounceUtil.Try(player, "TradeChangeOffer", 0.1)
        -> ยิงถี่กว่า 0.1 วิ/ครั้ง จะถูกดรอป (OfferDelay 0.12 เผื่อไว้แล้ว)
      TradeClass.ChangeOffer -> ResetConfirmation()
        -> ใส่ของทุกครั้ง ready/accept จะถูกรีเซ็ต => ต้องใส่ให้ครบก่อนค่อยกด ready
      TradeConfig: MAX_UNIQUE_ENTRIES = 20, MIN_ROLLS = 1000,
                   MIN_ACCOUNT_AGE = 14, UNTRADEABLE_ENTRIES = { "Tickets" }

    ── วิธีใช้ ──
      1) รันสคริปต์นี้ (executor ไหนก็ได้)
      2) เปิดเทรดกับคนที่จะให้ตามปกติ
      3) ในตาราง: กรอกจำนวนในช่องขวาของแต่ละไอเทม
         รับ: 2500 | 2.5k | 1m | all | max | ครึ่ง = half
      4) กด [▶ ใส่ของตามที่กรอก]  — มันจะยิงทีละ +1 จนครบ แล้วรายงานความคืบหน้า
      5) กด [✓ READY] เมื่อใส่ครบ (หรือเปิด AutoReady ให้กดเอง)

    ปุ่มลัด: RightCtrl = ซ่อน/โชว์ GUI
    ปิดสคริปต์: _G.ADTradeGUI_Stop()
--]]

------------------------------------------------------------------
-- SETTINGS
-- ตั้งจาก one-liner ได้: getgenv().TradeGUIConfig = { ... } ก่อน loadstring
-- (ไม่ตั้งก็ใช้ค่า default ด้านล่าง)
------------------------------------------------------------------
local _U = (typeof(getgenv) == "function" and getgenv().TradeGUIConfig) or {}
if type(_U) ~= "table" then _U = {} end
local function pick(u, d) if u ~= nil then return u end return d end

local CFG = {
    -- "bulk" = ยิงทีเดียวเต็มจำนวนตามที่กรอก | "loop" = ยิงทีละ +1 (ช้า สำรอง)
    OfferMode    = pick(_U.OfferMode, "bulk"),
    -- หน่วงต่อการยิง 1 ครั้ง (เซิร์ฟ debounce 0.1 วิ อย่าลดต่ำกว่า 0.11)
    OfferDelay   = pick(_U.OfferDelay, 0.12),
    -- true = ใส่ครบแล้วกด ready ให้เอง
    AutoReady    = pick(_U.AutoReady, false),
    -- true = ตอนเข้า phase Confirm กด accept ให้เอง (ระวัง! ตรวจของอีกฝั่งเอง)
    AutoAccept   = pick(_U.AutoAccept, false),
    -- โชว์ตัวละคร (Unit) ในตารางด้วย (unit = 1 ชิ้น/คีย์ ไม่ stack)
    ShowUnits    = pick(_U.ShowUnits, true),
    -- ปุ่มซ่อน/โชว์ GUI
    HideKey      = pick(_U.HideKey, Enum.KeyCode.RightControl),
}

------------------------------------------------------------------
-- SERVICES / REMOTES
------------------------------------------------------------------
local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")

local LP = Players.LocalPlayer
if not LP then
    local t0 = os.clock()
    repeat task.wait(0.1) until Players.LocalPlayer or (os.clock() - t0 > 30)
    LP = Players.LocalPlayer
end
if not LP then return warn("[TradeGUI] LocalPlayer ไม่พร้อม") end

local Net     = RS:WaitForChild("Network")
local TradeRE = Net:WaitForChild("TradeService"):WaitForChild("RE")
local rOffer   = TradeRE:WaitForChild("ChangeOffer")
local rAdvance = TradeRE:WaitForChild("AdvanceTrade")
local rCancel  = TradeRE:WaitForChild("CancelTrade")
local rEvent   = TradeRE:WaitForChild("TradeEvent")

local DataController = require(RS.Framework.Features.Data.DataController)
local EntryRegistry  = require(RS.Framework.Features.Inventory.EntryRegistry)
local TradeConfig    = require(RS.Framework.Features.Trading.TradeConfig)

local UNTRADEABLE = {}
for _, n in ipairs(TradeConfig.UNTRADEABLE_ENTRIES or { "Tickets" }) do UNTRADEABLE[n] = true end
local MAX_UNIQUE = TradeConfig.MAX_UNIQUE_ENTRIES or 20

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------
local ST = {
    inTrade    = false,
    phase      = "-",
    partner    = nil,
    ownOffer   = {},      -- key -> amount ที่ "เซิร์ฟ" บันทึกว่าเราใส่ไปแล้ว (จาก event Updated)
    sending    = false,
    stopFlag   = false,
    rows       = {},      -- key -> {frame, box, nameLabel, haveLabel}
    alive      = true,
}

local function log(...) print("[TradeGUI]", ...) end

------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qd = 1e15, qi = 1e18 }

-- แปลงข้อความที่ผู้ใช้กรอก -> จำนวนจริง (รองรับ all / max / half / 2.5k / 1m)
local function parseAmount(text, have)
    if text == nil then return 0 end
    local s = tostring(text):gsub("[%s,]", ""):lower()
    if s == "" then return 0 end
    if s == "all" or s == "max" or s == "*" then return have end
    if s == "half" then return math.floor(have / 2) end
    local num, suf = s:match("^([%d%.]+)(%a*)$")
    local n = tonumber(num)
    if not n then return 0 end
    if suf ~= "" then
        local mult = SUFFIX[suf]
        if not mult then return 0 end
        n = n * mult
    end
    n = math.floor(n)
    if n < 0 then n = 0 end
    if n > have then n = have end
    return n
end

local function fmt(n)
    if n >= 1e12 then return ("%.2ft"):format(n / 1e12) end
    if n >= 1e9  then return ("%.2fb"):format(n / 1e9)  end
    if n >= 1e6  then return ("%.2fm"):format(n / 1e6)  end
    if n >= 1e3  then return ("%.2fk"):format(n / 1e3)  end
    return tostring(n)
end

-- อ่านกระเป๋า -> list { key, name, amount, kind, isUnit }
local function readInventory()
    local out = {}
    local ok, inv = pcall(function() return DataController.Inventory() end)
    if not ok or not inv then return out end
    for key, e in pairs(inv) do
        if type(e) == "table" and e.name and not UNTRADEABLE[e.name] then
            local kind
            local okc, cfg = pcall(function() return EntryRegistry.getEntryConfig(e.name) end)
            if okc and cfg then kind = cfg.kind end
            local isUnit = (kind == "Unit")
            if CFG.ShowUnits or not isUnit then
                out[#out + 1] = {
                    key = key, name = e.name, amount = e.amount or 1,
                    kind = kind or "?", isUnit = isUnit,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.isUnit ~= b.isUnit then return not a.isUnit end
        if a.amount ~= b.amount then return a.amount > b.amount end
        return a.name < b.name
    end)
    return out
end

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ADTradeAmountGUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 9999
do
    -- เกมทำลาย ScreenGui แปลกปลอมใน PlayerGui ได้ -> ใช้ที่หลบของ executor ก่อน
    local parented = false
    if typeof(gethui) == "function" then
        parented = pcall(function() gui.Parent = gethui() end)
    end
    if not parented then
        pcall(function() gui.Parent = LP:WaitForChild("PlayerGui") end)
    end
end

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local root = mk("Frame", {
    Size = UDim2.fromOffset(430, 480),
    Position = UDim2.new(0.5, -215, 0.5, -240),
    BackgroundColor3 = Color3.fromRGB(24, 26, 34),
    BorderSizePixel = 0,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 10) }, root)
mk("UIStroke", { Color = Color3.fromRGB(70, 110, 220), Thickness = 2 }, root)

local title = mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = Color3.fromRGB(34, 38, 52),
    BorderSizePixel = 0,
    Text = "  🎲 Anime Dice — Trade Amount",
    TextColor3 = Color3.fromRGB(235, 238, 250),
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 15,
}, root)
mk("UICorner", { CornerRadius = UDim.new(0, 10) }, title)

local status = mk("TextLabel", {
    Size = UDim2.new(1, -16, 0, 30), Position = UDim2.fromOffset(8, 38),
    BackgroundColor3 = Color3.fromRGB(18, 20, 27), BorderSizePixel = 0,
    Text = "สถานะ: ยังไม่ได้อยู่ในเทรด",
    TextColor3 = Color3.fromRGB(200, 206, 225),
    Font = Enum.Font.Gotham, TextSize = 13,
}, root)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, status)

local search = mk("TextBox", {
    Size = UDim2.new(1, -16, 0, 26), Position = UDim2.fromOffset(8, 72),
    BackgroundColor3 = Color3.fromRGB(18, 20, 27), BorderSizePixel = 0,
    PlaceholderText = "ค้นหาชื่อไอเทม...", Text = "",
    TextColor3 = Color3.fromRGB(225, 230, 245), ClearTextOnFocus = false,
    Font = Enum.Font.Gotham, TextSize = 13,
}, root)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, search)

local list = mk("ScrollingFrame", {
    Size = UDim2.new(1, -16, 1, -190), Position = UDim2.fromOffset(8, 104),
    BackgroundColor3 = Color3.fromRGB(18, 20, 27), BorderSizePixel = 0,
    ScrollBarThickness = 5, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, root)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, list)
mk("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
mk("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, list)

local progress = mk("TextLabel", {
    Size = UDim2.new(1, -16, 0, 34), Position = UDim2.new(0, 8, 1, -82),
    BackgroundColor3 = Color3.fromRGB(18, 20, 27), BorderSizePixel = 0,
    Text = "พร้อม — กรอกจำนวนแล้วกดปุ่มด้านล่าง",
    TextColor3 = Color3.fromRGB(190, 220, 190),
    Font = Enum.Font.Gotham, TextSize = 12, TextWrapped = true,
}, root)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, progress)

local function button(text, x, w, color)
    local b = mk("TextButton", {
        Size = UDim2.fromOffset(w, 34), Position = UDim2.new(0, x, 1, -42),
        BackgroundColor3 = color, BorderSizePixel = 0, AutoButtonColor = true,
        Text = text, TextColor3 = Color3.fromRGB(255, 255, 255),
        Font = Enum.Font.GothamBold, TextSize = 13,
    }, root)
    mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    return b
end

local btnSend   = button("▶ ใส่ของตามที่กรอก", 8,   176, Color3.fromRGB(48, 110, 200))
local btnStop   = button("■ หยุด",            190,  70, Color3.fromRGB(150, 60, 60))
local btnReady  = button("✓ READY",           266,  70, Color3.fromRGB(50, 140, 70))
local btnRefresh= button("⟳",                 342,  34, Color3.fromRGB(70, 74, 92))
local btnCancel = button("✖",                 382,  40, Color3.fromRGB(100, 50, 50))

-- ลาก GUI ด้วยแถบหัว
do
    local dragging, dragStart, startPos = false, nil, nil
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, root.Position
        end
    end)
    title.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                      startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == CFG.HideKey then root.Visible = not root.Visible end
end)

------------------------------------------------------------------
-- ตารางไอเทม
------------------------------------------------------------------
local wanted = {}   -- key -> ตัวเลขที่ผู้ใช้กรอก (คงค่าไว้ตอน refresh)

local function rebuildList()
    for _, r in pairs(ST.rows) do
        if r.frame then r.frame:Destroy() end
    end
    ST.rows = {}

    local filter = (search.Text or ""):lower()
    local inv = readInventory()
    local shown = 0

    for idx, it in ipairs(inv) do
        local pass = (filter == "") or (it.name:lower():find(filter, 1, true) ~= nil)
        if pass then
            shown = shown + 1
            local row = mk("Frame", {
                Size = UDim2.new(1, -8, 0, 28), LayoutOrder = idx,
                BackgroundColor3 = it.isUnit and Color3.fromRGB(40, 32, 52) or Color3.fromRGB(30, 33, 43),
                BorderSizePixel = 0,
            }, list)
            mk("UICorner", { CornerRadius = UDim.new(0, 5) }, row)

            mk("TextLabel", {
                Size = UDim2.new(1, -168, 1, 0), Position = UDim2.fromOffset(8, 0),
                BackgroundTransparency = 1, Text = it.name,
                TextColor3 = it.isUnit and Color3.fromRGB(215, 185, 255) or Color3.fromRGB(225, 230, 245),
                TextXAlignment = Enum.TextXAlignment.Left,
                Font = Enum.Font.Gotham, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
            }, row)

            local have = mk("TextLabel", {
                Size = UDim2.fromOffset(62, 28), Position = UDim2.new(1, -160, 0, 0),
                BackgroundTransparency = 1, Text = "x" .. fmt(it.amount),
                TextColor3 = Color3.fromRGB(160, 170, 195),
                TextXAlignment = Enum.TextXAlignment.Right,
                Font = Enum.Font.Gotham, TextSize = 12,
            }, row)

            local box = mk("TextBox", {
                Size = UDim2.fromOffset(62, 22), Position = UDim2.new(1, -92, 0, 3),
                BackgroundColor3 = Color3.fromRGB(16, 18, 24), BorderSizePixel = 0,
                Text = wanted[it.key] and tostring(wanted[it.key]) or "",
                PlaceholderText = "0", ClearTextOnFocus = false,
                TextColor3 = Color3.fromRGB(255, 240, 180),
                Font = Enum.Font.Gotham, TextSize = 12,
            }, row)
            mk("UICorner", { CornerRadius = UDim.new(0, 4) }, box)

            local maxBtn = mk("TextButton", {
                Size = UDim2.fromOffset(26, 22), Position = UDim2.new(1, -28, 0, 3),
                BackgroundColor3 = Color3.fromRGB(60, 64, 82), BorderSizePixel = 0,
                Text = "max", TextColor3 = Color3.fromRGB(235, 238, 250),
                Font = Enum.Font.Gotham, TextSize = 10,
            }, row)
            mk("UICorner", { CornerRadius = UDim.new(0, 4) }, maxBtn)

            local keyRef, haveRef = it.key, it.amount
            box.FocusLost:Connect(function()
                local n = parseAmount(box.Text, haveRef)
                wanted[keyRef] = (n > 0) and n or nil
                box.Text = (n > 0) and tostring(n) or ""
            end)
            maxBtn.MouseButton1Click:Connect(function()
                wanted[keyRef] = haveRef
                box.Text = tostring(haveRef)
            end)

            ST.rows[it.key] = { frame = row, box = box, have = have, amount = it.amount, name = it.name }
        end
    end

    if shown == 0 then
        mk("TextLabel", {
            Size = UDim2.new(1, -8, 0, 28), BackgroundTransparency = 1,
            Text = "— ไม่มีไอเทมที่เทรดได้ —", TextColor3 = Color3.fromRGB(150, 155, 175),
            Font = Enum.Font.Gotham, TextSize = 12,
        }, list)
    end
end

search:GetPropertyChangedSignal("Text"):Connect(rebuildList)
btnRefresh.MouseButton1Click:Connect(rebuildList)

------------------------------------------------------------------
-- ตัวส่งของจริง
------------------------------------------------------------------
local function setProgress(txt, color)
    progress.Text = txt
    progress.TextColor3 = color or Color3.fromRGB(190, 220, 190)
end

local function updateStatus()
    if not ST.inTrade then
        status.Text = "สถานะ: ยังไม่ได้อยู่ในเทรด (เปิดเทรดกับเป้าหมายก่อน)"
        status.TextColor3 = Color3.fromRGB(200, 160, 160)
    else
        local n = 0
        for _ in pairs(ST.ownOffer) do n = n + 1 end
        status.Text = ("สถานะ: เทรดกับ %s | phase=%s | ใส่แล้ว %d/%d ชนิด")
            :format(tostring(ST.partner), ST.phase, n, MAX_UNIQUE)
        status.TextColor3 = Color3.fromRGB(170, 220, 180)
    end
end

-- ยิง +1 ซ้ำจนยอดที่เซิร์ฟรับรู้ถึงเป้าหมาย (self-correcting: อ่านจาก event Updated)
local function sendPlan()
    if ST.sending then return end
    if not ST.inTrade then
        setProgress("❌ ยังไม่ได้อยู่ในเทรด — เปิดเทรดกับเป้าหมายก่อน", Color3.fromRGB(240, 150, 150))
        return
    end

    -- สร้างแผนจากช่องที่กรอก (เคารพเพดาน 20 ชนิด/เทรด)
    local plan, total = {}, 0
    local uniqueUsed = 0
    for _ in pairs(ST.ownOffer) do uniqueUsed = uniqueUsed + 1 end

    for key, want in pairs(wanted) do
        local row = ST.rows[key]
        if row and want > 0 then
            local already = ST.ownOffer[key] or 0
            local need = math.min(want, row.amount) - already
            if need > 0 then
                if (ST.ownOffer[key] == nil) and (uniqueUsed >= MAX_UNIQUE) then
                    log(("ข้าม %s — ครบเพดาน %d ชนิด/เทรดแล้ว"):format(row.name, MAX_UNIQUE))
                else
                    if ST.ownOffer[key] == nil then uniqueUsed = uniqueUsed + 1 end
                    plan[#plan + 1] = { key = key, name = row.name, target = math.min(want, row.amount) }
                    total = total + need
                end
            end
        end
    end

    if #plan == 0 then
        setProgress("ไม่มีอะไรต้องใส่เพิ่ม (กรอกจำนวน หรือใส่ครบแล้ว)", Color3.fromRGB(230, 215, 150))
        return
    end

    ST.sending, ST.stopFlag = true, false
    setProgress(("กำลังใส่ %s ชิ้น (%d ชนิด)..."):format(fmt(total), #plan))

    task.spawn(function()
        for _, p in ipairs(plan) do
            if ST.stopFlag or not ST.inTrade then break end

            if CFG.OfferMode == "loop" then
                -- ยิงทีละ +1 (ช้า · ใช้เมื่อ bulk ใช้ไม่ได้)
                local guard = 0
                while not ST.stopFlag and ST.inTrade do
                    local cur = ST.ownOffer[p.key] or 0
                    if cur >= p.target then break end
                    if ST.phase == "Countdown" then
                        task.wait(0.3)
                    else
                        pcall(function() rOffer:FireServer(p.key, 1) end)
                        task.wait(CFG.OfferDelay)
                        guard = guard + 1
                        if guard % 10 == 0 then
                            setProgress(("กำลังใส่... %s %s/%s")
                                :format(p.name, fmt(ST.ownOffer[p.key] or 0), fmt(p.target)))
                        end
                        if guard > p.target * 3 + 30 then
                            log(("⚠️ %s ใส่ไม่ขึ้น หยุดชนิดนี้ (ได้ %s/%s)")
                                :format(p.name, fmt(ST.ownOffer[p.key] or 0), fmt(p.target)))
                            break
                        end
                    end
                end
            else
                -- ยิงทีเดียวเต็มจำนวนตามที่กรอก (เกม clamp ให้เท่าที่มีในกระเป๋า)
                for _ = 1, 3 do
                    if ST.stopFlag or not ST.inTrade then break end
                    local need = p.target - (ST.ownOffer[p.key] or 0)
                    if need <= 0 then break end
                    if ST.phase == "Countdown" then
                        task.wait(0.3)
                    else
                        setProgress(("ใส่ %s x%s..."):format(p.name, fmt(need)))
                        pcall(function() rOffer:FireServer(p.key, need) end)
                        task.wait(CFG.OfferDelay)
                    end
                end
            end
        end

        -- สรุปจากยอดจริงที่เซิร์ฟตอบกลับ ไม่ใช่จำนวนครั้งที่ยิง
        local got, want, miss = 0, 0, {}
        for _, p in ipairs(plan) do
            local g = ST.ownOffer[p.key] or 0
            got, want = got + g, want + p.target
            if g < p.target then
                miss[#miss + 1] = ("%s %s/%s"):format(p.name, fmt(g), fmt(p.target))
            end
        end

        ST.sending = false
        if ST.stopFlag then
            setProgress(("หยุดแล้ว — ใส่ไป %s/%s ชิ้น"):format(fmt(got), fmt(want)),
                        Color3.fromRGB(240, 200, 150))
        elseif not ST.inTrade then
            setProgress("เทรดจบระหว่างใส่ของ", Color3.fromRGB(240, 150, 150))
        elseif #miss > 0 then
            setProgress(("⚠️ ใส่ได้ %s/%s ชิ้น — ไม่ครบ: %s")
                :format(fmt(got), fmt(want), table.concat(miss, ", ")),
                Color3.fromRGB(240, 200, 150))
            log("ถ้าใส่ไม่ขึ้นเลย ลองตั้ง CFG.OfferMode = \"loop\" (ยิงทีละ 1)")
        else
            setProgress(("✅ ใส่ครบ %s ชิ้น แล้ว — กด READY ได้เลย"):format(fmt(got)))
            if CFG.AutoReady then
                task.wait(0.3)
                pcall(function() rAdvance:FireServer() end)
            end
        end
        updateStatus()
    end)
end

btnSend.MouseButton1Click:Connect(sendPlan)
btnStop.MouseButton1Click:Connect(function()
    ST.stopFlag = true
    setProgress("กำลังหยุด...", Color3.fromRGB(240, 200, 150))
end)
btnReady.MouseButton1Click:Connect(function()
    if not ST.inTrade then
        setProgress("ยังไม่ได้อยู่ในเทรด", Color3.fromRGB(240, 150, 150)); return
    end
    if ST.sending then
        setProgress("ยังใส่ของไม่เสร็จ — กด ■ หยุด ก่อนถ้าจะ ready เลย", Color3.fromRGB(240, 200, 150)); return
    end
    pcall(function() rAdvance:FireServer() end)
end)
btnCancel.MouseButton1Click:Connect(function()
    ST.stopFlag = true
    pcall(function() rCancel:FireServer() end)
end)

------------------------------------------------------------------
-- ฟังสถานะเทรดจากเซิร์ฟ (แหล่งความจริงเดียว)
------------------------------------------------------------------
local conn = rEvent.OnClientEvent:Connect(function(kind, data)
    if not ST.alive then return end
    if kind == "Started" then
        ST.inTrade  = true
        ST.phase    = "Offer"
        ST.partner  = data and data.partner and data.partner.Name or "?"
        ST.ownOffer = {}
        setProgress("เทรดเริ่มแล้ว — กรอกจำนวนแล้วกด ▶", Color3.fromRGB(190, 220, 190))
        rebuildList()
    elseif kind == "Updated" then
        ST.inTrade = true
        ST.phase   = tostring(data and data.phase or "?")
        ST.ownOffer = (data and data.ownOffer) or {}
        if data and data.partner then ST.partner = data.partner.Name end
        if CFG.AutoAccept and ST.phase == "Confirm" and data and not data.ownAccepted then
            pcall(function() rAdvance:FireServer() end)
        end
    elseif kind == "Ended" then
        ST.inTrade  = false
        ST.phase    = "-"
        ST.ownOffer = {}
        ST.stopFlag = true
        setProgress("เทรดจบ: " .. tostring(data and data.reason), Color3.fromRGB(230, 215, 150))
        task.delay(0.5, rebuildList)
    end
    updateStatus()
end)

------------------------------------------------------------------
-- START
------------------------------------------------------------------
_G.ADTradeGUI_Stop = function()
    ST.alive, ST.stopFlag = false, true
    if conn then conn:Disconnect() end
    if gui then gui:Destroy() end
    log("ปิดแล้ว")
end

do
    local okRolls, rolls = pcall(function() return DataController.Rolls() end)
    rolls = okRolls and rolls or 0
    if rolls < (TradeConfig.MIN_ROLLS or 1000) then
        log(("⚠️ Rolls=%s < %s — เกมจะไม่ให้เทรด"):format(tostring(rolls), tostring(TradeConfig.MIN_ROLLS)))
    end
    if LP.AccountAge < (TradeConfig.MIN_ACCOUNT_AGE or 14) then
        log(("⚠️ AccountAge=%d < %d วัน — เกมจะไม่ให้เทรด"):format(LP.AccountAge, TradeConfig.MIN_ACCOUNT_AGE or 14))
    end
end

rebuildList()
updateStatus()
log("พร้อมใช้งาน | RightCtrl = ซ่อน/โชว์ | ปิด: _G.ADTradeGUI_Stop()")
