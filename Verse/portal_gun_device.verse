using { /Fortnite.com/Devices }
using { /Fortnite.com/Characters }
using { /Verse.org/SceneGraph }
using { /Verse.org/Simulation }
using { /UnrealEngine.com/Temporary/Diagnostics }
using { /UnrealEngine.com/Temporary/SpatialMath }

# Portal gun: a custom item (bought in the Achievements shop) that shoots two
# linked portals per player.
#
# 1. FIRING
#    LeftInput / RightInput are Input Trigger devices (Left = Fire, Right =
#    Aim/Target). Pressing one while HOLDING the portal gun casts a ray from
#    the player's view and moves that player's portal prop onto the surface it
#    hits, rotated to the surface normal:
#        Left  -> portal A (slot 0 of the pair)
#        Right -> portal B (slot 1 of the pair)
#    Firing again with the same button moves that portal to the new spot.
#    "Holding the gun" is checked with HoldCheck: a Conditional Button whose
#    key item (KeyItemIndex) is the portal gun item. The shop just has to grant
#    that item as usual — nothing else needs wiring to this device.
#
# 2. PROPS / TELEPORTERS
#    Props and Teleporters are 8-slot arrays — 2 per player, 4 players max:
#        Player slot 0 -> [0] (A), [1] (B)
#        Player slot 1 -> [2], [3]   ...and so on.
#    Players get a slot when they join (lowest free) and free it on leave.
#    Each portal prop carries a teleporter that is moved with it, sitting just
#    in front of the surface and facing out of it. Once BOTH of a player's
#    portals are placed, their teleporters are enabled; walking into one sends
#    you out of the other. Anyone can use anyone's portals.
#
# Setup:
#    - Props: Collision OFF (so they don't block the teleporter or the ray),
#      front of the mesh facing +X (or tick FlipPropFacing if it faces -X).
#      Park them anywhere; they are hidden until fired.
#    - Teleporters: no Teleport Group / Target Group (this device does the
#      teleporting), Visible During Game off.
#    - Input triggers: Left on "Fire", Right on "Aim/Target"; leave them
#      registered for all players.
#
# TODO (for whoever picks this up — the achievements device was NOT in this
# repo when this was written, so none of this is wired yet):
#    - Add the portal gun as a buyable item in the Achievements device's shop,
#      following how that device already sells its other items (item granter
#      or whatever pattern it uses). Match its naming/@editable layout.
#    - Make sure the item it grants is the SAME item set as HoldCheck's key
#      item at KeyItemIndex, otherwise FirePortal never passes the hold check.
#    - If the shop tracks ownership itself (e.g. a [player]logic of unlocked
#      items), consider exposing something like PortalGunDevice.OnGunBought /
#      ClearPlayerPortals(Player) for it to call, e.g. to clear a player's
#      portals when the gun is removed. Nothing here depends on that today.
#    - This file was written without compiling. Double-check in UEFN:
#        * Raycast(): FindSweepHits overload, collision_sphere, sweep_hit
#          field names, /Verse.org <-> UnrealEngine FromVector3 conversions.
#        * conditional_button_device.IsHoldingItem[Agent, KeyItemIndex].
#        * teleporter_device.TeleportTo[] (moving the teleporter with the prop).

# Verse has no closures, so one watcher per teleporter binds its index to the
# EnterEvent.
portal_gun_teleporter_watcher := class:
    Device : PortalGunDevice
    Index : int

    Handle(Agent : agent) : void =
        Device.OnPortalEntered(Agent, Index)

portal_gun_hit := struct:
    Position : vector3
    Normal : vector3

