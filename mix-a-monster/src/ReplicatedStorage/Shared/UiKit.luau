--!strict
--[[
	UiKit.luau — the visual contract for every screen (GDD §10).

	All UI in this game is built in code, not in Studio, so that a design
	change is a diff and not a manual pass over a dozen .rbxm files. Every
	controller builds from these primitives, which is what keeps eight
	separately-written screens looking like one game.

	Mobile-first rules baked in here, not left to each caller:
	  * every tappable thing is at least TOUCH_MIN (44px) on its short edge
	  * text scales, never overflows
	  * the HUD's action cluster sits bottom-right, thumb-reachable
	  * nothing relies on hover; hover is a bonus on desktop
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rarity = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("Rarity"))

local UiKit = {}

UiKit.TOUCH_MIN = 44

UiKit.PALETTE = {
	ink = Color3.fromRGB(16, 14, 28),
	panel = Color3.fromRGB(32, 28, 54),
	panelSoft = Color3.fromRGB(46, 40, 74),
	stroke = Color3.fromRGB(96, 84, 150),
	text = Color3.fromRGB(248, 246, 255),
	muted = Color3.fromRGB(168, 160, 200),
	goop = Color3.fromRGB(126, 232, 96),
	accent = Color3.fromRGB(255, 122, 210),
	warn = Color3.fromRGB(255, 186, 62),
	danger = Color3.fromRGB(255, 84, 84),
	ok = Color3.fromRGB(96, 220, 140),
}

UiKit.FONT = Enum.Font.FredokaOne
UiKit.FONT_BODY = Enum.Font.GothamMedium

function UiKit.rarityColor(tier: number): Color3
	return Rarity.color(tier)
end

-- Phones get a slightly larger base scale so 44px targets stay 44px.
function UiKit.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function UiKit.isSmallScreen(): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	return camera.ViewportSize.X < 900
end

-- ── Primitives ───────────────────────────────────────────────────────────

--[[
	Keys applyCommon consumes itself rather than assigning to the Instance.
	Everything NOT listed here is written straight onto the object, which is
	what makes the kit terse — and is exactly why the list has to be complete:
	a documented prop missing from it throws "X is not a valid member of
	TextLabel" at runtime, and `props` is `{ [string]: any }`, so the type
	checker cannot see it coming.
]]
local RESERVED = {
	Parent = true,
	Corner = true,
	Stroke = true,
	Padding = true,
	Gradient = true,
	MaxTextSize = true,
	MinTextSize = true,
}

local function applyCommon(instance: GuiObject, props: { [string]: any })
	for key, value in props do
		if not RESERVED[key] then
			(instance :: any)[key] = value
		end
	end
	if props.Corner then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = if typeof(props.Corner) == "UDim" then props.Corner else UDim.new(0, props.Corner)
		corner.Parent = instance
	end
	if props.Stroke then
		local stroke = Instance.new("UIStroke")
		stroke.Color = if typeof(props.Stroke) == "Color3" then props.Stroke else UiKit.PALETTE.stroke
		stroke.Thickness = 2
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = instance
	end
	if props.Gradient then
		local gradient = Instance.new("UIGradient")
		if typeof(props.Gradient) == "ColorSequence" then
			gradient.Color = props.Gradient
		elseif type(props.Gradient) == "table" then
			gradient.Color = ColorSequence.new(props.Gradient[1], props.Gradient[2])
			gradient.Rotation = props.Gradient[3] or 90
		end
		gradient.Parent = instance
	end
	if props.Padding then
		local padding = Instance.new("UIPadding")
		local amount = UDim.new(0, props.Padding)
		padding.PaddingTop = amount
		padding.PaddingBottom = amount
		padding.PaddingLeft = amount
		padding.PaddingRight = amount
		padding.Parent = instance
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
end

function UiKit.screen(name: string, displayOrder: number?): ScreenGui
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 1
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

function UiKit.frame(props: { [string]: any }): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = UiKit.PALETTE.panel
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	applyCommon(frame, props)
	return frame
end

function UiKit.label(props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = UiKit.FONT
	label.TextColor3 = UiKit.PALETTE.text
	label.TextScaled = true
	label.Text = ""
	label.RichText = true
	applyCommon(label, props)
	if label.TextScaled then
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = (props.MaxTextSize :: number?) or 42
		constraint.MinTextSize = 8
		constraint.Parent = label
	end
	return label
end

--[[
	The only button constructor in the game. Enforces the touch minimum and
	gives every button the same press feedback, so nothing in the UI feels
	inert on a phone.
]]
function UiKit.button(props: { [string]: any }, onClick: (() -> ())?): TextButton
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = UiKit.PALETTE.accent
	button.BorderSizePixel = 0
	button.Font = UiKit.FONT
	button.TextColor3 = UiKit.PALETTE.ink
	button.TextScaled = true
	button.AutoButtonColor = false
	button.Text = ""
	applyCommon(button, props)

	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(UiKit.TOUCH_MIN, UiKit.TOUCH_MIN)
	minimum.Parent = button

	local textSize = Instance.new("UITextSizeConstraint")
	textSize.MaxTextSize = (props.MaxTextSize :: number?) or 28
	textSize.MinTextSize = 8
	textSize.Parent = button

	local base = button.BackgroundColor3
	local function setState(pressed: boolean, hovering: boolean)
		local target = base
		if pressed then
			target = base:Lerp(Color3.new(0, 0, 0), 0.25)
		elseif hovering then
			target = base:Lerp(Color3.new(1, 1, 1), 0.15)
		end
		TweenService:Create(button, TweenInfo.new(0.08), { BackgroundColor3 = target }):Play()
	end

	local hovering = false
	button.MouseEnter:Connect(function()
		hovering = true
		setState(false, true)
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		setState(false, false)
	end)
	button.MouseButton1Down:Connect(function()
		setState(true, hovering)
	end)
	button.MouseButton1Up:Connect(function()
		setState(false, hovering)
	end)
	if onClick then
		button.Activated:Connect(onClick)
	end
	return button
end

function UiKit.list(parent: GuiObject, props: { [string]: any }?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	if props then
		for key, value in props do
			(layout :: any)[key] = value
		end
	end
	layout.Parent = parent
	return layout
end

function UiKit.grid(parent: GuiObject, cellSize: UDim2, padding: UDim2?): UIGridLayout
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = cellSize
	grid.CellPadding = padding or UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = parent
	return grid
end

function UiKit.scroll(props: { [string]: any }): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = UiKit.PALETTE.stroke
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Size = UDim2.fromScale(1, 1)
	applyCommon(scroll, props)
	return scroll
end

--[[
	Shows an assembled Mixling in a rotating ViewportFrame. Used by the result
	card, the Mixdex grid and the Den panel — one implementation so a Mixling
	looks the same everywhere it is shown.
]]
function UiKit.viewport(props: { [string]: any }): (ViewportFrame, (Model?) -> ())
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(190, 190, 210)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.Size = UDim2.fromScale(1, 1)
	applyCommon(viewport, props)

	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local current: Model? = nil
	local function setModel(model: Model?)
		if current then
			current:Destroy()
			current = nil
		end
		if not model then
			return
		end
		model.Parent = viewport
		current = model

		local _, size = model:GetBoundingBox()
		local radius = math.max(size.X, size.Y, size.Z)
		local distance = math.max(4, radius * 2.1)
		local pivot = model:GetPivot().Position
		camera.CFrame = CFrame.lookAt(pivot + Vector3.new(0, radius * 0.35, distance), pivot)
	end

	return viewport, setModel
end

--[[
	Text entry. Sized to the touch minimum on its short edge like a button,
	because a code field a thumb cannot hit is a code field nobody redeems.
]]
function UiKit.textBox(props: { [string]: any }): TextBox
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = UiKit.PALETTE.ink
	box.BorderSizePixel = 0
	box.Font = UiKit.FONT_BODY
	box.TextColor3 = UiKit.PALETTE.text
	box.PlaceholderColor3 = UiKit.PALETTE.muted
	box.TextScaled = true
	box.ClearTextOnFocus = false
	box.Text = ""
	applyCommon(box, props)

	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(UiKit.TOUCH_MIN, UiKit.TOUCH_MIN)
	minimum.Parent = box

	local textSize = Instance.new("UITextSizeConstraint")
	textSize.MaxTextSize = (props.MaxTextSize :: number?) or 24
	textSize.MinTextSize = (props.MinTextSize :: number?) or 8
	textSize.Parent = box
	return box
end

--[[
	A world-anchored panel: overhead nameplates, den signs, tutorial bubbles.
	`AlwaysOnTop` is off by default — a nameplate that draws through walls
	turns the Den ring into a wallhack, which matters in a game about sneaking
	into someone else's Den.
]]
function UiKit.billboard(adornee: Instance, props: { [string]: any }): BillboardGui
	local gui = Instance.new("BillboardGui")
	if adornee:IsA("BasePart") then
		gui.Adornee = adornee
	elseif adornee:IsA("Model") then
		local root = adornee.PrimaryPart or adornee:FindFirstChildWhichIsA("BasePart", true)
		if root then
			gui.Adornee = root
		end
	end
	gui.Size = UDim2.fromOffset(200, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	for key, value in props do
		if key ~= "Parent" then
			(gui :: any)[key] = value
		end
	end
	if props.Parent then
		gui.Parent = props.Parent
	end
	return gui
end

-- ── Motion ───────────────────────────────────────────────────────────────

function UiKit.tween(instance: Instance, props: { [string]: any }, duration: number?, style: Enum.EasingStyle?): Tween
	local info = TweenInfo.new(duration or 0.2, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance, info, props)
	tween:Play()
	return tween
end

--[[
	A quick squash-and-release. Scales BOTH halves of the UDim2: an earlier
	version touched only the Scale components, which made it a silent no-op on
	any element sized purely in offsets — i.e. most of the HUD.
]]
function UiKit.pop(instance: GuiObject, strength: number?)
	local amount = 1 - (strength or 0.12)
	local base = instance.Size
	instance.Size = UDim2.new(
		base.X.Scale * amount,
		base.X.Offset * amount,
		base.Y.Scale * amount,
		base.Y.Offset * amount
	)
	UiKit.tween(instance, { Size = base }, 0.18, Enum.EasingStyle.Back)
end

-- Top safe area, so the HUD never hides under a phone notch.
function UiKit.topInset(): number
	local inset = GuiService:GetGuiInset()
	return math.max(inset.Y, 8)
end

return UiKit