PortalGunDevice := class(creative_device):

    # ── Input ────────────────────────────────────────────────────────────────

    # Input Trigger on "Fire" (left click). Places portal A.
    @editable
    LeftInput : input_trigger_device = input_trigger_device{}

    # Input Trigger on "Aim/Target" (right click). Places portal B.
    @editable
    RightInput : input_trigger_device = input_trigger_device{}

    # Conditional Button whose key item is the portal gun. Only used to check
    # that the player is holding the gun when they click.
    @editable
    HoldCheck : conditional_button_device = conditional_button_device{}

    # Which key item slot on HoldCheck is the portal gun.
    @editable
    KeyItemIndex : int = 0

    # ── Portals (2 per player, 4 players) ────────────────────────────────────

    # [2*slot] = portal A, [2*slot + 1] = portal B.
    @editable
    Props : []creative_prop = array{}

    # One per prop, same order.
    @editable
    Teleporters : []teleporter_device = array{}

    # ── Ray / placement ──────────────────────────────────────────────────────

    # Max distance a portal can be shot, in cm.
    @editable
    MaxDistance : float = 5000.0

    # Ray starts this far in front of the view so it clears the player's own
    # capsule.
    @editable
    RayStartOffset : float = 60.0

    # Prop is pushed this far off the surface so it doesn't z-fight.
    @editable
    WallOffset : float = 2.0

    # Teleporter sits this far out from the surface (where players exit).
    @editable
    TeleporterOffset : float = 80.0

    # Added to the teleporter's height (negative = lower, e.g. so a wall
    # portal's exit point is near the floor).
    @editable
    TeleporterHeightOffset : float = 0.0

    # Tick if the portal mesh's front faces -X instead of +X.
    @editable
    FlipPropFacing : logic = false

    # Seconds after a teleport before that player can be teleported again, so
    # arriving at the other portal doesn't bounce them straight back.
    @editable
    TeleportCooldown : float = 1.0

    # ── Feedback (optional, "Heard by Instigator") ───────────────────────────

    @editable
    FireSound : audio_player_device = audio_player_device{}

    @editable
    MissSound : audio_player_device = audio_player_device{}

    @editable
    TeleportSound : audio_player_device = audio_player_device{}

    @editable
    DEBUG : logic = false

    # ── State ────────────────────────────────────────────────────────────────

    var PlayerSlots : [player]int = map{}

    # Portal index -> placed this round.
    var Placed : [int]logic = map{}

    var LastTeleportTime : [agent]float = map{}

    OnBegin<override>()<suspends>:void =
        LeftInput.PressedEvent.Subscribe(OnLeftPressed)
        RightInput.PressedEvent.Subscribe(OnRightPressed)

        for (Index -> Teleporter : Teleporters):
            Watcher := portal_gun_teleporter_watcher{Device := Self, Index := Index}
            Teleporter.EnterEvent.Subscribe(Watcher.Handle)
            Teleporter.Disable()
        for (Prop : Props):
            Prop.Hide()

        Playspace := GetPlayspace()
        for (Player : Playspace.GetPlayers()):
            AssignSlot(Player)
        Playspace.PlayerAddedEvent().Subscribe(AssignSlot)
        Playspace.PlayerRemovedEvent().Subscribe(FreeSlot)

        if (Props.Length <> Teleporters.Length):
            Print("[PortalGun] WARNING: {Props.Length} props but {Teleporters.Length} teleporters — they must match")
        Log("Ready — {MaxSlots()} player slot(s)")

    MaxSlots():int =
        Quotient[Min(Props.Length, Teleporters.Length), 2] or 0

    # --- Slots ---------------------------------------------------------------

    AssignSlot(Player : player):void =
        if (PlayerSlots[Player]):
            return
        if (Slot := FirstFreeSlot[], set PlayerSlots[Player] = Slot):
            Log("Player got slot {Slot}")
        else:
            Log("No free portal slot for player")

    FirstFreeSlot()<transacts><decides>:int =
        Free := for (Slot := 0..MaxSlots() - 1, not SlotTaken[Slot]) { Slot }
        Free[0]

    SlotTaken(Slot : int)<transacts><decides>:void =
        Owners := for (Player -> Used : PlayerSlots, Used = Slot) { Player }
        Owners.Length > 0

    FreeSlot(Player : player):void =
        if (Slot := PlayerSlots[Player]):
            ClearPortal(Slot * 2)
            ClearPortal(Slot * 2 + 1)
            var Remaining : [player]int = map{}
            for (Other -> OtherSlot : PlayerSlots, Other <> Player):
                set Remaining = ConcatenateMaps(Remaining, map{Other => OtherSlot})
            set PlayerSlots = Remaining
            Log("Freed slot {Slot}")

    ClearPortal(Index : int):void =
        if (Prop := Props[Index]):
            Prop.Hide()
        if (Teleporter := Teleporters[Index]):
            Teleporter.Disable()
        if (set Placed[Index] = false) {}
        UpdatePair(Index)

    # --- Firing --------------------------------------------------------------

    OnLeftPressed(Agent : agent):void =
        FirePortal(Agent, 0)

    OnRightPressed(Agent : agent):void =
        FirePortal(Agent, 1)

    FirePortal(Agent : agent, Side : int):void =
        if (not HoldCheck.IsHoldingItem[Agent, KeyItemIndex]):
            return
        if (Player := player[Agent], Slot := PlayerSlots[Player], Character := Agent.GetFortCharacter[]):
            Index := Slot * 2 + Side
            ViewRotation := Character.GetViewRotation()
            Direction := ViewRotation.GetLocalForward()
            Start := Character.GetViewLocation() + Direction * RayStartOffset
            if (Hit := Raycast[Start, Direction, MaxDistance]):
                PlacePortal(Index, Hit, ViewRotation)
                FireSound.Play(Agent)
            else:
                Log("Portal {Index}: ray hit nothing")
                MissSound.Play(Agent)

    PlacePortal(Index : int, Hit : portal_gun_hit, ViewRotation : rotation):void =
        Normal := Hit.Normal
        # Floors/ceilings have no meaningful yaw from the normal, so face them
        # the way the player is looking instead.
        Yaw := if (Abs(Normal.Z) > 0.99) then (ViewRotation.GetYawPitchRollDegrees()[0] or 0.0) else RadiansToDegrees(ArcTan(Normal.Y, Normal.X))
        Pitch := RadiansToDegrees(ArcTan(Normal.Z, Sqrt(Normal.X * Normal.X + Normal.Y * Normal.Y)))

        PropRotation := if (FlipPropFacing?) then MakeRotationFromYawPitchRollDegrees(Yaw + 180.0, -Pitch, 0.0) else MakeRotationFromYawPitchRollDegrees(Yaw, Pitch, 0.0)
        # Teleporter stays upright; only its yaw follows the wall, so players
        # come out facing away from it.
        TeleporterRotation := MakeRotationFromYawPitchRollDegrees(Yaw, 0.0, 0.0)
        TeleporterPosition := Hit.Position + Normal * TeleporterOffset + vector3{X := 0.0, Y := 0.0, Z := TeleporterHeightOffset}

        if (Prop := Props[Index]):
            if (Prop.TeleportTo[Hit.Position + Normal * WallOffset, PropRotation]):
                Prop.Show()
        if (Teleporter := Teleporters[Index]):
            if (Teleporter.TeleportTo[TeleporterPosition, TeleporterRotation]) {}
        if (set Placed[Index] = true) {}
        UpdatePair(Index)
        Log("Portal {Index} placed")

    # Enables both teleporters of a pair once both portals exist, otherwise
    # keeps them off.
    UpdatePair(Index : int):void =
        Partner := PartnerOf(Index)
        Ready := if (Placed[Index]?, Placed[Partner]?) then true else false
        for (I : array{Index, Partner}, Teleporter := Teleporters[I]):
            if (Ready?):
                Teleporter.Enable()
            else:
                Teleporter.Disable()

    PartnerOf(Index : int):int =
        if (Mod[Index, 2] = 0) then Index + 1 else Index - 1

    # --- Raycast -------------------------------------------------------------

    # Sweeps a tiny sphere from Start along Direction and returns the solid
    # surface it hits. FindSweepHits yields every overlap before the first
    # blocking hit, sorted by distance, so the blocking hit is the last one.
    # Scene graph uses /Verse.org/SpatialMath; convert to/from the
    # UnrealEngine types the props and characters use.
    Raycast(Start : vector3, Direction : vector3, Distance : float)<transacts><decides>:portal_gun_hit =
        Root := GetSimulationEntity[]
        StartTransform := (/Verse.org/SpatialMath:)transform{Translation := (/Verse.org/SpatialMath:)FromVector3(Start)}
        Displacement := (/Verse.org/SpatialMath:)FromVector3(Direction * Distance)
        var LastHit : ?sweep_hit = false
        for (Hit : Root.FindSweepHits(Displacement, StartTransform, collision_sphere{Radius := 1.0})):
            set LastHit = option{Hit}
        Hit := LastHit?
        portal_gun_hit{Position := FromVector3(Hit.ContactPosition), Normal := FromVector3(Hit.ContactNormal)}

    # --- Teleporting ---------------------------------------------------------

    OnPortalEntered(Agent : agent, Index : int):void =
        Partner := PartnerOf(Index)
        if (not (Placed[Index]? and Placed[Partner]?)):
            return
        Now := GetSimulationElapsedTime()
        if (Last := LastTeleportTime[Agent], Now - Last < TeleportCooldown):
            return
        if (Destination := Teleporters[Partner]):
            if (set LastTeleportTime[Agent] = Now) {}
            Destination.Teleport(Agent)
            TeleportSound.Play(Agent)
            Log("Teleported through portal {Index} -> {Partner}")

    Log(Message : string):void =
        if (DEBUG?):
            Print("[PortalGun] {Message}")
